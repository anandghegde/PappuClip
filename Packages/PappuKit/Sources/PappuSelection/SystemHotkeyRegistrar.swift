import Carbon.HIToolbox
import Foundation
import Synchronization

/// `RegisterEventHotKey`, the system's own global shortcut (architecture §4.1).
///
/// It needs no permission and no tap: the key never passes through PappuClip, macOS simply says that
/// the combination was pressed, and no other app sees it while it is registered. Carbon delivers hot
/// keys through the application event target, so registering, unregistering and the handler all happen
/// on the main thread. Without a running application event loop nothing is delivered, which is why the
/// package's tests use a fake and the real thing is exercised by SpikeLab's `check-tap-service`.
public final class SystemHotkeyRegistrar: HotkeyRegistering {
    public init() {}

    public func register(
        _ shortcut: HotkeyShortcut,
        handler: @escaping @Sendable () -> Void
    ) -> (any RegisteredHotkey)? {
        onMainThread { HotkeyTable.shared.register(shortcut, handler: handler) }
    }
}

/// `'PPCL'`. Carbon hands every hot key to the one process-wide handler, so a signature of our own
/// tells ours from a library's.
private let hotkeySignature: OSType = 0x5050_434C

/// The registrations of this process and the one Carbon handler that dispatches to them.
@MainActor
private final class HotkeyTable {
    static let shared = HotkeyTable()

    private var handlers: [UInt32: @Sendable () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    func register(_ shortcut: HotkeyShortcut, handler: @escaping @Sendable () -> Void) -> (any RegisteredHotkey)? {
        installHandlerIfNeeded()
        let id = nextID
        var hotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            EventHotKeyID(signature: hotkeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &hotkey
        )
        // `eventHotKeyExistsErr` is what a combination another app holds comes back as.
        guard status == noErr, let hotkey else { return nil }
        nextID += 1
        handlers[id] = handler
        return CarbonHotkey(id: id, hotkey: hotkey)
    }

    func unregister(id: UInt32, hotkey: EventHotKeyRef) {
        handlers[id] = nil
        UnregisterEventHotKey(hotkey)
    }

    func fire(id: UInt32) {
        handlers[id]?()
    }

    /// Installed once and never removed, like the taps' callback contexts: a hot-key event that
    /// arrives while the last registration is going away then still finds a handler table to miss in.
    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, nil, &eventHandler)
    }
}

private let hotkeyCallback: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr, id.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    // Carbon calls this on the main thread, where the table lives.
    MainActor.assumeIsolated { HotkeyTable.shared.fire(id: id.id) }
    return noErr
}

private final class CarbonHotkey: RegisteredHotkey, @unchecked Sendable {
    private let id: UInt32
    private let hotkey: EventHotKeyRef
    private let gone = Atomic(false)

    init(id: UInt32, hotkey: EventHotKeyRef) {
        self.id = id
        self.hotkey = hotkey
    }

    func unregister() {
        guard !gone.exchange(true, ordering: .relaxed) else { return }
        let (id, hotkey) = (self.id, self.hotkey)
        onMainThread { HotkeyTable.shared.unregister(id: id, hotkey: hotkey) }
    }

    deinit {
        unregister()
    }
}

extension HotkeyShortcut {
    /// Carbon's modifier bits, which are neither `CGEventFlags` nor `NSEvent.ModifierFlags`.
    fileprivate var carbonModifiers: UInt32 {
        var bits = 0
        if modifiers.contains(.shift) { bits |= shiftKey }
        if modifiers.contains(.control) { bits |= controlKey }
        if modifiers.contains(.option) { bits |= optionKey }
        if modifiers.contains(.command) { bits |= cmdKey }
        return UInt32(bits)
    }
}
