import CoreGraphics
import Foundation
import Synchronization

/// Session-level active `CGEventTap`s, which the Accessibility grant alone authorises (M0 spike 2).
///
/// The taps are served by a thread of their own: a tap on the main run loop stalls input system-wide
/// whenever the UI is busy, and macOS then switches it off (architecture §4.1).
public final class SessionTapInstaller: TapInstalling {
    private let thread: TapThread
    private let contexts: [TapKind: CallbackContext]

    /// - Parameter ownTag: what PappuClip marks the events it posts with. The taps pass those on untouched
    ///   and tell nobody.
    public init(ownTag: SyntheticEventTag) {
        thread = TapThread(name: "app.pappuclip.taps")
        contexts = Dictionary(uniqueKeysWithValues: TapKind.allCases.map { ($0, CallbackContext(ownTag: ownTag)) })
        // Never released, on purpose. See `CallbackContext`.
        contexts.values.forEach { _ = Unmanaged.passRetained($0) }
    }

    public func install(_ kind: TapKind, handler: @escaping TapHandler) -> (any InstalledTap)? {
        guard let context = contexts[kind] else { return nil }
        let mask = kind.eventTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: tapCallback, userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return nil }
        return SessionTap(port: port, runLoop: thread.runLoop, context: context, handler: handler)
    }
}

extension TapKind {
    fileprivate var eventTypes: [CGEventType] {
        switch self {
        case .mouse: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        case .keyDown: [.keyDown]
        }
    }
}

/// What a tap's callback is given. There is one per kind of tap, shared by every tap of that kind the
/// installer ever makes, and it is never freed: M0 spike 6 lost a run to a callback that arrived, as a
/// tap-disabled notice, with a context whose memory was gone. A callback that comes after its tap has
/// been removed finds no handler here and passes the event on.
private final class CallbackContext: Sendable {
    struct Slot {
        var owner: ObjectIdentifier
        var handler: TapHandler
    }

    let ownTag: SyntheticEventTag
    let slot = Mutex<Slot?>(nil)

    init(ownTag: SyntheticEventTag) {
        self.ownTag = ownTag
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    let pass = Unmanaged.passUnretained(event)
    guard let userInfo else { return pass }
    let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
    guard let handler = context.slot.withLock({ $0?.handler }),
          let input = TapInput(type: type, event: event, ownTag: context.ownTag)
    else { return pass }
    switch handler(input) {
    case .pass: return pass
    case .consume: return nil
    }
}

private final class SessionTap: InstalledTap, @unchecked Sendable {
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop
    private let context: CallbackContext
    private let removed = Atomic(false)

    init(port: CFMachPort, runLoop: CFRunLoop, context: CallbackContext, handler: @escaping TapHandler) {
        self.port = port
        self.runLoop = runLoop
        self.context = context
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        context.slot.withLock { $0 = .init(owner: ObjectIdentifier(self), handler: handler) }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isEnabled: Bool {
        !removed.load(ordering: .relaxed) && CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    func enable() {
        guard !removed.load(ordering: .relaxed) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func remove() {
        guard !removed.exchange(true, ordering: .relaxed) else { return }
        // A newer tap of the same kind may have the slot by now; only our own handler is ours to clear.
        context.slot.withLock { if $0?.owner == ObjectIdentifier(self) { $0 = nil } }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
    }

    deinit {
        remove()
    }
}

/// A thread that does nothing but serve event taps.
private final class TapThread: @unchecked Sendable {
    // Written once by the thread itself, before `init` is let past the semaphore.
    private(set) var runLoop: CFRunLoop!

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; this timer never fires and keeps it alive.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }
}
