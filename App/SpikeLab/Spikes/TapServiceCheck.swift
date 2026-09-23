import CoreGraphics
import Foundation
import PappuHarness
import PappuSelection
import Synchronization

/// Not one of the six spikes. It runs the input routes M1 is built on — `EventTapService` over
/// `SessionTapInstaller`, and `HotkeyService` over `SystemHotkeyRegistrar`, both in PappuSelection —
/// against the real window server, which the package's tests cannot reach: they use fakes, because a
/// real tap needs the Accessibility grant and a real hot key needs an application event loop.
///
/// Every key event here is an F13, or the ⌃⌥⌘F16 the run registers as a shortcut, and both are posted
/// by the run itself and swallowed by it, so no app sees a key nobody pressed. It posts no mouse event;
/// pointer events are only counted if someone happens to use the mouse meanwhile.
struct TapServiceCheck: Spike {
    let id = "check-tap-service"
    let title = "· The product's taps and shortcut on the real system"
    let question = "Do EventTapService, SessionTapInstaller and the global shortcut behave on a real session as they do against the fakes (ACT-5, ACT-15, ACT-19)?"
    let instructions = """
        Needs Accessibility. Hands off the keyboard for the few seconds it takes; using the mouse is welcome, \
        since the run counts the pointer events the mouse tap hands over and nothing else about them. \
        Switching apps is welcome too: the health monitor counts the notices it gets, and app activation is one.
        """
    let options: [SpikeOption] = []

    private static let f13: CGKeyCode = 105
    private static let burst = 50
    private static let leaseCycles = 50
    /// The same ceiling spike 2 holds the bare tap to (ACT-19).
    private static let leaseCeilingMs = 10.0
    /// F16 with all three modifiers: a combination ACT-5 allows and nothing is likely to be holding.
    private static let shortcut = HotkeyShortcut(keyCode: 106, modifiers: [.control, .option, .command])
    private static let shortcutPresses = 5

