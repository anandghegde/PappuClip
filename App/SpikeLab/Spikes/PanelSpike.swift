import AppKit
import PappuCore
import PappuHarness

/// Spike 1: which panel configuration shows above fullscreen apps, and whether a key-capable
/// non-activating panel leaves the source app's focus alone.
///
/// What the design assumes, and this run checks:
/// 1. A borderless non-activating panel that joins all Spaces and is a full-screen auxiliary shows over
///    a fullscreen app, in every Space and under Stage Manager. The level is open. (architecture §7, PRD §12)
/// 2. Showing the pre-built panel costs a small part of the 30 ms render stage. (PRD §11.1)
/// 3. While a key-capable non-activating panel is key, the source app stays frontmost and its AX focused
///    element and selection do not change, and key presses reach the panel. (BAR-1, RUN-1c) The
///    system-wide focus is recorded apart from the source app's own: it follows the keyboard to our
///    panel, so anything that verifies a destination has to ask the source app, not the system.
/// 4. When that panel closes, focus is where it was with nothing done to restore it. (BAR-1)
///
/// What it cannot check: whether a person could see the panel. AppKit and the window server both say
/// "on screen" for a window that a fullscreen Space is covering, which is the reason sources disagree.
/// Every panel shows a number; the operator writes down the ones they saw.
struct PanelSpike: Spike {
    let id = "spike-1-panel"
    let title = "1 · Panel above fullscreen, and focus"
    let question = "Which window level and collection behaviour reliably show the panel above fullscreen apps on macOS 15, 26 and the current beta."
    let instructions = """
        Run once per setting and name it in the field below: a normal Space, a fullscreen app, a second Space, \
        Stage Manager, a second display. Prefer Scripts/run-spike.sh, where SpikeLab is an accessory app like the \
        product; from this window it is a regular app, which may behave differently. During the countdown, switch \
        to the app under test, click into a text field and select some words. Numbered orange panels then appear \
        one at a time near the top of the screen the pointer is on. Write down every number you saw. Keep your \
        hands off the keyboard and mouse until the log says the run is finished.
        """

    let options = [
        SpikeOption(
            id: Option.matrix, title: "Level × behaviour matrix",
            detail: "16 panels, about a second each.", defaultOn: true
        ),
        SpikeOption(
            id: Option.focus, title: "Key-capable panel and AX focus",
            detail: "Needs Accessibility. With post-event access it also sends F13 to see where keys go.", defaultOn: true
        ),
    ]

    private enum Option {
        static let matrix = "matrix"
        static let focus = "focus"
    }

    private static let countdownSeconds = 8
    private static let dwell: Duration = .milliseconds(700)
    private static let gap: Duration = .milliseconds(200)
    private static let showCycles = 30
    /// A third of the render stage: the rest is for laying out and drawing the buttons.
    private static let showCeilingMs = 10.0
    private static let f13: CGKeyCode = 105

    func run(recorder: RunRecorder, enabled: Set<String>) {
        let lab = onMain { PanelLab() }
        defer { onMain { lab.tearDown() } }

        recorder.setParameter("activationPolicy", onMain { lab.activationPolicy })
        recorder.setParameter("screens", String(onMain { NSScreen.screens.count }))
        recorder.setParameter("accessibility", String(AXIsProcessTrusted()))

        for remaining in stride(from: Self.countdownSeconds, to: 0, by: -2) {
            recorder.log("Switch to the app and Space under test and select some text. Starting in \(remaining) s.")
            Thread.sleep(forTimeInterval: 2)
        }

        if !onMain({ lab.pinSource() }) {
            recorder.observe("context.source", .inconclusive, "SpikeLab itself is frontmost, so there is no source app to watch.")
        }
        let context = onMain { (lab.focus(), lab.frontmostWindowCoversAScreen()) }
        recorder.observe("context.atStart", .info, "\(context.0.summary) frontWindowCoversScreen=\(context.1)")

        if enabled.contains(Option.matrix) { matrix(recorder: recorder, lab: lab) }
        showCost(recorder: recorder, lab: lab)
        if enabled.contains(Option.focus) { focus(recorder: recorder, lab: lab) }

        let end = onMain { lab.focus() }
        if end.frontmostBundleID != context.0.frontmostBundleID {
            recorder.observe(
                "context.frontmostChangedDuringRun", .info,
                "\(context.0.frontmostBundleID) → \(end.frontmostBundleID). Someone switched apps, or a panel activated us."
            )
        }
        recorder.log("Finished. Write down the numbers of the panels you saw.")
    }

    // MARK: 1. Which configurations show

