import AppKit
import ApplicationServices
import PappuCore
import PappuHarness

/// Spike 4: what it costs to switch on the accessibility tree of a Chromium or Electron app, and
/// whether it can be switched off again between reads.
///
/// What the design assumes, and this run checks:
/// 1. The tree is off until asked for, so strategies 1 and 2 read nothing first. (architecture §4.5)
///    When that is false the app needs no strategy 3, which is the better answer.
/// 2. `AXManualAccessibility` is the switch for Electron and `AXEnhancedUserInterface` for Chromium. (architecture §4.6)
/// 3. The switch can be set "narrowly": on for a read and off again, inside the read stage. (ACT-9)
///    The alternative is enable-and-hold, which costs the app memory and CPU for as long as we run.
/// 4. Switching it on does not move or resize the window.
///
/// What it cannot check: animation. A window that slides or a resize that stutters has the same frame
/// before and after, so the operator resizes and moves the window while the tree is held on and notes what they saw.
struct AXEnableSpike: Spike {
    let id = "spike-4-ax-enable"
    let title = "4 · Switching on the AX tree"
    let question = "Accessibility-tree enabling for Chromium and Electron apps without window-animation side effects."
    let instructions = """
        Run once per Chromium or Electron app, headless. Quit and reopen the app first: a tree that has been on \
        once may come back faster, and the cold figure is the one a first selection pays. Make sure VoiceOver and \
        other assistive tools are off, because they switch the same attributes on. During the countdown, switch to \
        the app and select a sentence. While the log says the tree is held on, move and resize the window and \
        watch for a slide, a jump or a stutter, then note it.
        """

    let options = [
        SpikeOption(
            id: Option.both, title: "Try both attributes",
            detail: "Also the one the app's family is not expected to honour. Off, only the expected one is set.",
            defaultOn: true
        ),
        SpikeOption(
            id: Option.cycles, title: "Enable-per-read cycles",
            detail: "Five rounds of on, read, off. The answer to enable-and-hold versus enable-per-read.", defaultOn: true
        ),
        SpikeOption(
            id: Option.hold, title: "Hold for the operator",
            detail: "Keeps the tree on for 12 s so you can move and resize the window.", defaultOn: true
        ),
    ]

    private enum Option {
        static let both = "both"
        static let cycles = "cycles"
        static let hold = "hold"
    }

    private static let countdownSeconds = 8
    private static let firstReadLimit: Duration = .seconds(5)
    private static let cycleLimit: Duration = .seconds(2)
    private static let cycleCount = 5
    private static let heldReads = 30
    private static let holdSeconds = 12
    /// How long to wait after switching off before asking whether reads still work.
    private static let settle: TimeInterval = 0.5

    func run(recorder: RunRecorder, enabled: Set<String>) {
        recorder.setParameter("accessibility", String(AXIsProcessTrusted()))
        recorder.setParameter("voiceOverRunning", String(onMain { NSWorkspace.shared.isVoiceOverEnabled }))
        guard AXIsProcessTrusted() else {
            recorder.observe("axEnable", .inconclusive, "Accessibility is not granted.")
            return
        }
        for remaining in stride(from: Self.countdownSeconds, to: 0, by: -2) {
            recorder.log("Switch to the app under test and select a sentence. Starting in \(remaining) s.")
            Thread.sleep(forTimeInterval: 2)
        }
        guard let source = onMain({ SourceApp.frontmost() }) else {
            recorder.observe("context.source", .inconclusive, "SpikeLab itself is frontmost, so there is no app to read from.")
            return
        }
        let processAge = source.launchDate.map { Int(Date().timeIntervalSince($0)) }
        recorder.setParameter("app", source.name)
        recorder.setParameter("bundleID", source.bundleID)
        recorder.setParameter("family", source.family)
        recorder.setParameter("processAgeSeconds", processAge.map(String.init) ?? "unknown")
        recorder.log("Testing \(source.name) (\(source.bundleID), family \(source.family)), running for \(processAge.map(String.init) ?? "?") s.")

        let reader = AXReader(pid: source.pid)
        let prior = Dictionary(uniqueKeysWithValues: AXEnableAttribute.allCases.map { ($0, reader.isEnabled($0)) })
        recorder.observe(
            "context.attributesAtStart", .info,
            AXEnableAttribute.allCases.map { "\($0.rawValue)=\(prior[$0]?.map(String.init) ?? "unreadable")" }.joined(separator: " "),
            labels: source.labels
        )

        let baseline = reader.readChain()
        recorder.observe(
            "axEnable.treeIsOffUntilAskedFor", baseline.read.gotText ? .refuted : .confirmed,
            baseline.read.gotText
                ? "Text read through \(baseline.strategy) with nothing switched on. Either the app needs no strategy 3, "
                    + "or something switched the tree on earlier in this process's life."
                : "Nothing read before enabling: \(baseline.read.outcome.rawValue) \(baseline.read.detail)",
            labels: source.labels
        )

        let expected = AXEnableAttribute.preferred(forFamily: source.family)
        let candidates: [AXEnableAttribute] = if let expected, !enabled.contains(Option.both) {
            [expected]
        } else {
            (expected.map { [$0] } ?? []) + AXEnableAttribute.allCases.filter { $0 != expected }
        }
        var holdDone = false
        for attribute in candidates {
            // Each attribute starts from a tree that is off, or the second one measures the first one's work.
            AXEnableAttribute.allCases.forEach { reader.set($0, to: false) }
            Thread.sleep(forTimeInterval: Self.settle)
            let worked = measure(attribute, source: source, reader: reader, recorder: recorder, enabled: enabled, hold: !holdDone)
            holdDone = holdDone || worked
        }

        for attribute in AXEnableAttribute.allCases {
            reader.set(attribute, to: prior[attribute].flatMap { $0 } ?? false)
        }
        recorder.log("Finished, with both attributes back as they were. Note anything that moved, slid or stuttered.")
    }

