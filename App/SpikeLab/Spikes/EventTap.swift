import CoreGraphics
import Foundation
import Synchronization

/// A thread that does nothing but serve event taps, the shape architecture §4.1 gives the product:
/// a tap on the main run loop stalls input system-wide whenever the UI is busy.
final class TapThread: @unchecked Sendable {
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

    func stop() {
        CFRunLoopStop(runLoop)
    }
}

/// A `CGEventTap` with a Swift closure for a callback.
final class EventTap: @unchecked Sendable {
    enum Disposition {
        case pass
        /// Only an active (`.defaultTap`) tap can do this; a listen-only tap's answer is ignored.
        case swallow
    }

    typealias Handler = @Sendable (CGEventType, CGEvent) -> Disposition

    /// What the tap's callback is given. It is never freed. A run of spike 6 died in the callback: it had
    /// been handed a `tapDisabledByUserInput` notice and a context whose memory had been freed. Which tap
    /// that context had belonged to is not known, so a context now outlives every tap.
    private final class Context: @unchecked Sendable {
        let handler: Handler
        weak var tap: EventTap?

        init(handler: @escaping Handler) {
            self.handler = handler
        }
    }

    /// Callbacks that arrived for a tap that was refused or had been invalidated, by event type.
    static var callsAfterTheTapWentAway: [UInt32: Int] { strayCalls.withLock { $0 } }
    private static let strayCalls = Mutex([UInt32: Int]())

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop: CFRunLoop

    /// Nil when the system refuses the tap, which is how a missing permission shows up.
    init?(
        events: [CGEventType],
        option: CGEventTapOptions,
        location: CGEventTapLocation = .cgSessionEventTap,
        on thread: TapThread,
        handler: @escaping Handler
    ) {
        runLoop = thread.runLoop
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }

        let context = Context(handler: handler)
        guard let port = CGEvent.tapCreate(
            tap: location, place: .headInsertEventTap, options: option, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                guard let tap = box.tap, tap.port != nil else {
                    EventTap.strayCalls.withLock { $0[type.rawValue, default: 0] += 1 }
                    return Unmanaged.passUnretained(event)
                }
                switch box.handler(type, event) {
                case .pass: return Unmanaged.passUnretained(event)
                case .swallow: return nil
                }
            },
            userInfo: Unmanaged.passRetained(context).toOpaque()
        ) else { return nil }

        context.tap = self
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isEnabled: Bool {
        get { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
        set { port.map { CGEvent.tapEnable(tap: $0, enable: newValue) } }
    }

    func invalidate() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    deinit {
        invalidate()
    }
}