    private func matrix(recorder: RunRecorder, lab: PanelLab) {
        onMain { lab.build(keyable: false) }
        var shown: [Int] = []
        for (index, configuration) in PanelConfiguration.matrix.enumerated() {
            let number = index + 1
            let before = onMain { lab.focus() }
            onMain {
                lab.apply(configuration, caption: "\(number) · \(configuration.levelName) · \(configuration.behaviourName)")
                _ = lab.show(makeKey: false)
            }
            Thread.sleep(forTimeInterval: Self.dwell.milliseconds / 1_000)
            let (settled, after) = onMain { (lab.sample(), lab.focus()) }
            onMain { lab.hide() }
            Thread.sleep(forTimeInterval: Self.gap.milliseconds / 1_000)

            var labels = configuration.labels
            labels["panel"] = String(number)
            if settled.reportedShown { shown.append(number) }
            recorder.observe("panel.reportedShown", .info, "#\(number) \(settled.summary)", labels: labels)
            if settled.appIsActive || after.frontmostBundleID != before.frontmostBundleID {
                recorder.observe(
                    "panel.activatedUs", .refuted,
                    "#\(number) took activation: \(before.frontmostBundleID) → \(after.frontmostBundleID) appActive=\(settled.appIsActive)",
                    labels: labels
                )
            }
        }
        recorder.observe(
            "panel.matrix.reportedShown", .info,
            "The system reports these as on screen: \(shown.map(String.init).joined(separator: ", ")). Compare with what was seen."
        )
    }

    // MARK: 2. What showing the pre-built panel costs

    private func showCost(recorder: RunRecorder, lab: PanelLab) {
        onMain {
            recorder.measure("panel.build") { lab.build(keyable: false) }
            lab.apply(.designDefault, caption: "timing")
        }
        for _ in 0..<Self.showCycles {
            let cost = onMain { lab.show(makeKey: false) }
            recorder.record("panel.show", labels: PanelConfiguration.designDefault.labels, duration: cost)
            Thread.sleep(forTimeInterval: 0.03)
            onMain { recorder.measure("panel.hide") { lab.hide() } }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let p95 = recorder.finish().measurements.first { $0.name == "panel.show" }?.summary?.p95 ?? .infinity
        recorder.observe(
            "panel.showIsCheap", p95 <= Self.showCeilingMs ? .confirmed : .refuted,
            "p95 \(String(format: "%.2f", p95)) ms against a ceiling of \(Self.showCeilingMs) ms, "
                + "out of a \(BudgetTable.initial.budget(for: .render, on: .accessibility).milliseconds) ms render stage"
        )
    }

    // MARK: 3. Focus while a key-capable panel is key

    private func focus(recorder: RunRecorder, lab: PanelLab) {
        guard AXIsProcessTrusted() else {
            recorder.observe("focus", .inconclusive, "Accessibility is not granted, so another app's focus cannot be read.")
            return
        }
        let before = onMain { lab.focus() }
        recorder.log("Focus before: \(before.summary)")
        guard before.focusedElementHash != nil, before.frontmostBundleID != Bundle.main.bundleIdentifier else {
            recorder.observe("focus", .inconclusive, "No focused element in another app to watch: \(before.summary)")
            return
        }

        onMain {
            lab.build(keyable: true)
            lab.apply(.designDefault, caption: "key-capable panel")
            lab.startCountingKeys(keyCode: Self.f13)
            _ = lab.show(makeKey: true)
        }
        Thread.sleep(forTimeInterval: 0.6)
        let (during, state) = onMain { (lab.focus(), lab.sample()) }
        recorder.log("Focus while key: \(during.summary); panel \(state.summary)")

        recorder.observe("focus.panelBecomesKey", state.isKey ? .confirmed : .refuted, state.summary)
        recorder.observe(
            "focus.systemWideFocusWhileKey", .info,
            "System-wide AX focus is in \(during.systemFocusIsOurs ? "our panel" : "another app"); NSApp.isActive=\(state.appIsActive); "
                + "the source app reports isActive=\(during.sourceIsActive.map(String.init) ?? "?")"
        )
        recorder.observe(
            "focus.sourceAppStaysFrontmost", during.frontmostBundleID == before.frontmostBundleID ? .confirmed : .refuted,
            "\(before.frontmostBundleID) → \(during.frontmostBundleID)"
        )
        recorder.observe(
            "focus.sourceFocusedElementUnchangedWhileKey", during.sameElement(as: before) ? .confirmed : .refuted,
            "before: \(before.summary); while key: \(during.summary)"
        )
        if before.selectionLength ?? 0 > 0 {
            recorder.observe(
                "focus.selectionUnchangedWhileKey", during.sameSelection(as: before) ? .confirmed : .refuted,
                "selection length \(before.selectionLength ?? 0) → \(during.selectionLength.map(String.init) ?? "unreadable")"
            )
        } else {
            recorder.observe("focus.selectionUnchangedWhileKey", .inconclusive, "Nothing was selected, or the app does not expose it.")
        }

        if CGPreflightPostEventAccess() {
            for keyDown in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: Self.f13, keyDown: keyDown)?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.3)
            let seen = onMain { lab.keyDownsSeen }
            recorder.observe(
                "focus.keysReachTheKeyPanel", seen > 0 ? .confirmed : .refuted,
                "An F13 posted at the HID tap reached the panel \(seen) time(s) while the source app was frontmost."
            )
        } else {
            recorder.observe("focus.keysReachTheKeyPanel", .inconclusive, "No post-event access. Type into the panel by hand and note it.")
        }

        onMain { lab.tearDown() }
        Thread.sleep(forTimeInterval: 0.4)
        let after = onMain { lab.focus() }
        recorder.log("Focus after close: \(after.summary)")
        recorder.observe(
            "focus.backWhereItWasAfterClose",
            after.sameElement(as: before) && after.frontmostBundleID == before.frontmostBundleID ? .confirmed : .refuted,
            "before: \(before.summary); after: \(after.summary)"
        )
    }
}