    /// - Returns: Whether the attribute made the selection readable.
    private func measure(
        _ attribute: AXEnableAttribute, source: SourceApp, reader: AXReader, recorder: RunRecorder,
        enabled: Set<String>, hold: Bool
    ) -> Bool {
        var labels = source.labels
        labels["attribute"] = attribute.rawValue

        let frameBefore = reader.focusedWindowFrame()
        let error = recorder.measure("axEnable.set", labels: labels) { reader.set(attribute, to: true) }
        guard error == .success else {
            recorder.observe("axEnable.accepted", .info, "\(attribute.rawValue) was refused: AXError \(error.rawValue).", labels: labels)
            return false
        }
        let first = reader.pollForText(limit: Self.firstReadLimit)
        guard let elapsed = first.elapsed else {
            recorder.observe(
                "axEnable.makesTheSelectionReadable", .refuted,
                "\(attribute.rawValue) was accepted and nothing read in \(Self.firstReadLimit.components.seconds) s: "
                    + "\(first.last.outcome.rawValue) \(first.last.detail)",
                labels: labels
            )
            reader.set(attribute, to: false)
            return false
        }
        recorder.record("axEnable.timeToFirstRead", labels: labels, duration: elapsed)
        recorder.observe(
            "axEnable.makesTheSelectionReadable", .confirmed,
            "\(attribute.rawValue): first text after \(format(elapsed)) ms through \(first.strategy), "
                + "\(first.last.hasBounds ? "with" : "without") bounds.",
            labels: labels
        )

        // Held on: what a read costs once the tree exists.
        for _ in 0..<Self.heldReads {
            recorder.record("axEnable.readWhileHeld", labels: labels, duration: reader.readChain().read.elapsed)
            Thread.sleep(forTimeInterval: 0.01)
        }

        let frameAfter = reader.focusedWindowFrame()
        if let frameBefore, let frameAfter {
            recorder.observe(
                "axEnable.windowFrameUnchanged", frameBefore == frameAfter ? .confirmed : .refuted,
                "\(describe(frameBefore)) → \(describe(frameAfter))", labels: labels
            )
        } else {
            recorder.observe("axEnable.windowFrameUnchanged", .inconclusive, "The focused window's frame could not be read.", labels: labels)
        }

        if hold, enabled.contains(Option.hold) {
            recorder.log("The tree is held on for \(Self.holdSeconds) s. Move and resize the window now, and watch how it behaves.")
            Thread.sleep(forTimeInterval: TimeInterval(Self.holdSeconds))
            recorder.log("Hands off again, and select the sentence again if you lost it.")
            Thread.sleep(forTimeInterval: 4)
        }

        recorder.measure("axEnable.unset", labels: labels) { _ = reader.set(attribute, to: false) }
        Thread.sleep(forTimeInterval: Self.settle)
        let afterDisable = reader.readChain().read
        recorder.observe(
            "axEnable.readsSurviveSwitchingOff", .info,
            afterDisable.gotText
                ? "Still readable \(Int(Self.settle * 1_000)) ms after switching off. The app keeps its tree, so \"narrowly\" buys nothing here "
                    + "and the first enable is the only cost."
                : "Unreadable again after switching off (\(afterDisable.outcome.rawValue)). Each read pays for an enable.",
            labels: labels
        )

        if enabled.contains(Option.cycles) { cycles(attribute, labels: labels, reader: reader, recorder: recorder) }
        return true
    }

    private func cycles(_ attribute: AXEnableAttribute, labels: [String: String], reader: AXReader, recorder: RunRecorder) {
        var reads = 0
        for _ in 0..<Self.cycleCount {
            reader.set(attribute, to: true)
            if let elapsed = reader.pollForText(limit: Self.cycleLimit).elapsed {
                reads += 1
                recorder.record("axEnable.cycle.timeToRead", labels: labels, duration: elapsed)
            }
            reader.set(attribute, to: false)
            Thread.sleep(forTimeInterval: Self.settle)
        }
        let budget = recorder.budgets.budget(for: .read, on: .accessibility).milliseconds
        let series = recorder.finish().measurements.first { $0.name == "axEnable.cycle.timeToRead" && $0.labels == labels }
        let p95 = series?.summary?.p95
        let fits: Finding.Outcome = if let p95, p95 <= budget, reads == Self.cycleCount { .confirmed } else { .refuted }
        recorder.observe(
            "axEnable.enablePerReadFitsTheReadStage", fits,
            "\(reads)/\(Self.cycleCount) cycles read text; p95 \(p95.map { String(format: "%.1f", $0) } ?? "n/a") ms against "
                + "\(String(format: "%.0f", budget)) ms. Refuted means enable-and-hold, or hotkey-only for this app.",
            labels: labels
        )
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.1f", duration.milliseconds)
    }

    private func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}