    func run(recorder: RunRecorder, enabled: Set<String>) {
        let permissions = PermissionSnapshot.current()
        recorder.setParameter("permissions", permissions.summary)
        guard permissions.accessibility, permissions.postEvent else {
            recorder.observe("service.run", .inconclusive, "Needs Accessibility and post-event access: \(permissions.summary)")
            return
        }

        let ownTag = SyntheticEventTag.random()
        // Differs from `ownTag` in its lowest bit, so the two cannot be the same.
        guard let probeTag = SyntheticEventTag(rawValue: ownTag.rawValue ^ 1) else { return }

        // Installed first, so it sits behind the service's key tap and sees only what that lets through.
        // It swallows every F13 of this run, whichever tag it carries.
        let catcherThread = TapThread(name: "check.catcher")
        defer { catcherThread.stop() }
        let caught = Mutex((probe: 0, own: 0))
        guard let catcher = EventTap(events: [.keyDown], option: .defaultTap, on: catcherThread, handler: { type, event in
            guard type == .keyDown else { return .pass }
            if probeTag.marks(event) {
                caught.withLock { $0.probe += 1 }
            } else if ownTag.marks(event) {
                caught.withLock { $0.own += 1 }
            } else {
                return .pass
            }
            return .swallow
        }) else {
            recorder.observe("service.run", .inconclusive, "The catching tap was refused, so nothing may be posted.")
            return
        }
        defer { catcher.invalidate() }

        let service = EventTapService(installer: SessionTapInstaller(ownTag: ownTag))
        // The three notices of architecture §4.1, on the real workspace. Nothing here forces one, so
        // what it reports is whatever happened during the run; it is started first so that it covers
        // all of it (ACT-15).
        let monitor = TapHealthMonitor(service: service, triggers: WorkspaceHealthTriggers())
        monitor.start()
        defer { monitor.stop() }
        let pointerEvents = Atomic(0)
        let interruptions = Atomic(0)
        let listener = Task { [events = service.events] in
            for await output in events {
                switch output {
                case .pointer: pointerEvents.add(1, ordering: .relaxed)
                case .interrupted: interruptions.add(1, ordering: .relaxed)
                }
            }
        }
        defer { listener.cancel() }

        let started = recorder.measure("service.start") { service.start() }
        recorder.observe("service.mouseTap.created", started ? .confirmed : .refuted, "start() returned \(started)")

        // 1. Idle: no key tap, so a key goes straight past.
        post(Self.burst, tagged: probeTag)
        let idle = wait(for: Self.burst) { caught.withLock { $0.probe } }
        recorder.observe(
            "service.noKeyTapWhileIdle", !service.status.keyTapInstalled && idle == Self.burst ? .confirmed : .refuted,
            "keyTapInstalled=\(service.status.keyTapInstalled); \(idle) of \(Self.burst) posted keys went past untouched"
        )

        // 2. Leased: the holder sees and consumes every key, and none gets past.
        let seen = Atomic(0)
        guard let lease = service.leaseKeyTap({ press in
            guard press.keyCode == Self.f13 else { return .pass }
            seen.add(1, ordering: .relaxed)
            return .consume
        }) else {
            recorder.observe("service.lease", .refuted, "The key tap was refused although the mouse tap was not.")
            return
        }
        post(Self.burst, tagged: probeTag)
        let delivered = wait(for: Self.burst) { seen.load(ordering: .relaxed) }
        let leaked = caught.withLock { $0.probe } - idle
        recorder.observe(
            "service.lease.deliversAndConsumes", delivered == Self.burst && leaked == 0 ? .confirmed : .refuted,
            "\(delivered) of \(Self.burst) reached the holder; \(leaked) got past it"
        )

        // 3. Events carrying our own tag are passed on and the holder is told nothing (architecture §3.4).
        post(Self.burst, tagged: ownTag)
        let passedOn = wait(for: Self.burst) { caught.withLock { $0.own } }
        let seenOfOurOwn = seen.load(ordering: .relaxed) - delivered
        recorder.observe(
            "service.ownEventsAreLeftAlone", passedOn == Self.burst && seenOfOurOwn == 0 ? .confirmed : .refuted,
            "\(passedOn) of \(Self.burst) passed on; the holder saw \(seenOfOurOwn)"
        )

        // 4. Released: the tap is gone again.
        lease.release()
        let before = caught.withLock { $0.probe }
        post(Self.burst, tagged: probeTag)
        let after = wait(for: before + Self.burst) { caught.withLock { $0.probe } } - before
        let seenAfterRelease = seen.load(ordering: .relaxed) - delivered - seenOfOurOwn
        recorder.observe(
            "service.lease.releaseRemovesTheTap",
            !service.status.keyTapInstalled && after == Self.burst && seenAfterRelease == 0 ? .confirmed : .refuted,
            "keyTapInstalled=\(service.status.keyTapInstalled); \(after) of \(Self.burst) went past; the old holder saw \(seenAfterRelease)"
        )

        // 5. What a surface pays for a lease, through the service and its lock (ACT-19).
        var slowest = 0.0
        for _ in 0..<Self.leaseCycles {
            let start = ContinuousClock.now
            let cycle = service.leaseKeyTap { _ in .pass }
            let acquired = start.duration(to: .now)
            recorder.record("service.lease.acquire", duration: acquired)
            slowest = max(slowest, acquired.milliseconds)
            recorder.measure("service.lease.release") { cycle?.release() }
        }
        recorder.observe(
            "service.lease.acquireIsCheap", slowest <= Self.leaseCeilingMs ? .confirmed : .refuted,
            String(format: "slowest of %d acquisitions %.3f ms; ceiling %.0f ms", Self.leaseCycles, slowest, Self.leaseCeilingMs)
        )

        // 6. The global shortcut (ACT-5). Not a tap: `RegisterEventHotKey` needs no permission, and the
        // key never passes through PappuClip — macOS keeps it from every other app instead.
        let hotkeys = HotkeyService(registrar: SystemHotkeyRegistrar())
        let shortcutPresses = Atomic(0)
        let shortcutListener = Task { [presses = hotkeys.presses] in
            for await _ in presses { shortcutPresses.add(1, ordering: .relaxed) }
        }
        defer { shortcutListener.cancel() }

        let refused = hotkeys.use(HotkeyShortcut(keyCode: 0, modifiers: [.shift]))
        recorder.observe(
            "hotkey.rule", refused == .notAShortcut && hotkeys.current == nil ? .confirmed : .refuted,
            "⇧A came back as \(refused), and the shortcut in force is \(hotkeys.current.map(String.init(describing:)) ?? "none")"
        )

        let outcome = recorder.measure("hotkey.register") { hotkeys.use(Self.shortcut) }
        recorder.observe(
            "hotkey.register", outcome == .registered ? .confirmed : .refuted,
            "⌃⌥⌘F16 came back as \(outcome)"
        )
        if outcome == .registered {
            postShortcut(Self.shortcutPresses)
            let delivered = wait(for: Self.shortcutPresses) { shortcutPresses.load(ordering: .relaxed) }
            recorder.observe(
                "hotkey.delivers", delivered == Self.shortcutPresses ? .confirmed : .refuted,
                "\(delivered) of \(Self.shortcutPresses) posted presses reached the service"
            )

            recorder.measure("hotkey.unregister") { hotkeys.use(nil) }
            postShortcut(Self.shortcutPresses)
            // Never reached, so this waits out its second: what is being shown is that nothing arrives.
            let afterwards = wait(for: delivered + 1) { shortcutPresses.load(ordering: .relaxed) } - delivered
            recorder.observe(
                "hotkey.clearingGivesTheKeyBack", afterwards == 0 ? .confirmed : .refuted,
                "\(afterwards) presses arrived after the shortcut was cleared"
            )
        }

        // 7. Health, and what the taps and the workspace handed over meanwhile.
        let health = service.checkHealth()
        let status = service.status
        recorder.observe(
            "service.health", health.mouse == .healthy && health.key == .notWanted ? .confirmed : .refuted,
            "mouse=\(health.mouse) key=\(health.key) reenables=\(status.reenables) rebuilds=\(status.rebuilds) "
                + "interruptions=\(interruptions.load(ordering: .relaxed))"
        )
        recorder.observe(
            "service.pointerEvents", .info,
            "\(pointerEvents.load(ordering: .relaxed)) pointer events came through the mouse tap during the run"
        )
        // Nothing here sleeps the Mac or switches the session, so this counts what the run happened to
        // see. Zero means no notice arrived, not that the monitor is wrong.
        let checks = monitor.checks
        recorder.observe(
            "monitor.notices", .info,
            "\(checks.total) health notices during the run: "
                + HealthTrigger.allCases.map { "\($0.rawValue)=\(checks.counts[$0] ?? 0)" }.joined(separator: " ")
        )
        service.stop()
    }

    /// Posts the shortcut as a key-down and key-up pair carrying its modifiers in the event's flags.
    private func postShortcut(_ count: Int) {
        let key = CGKeyCode(Self.shortcut.keyCode)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
            else { continue }
            for event in [down, up] {
                event.flags = [.maskControl, .maskAlternate, .maskCommand]
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func post(_ count: Int, tagged tag: SyntheticEventTag) {
        for _ in 0..<count {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.f13, keyDown: true) else { continue }
            tag.mark(event)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Polls until `count` reaches `target` or a second has gone by, and returns the count.
    private func wait(for target: Int, _ count: () -> Int) -> Int {
        let deadline = ContinuousClock.now + .seconds(1)
        while count() < target, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        // A little longer, so that an event too many would show as well.
        Thread.sleep(forTimeInterval: 0.05)
        return count()
    }
}
