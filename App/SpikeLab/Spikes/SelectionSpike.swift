import AppKit
import ApplicationServices
import PappuCore
import PappuHarness

/// Spike 3: how often, and how fast, each selection strategy reads the selection in one app.
///
/// One run covers the app that is frontmost when the countdown ends. The matrix is a run per Tier A app.
///
/// What the design assumes, and this run checks:
/// 1. Strategies 1–3 reach the gating apps inside the 70 ms read stage, earlier failures included. (PRD §11.1, ACT-9)
/// 2. A strategy that does not apply fails fast, so trying it first costs the chain little. (architecture §4.5)
/// 3. Bounds come with the text, so the bar can be placed by the selection and not the pointer. (BAR-3)
/// 4. Strategy 4 needs Automation consent and a browser developer setting, so its coverage is low. (architecture §19 item 5)
/// 5. Synthetic ⌘C fits the 270 ms fallback read stage. (PRD §11.1) Whether it is *safe* is spike 6's question.
/// 6. Every strategy that answers reads the same text.
///
/// What it cannot check: whether the text is what the operator selected. It records length and digest,
/// never the text, and the operator confirms the length in the notes.
struct SelectionSpike: Spike {
    let id = "spike-3-selection"
    let title = "3 · Selection strategies per app"
    let question = "Selection-read success rate and latency per strategy across Tier A apps."
    let instructions = """
        Run once per app of the matrix, headless (Scripts/run-spike.sh) so SpikeLab stays in the background. \
        During the countdown, switch to the app under test and select a sentence in the kind of text that matters \
        there: a web page, a message, an editor buffer. Then keep your hands off until the log says the run is \
        finished. Note the number of characters you selected. Strategies 4 and 5 are off by default: 4 shows an \
        Automation prompt the first time, and 5 puts the selection on your clipboard for a moment and then puts \
        back what was there.
        """

    let options = [
        SpikeOption(
            id: Option.scriptedSelect, title: "Select by scripted double-click",
            detail: "Double-clicks at the pointer when the countdown ends, so rest the pointer on a word. Needs post-event access.",
            defaultOn: false
        ),
        SpikeOption(
            id: Option.axEnable, title: "Strategy 3: switch on the AX tree",
            detail: "Only if strategies 1 and 2 read nothing. Restores the attribute afterwards. Spike 4 measures this properly.",
            defaultOn: true
        ),
        SpikeOption(
            id: Option.appleScript, title: "Strategy 4: AppleScript",
            detail: "Browsers only. Shows an Automation prompt the first time.", defaultOn: false
        ),
        SpikeOption(
            id: Option.syntheticCopy, title: "Strategy 5: synthetic ⌘C",
            detail: "Overwrites the clipboard for a moment, then restores it. Needs post-event access.", defaultOn: false
        ),
    ]

    private enum Option {
        static let scriptedSelect = "scriptedSelect"
        static let axEnable = "axEnable"
        static let appleScript = "appleScript"
        static let syntheticCopy = "syntheticCopy"
    }

    private static let countdownSeconds = 8
    private static let iterations = 30
    /// Few, because each one is a copy the operator's clipboard manager sees.
    private static let copyIterations = 5
    private static let scriptIterations = 10
    private static let enableLimit: Duration = .seconds(3)
    private static let copyLimit: Duration = .seconds(1)
    private static let keyC: CGKeyCode = 8

    func run(recorder: RunRecorder, enabled: Set<String>) {
        recorder.setParameter("accessibility", String(AXIsProcessTrusted()))
        recorder.setParameter("postEvent", String(CGPreflightPostEventAccess()))
        guard AXIsProcessTrusted() else {
            recorder.observe("selection", .inconclusive, "Accessibility is not granted, so no strategy can run.")
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
        recorder.setParameter("app", source.name)
        recorder.setParameter("bundleID", source.bundleID)
        recorder.setParameter("family", source.family)
        recorder.log("Reading from \(source.name) (\(source.bundleID), family \(source.family)).")

        if enabled.contains(Option.scriptedSelect) { scriptedDoubleClick(recorder: recorder) }

        let reader = AXReader(pid: source.pid)
        var digests: [String: Set<String>] = [:]
        var working: [String] = []

        let attributes = sample("ax", source: source, recorder: recorder) { reader.readAttributes() }
        let markers = sample("webkitMarkers", source: source, recorder: recorder) { reader.readTextMarkers() }
        for (strategy, tally) in [("ax", attributes), ("webkitMarkers", markers)] where tally.texts > 0 {
            digests[strategy] = tally.digests
            working.append(strategy)
        }
        chain(source: source, reader: reader, recorder: recorder)

        if enabled.contains(Option.axEnable), working.isEmpty,
           let tally = axEnable(source: source, reader: reader, recorder: recorder) {
            digests["axEnable"] = tally.digests
            working.append("axEnable")
        }
        if enabled.contains(Option.appleScript), let tally = appleScript(source: source, recorder: recorder), tally.texts > 0 {
            digests["appleScript"] = tally.digests
            working.append("appleScript")
        }
        if enabled.contains(Option.syntheticCopy), let tally = syntheticCopy(source: source, recorder: recorder), tally.texts > 0 {
            digests["syntheticCopy"] = tally.digests
            working.append("syntheticCopy")
        }

        agreement(digests, source: source, recorder: recorder)
        recorder.observe(
            "policy.strategiesThatRead", .info,
            working.isEmpty ? "None. This app is a candidate for hotkey-only, or for the fallback path."
                : "In chain order: \(working.joined(separator: ", ")). The first is what DetectionPolicies.json should lead with.",
            labels: source.labels
        )
        recorder.log("Finished. Note how many characters you selected, and anything that moved or flashed.")
    }

    // MARK: Strategies 1 and 2

    private func sample(_ strategy: String, source: SourceApp, recorder: RunRecorder, read: () -> SelectionRead) -> ReadTally {
        var labels = source.labels
        labels["strategy"] = strategy
        var tally = ReadTally()
        for _ in 0..<Self.iterations {
            let result = read()
            tally.add(result)
            labels["outcome"] = result.gotText ? "text" : "noText"
            recorder.record("selection.read", labels: labels, duration: result.elapsed)
            Thread.sleep(forTimeInterval: 0.01)
        }
        labels["outcome"] = nil
        recorder.observe("strategy.\(strategy)", .info, "\(tally.texts)/\(tally.total) read text. \(tally.summary)", labels: labels)
        if tally.texts > 0 {
            recorder.observe(
                "strategy.\(strategy).boundsComeWithTheText", tally.withBounds == tally.texts ? .confirmed : .refuted,
                "\(tally.withBounds) of \(tally.texts) reads had bounds. Without them the bar goes by the pointer (BAR-3).",
                labels: labels
            )
        }
        return tally
    }

    /// Strategies 1 then 2 in order, timed as one read, because the budget is spent by the failures too.
    private func chain(source: SourceApp, reader: AXReader, recorder: RunRecorder) {
        var labels = source.labels
        labels["strategy"] = "chain(ax,webkitMarkers)"
        var texts = 0
        for _ in 0..<Self.iterations {
            let (read, _) = reader.readChain()
            if read.gotText { texts += 1 }
            recorder.record("selection.chain", labels: labels, duration: read.elapsed)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let budget = recorder.budgets.budget(for: .read, on: .accessibility).milliseconds
        let p95 = recorder.finish().measurements.first { $0.name == "selection.chain" }?.summary?.p95 ?? .infinity
        guard texts > 0 else {
            recorder.observe(
                "chain.failsFast", p95 <= budget / 2 ? .confirmed : .refuted,
                "Strategies 1 and 2 read nothing and cost p95 \(format(p95)) ms of the \(format(budget)) ms read stage before strategy 3 starts.",
                labels: labels
            )
            return
        }
        recorder.observe(
            "chain.readsInsideTheReadStage", texts == Self.iterations && p95 <= budget ? .confirmed : .refuted,
            "\(texts)/\(Self.iterations) read text; p95 \(format(p95)) ms against \(format(budget)) ms.", labels: labels
        )
    }

    // MARK: Strategy 3

    private func axEnable(source: SourceApp, reader: AXReader, recorder: RunRecorder) -> ReadTally? {
        let candidates = AXEnableAttribute.preferred(forFamily: source.family).map { [$0] } ?? AXEnableAttribute.allCases
        for attribute in candidates {
            var labels = source.labels
            labels["strategy"] = "axEnable"
            labels["attribute"] = attribute.rawValue
            let before = reader.isEnabled(attribute)
            let error = recorder.measure("axEnable.set", labels: labels) { reader.set(attribute, to: true) }
            guard error == .success else {
                recorder.observe("strategy.axEnable", .info, "\(attribute.rawValue) was refused: AXError \(error.rawValue).", labels: labels)
                continue
            }
            let poll = reader.pollForText(limit: Self.enableLimit)
            defer {
                // Put back what was there. Unreadable counts as off: the attribute exists for tools like this one.
                if before != true { reader.set(attribute, to: false) }
            }
            guard let elapsed = poll.elapsed else {
                recorder.observe(
                    "strategy.axEnable", .info,
                    "\(attribute.rawValue) was accepted, and nothing read in \(Self.enableLimit.components.seconds) s: \(poll.last.detail)",
                    labels: labels
                )
                continue
            }
            recorder.record("axEnable.timeToFirstRead", labels: labels, duration: elapsed)
            var tally = ReadTally()
            tally.add(poll.last)
            let budget = recorder.budgets.budget(for: .read, on: .accessibility)
            recorder.observe(
                "strategy.axEnable", .info,
                "\(attribute.rawValue) (was \(before.map(String.init) ?? "unreadable")): first text after \(format(elapsed.milliseconds)) ms "
                    + "through \(poll.strategy). \(elapsed <= budget ? "Inside" : "Outside") the \(format(budget.milliseconds)) ms read stage, "
                    + "so enable-per-read \(elapsed <= budget ? "may be" : "is not") an option. Process age "
                    + "\(source.launchDate.map { String(Int(Date().timeIntervalSince($0))) } ?? "?") s.",
                labels: labels
            )
            return tally
        }
        return nil
    }

    // MARK: Strategy 4

    /// Page JavaScript through the browser's scripting dictionary. NSAppleScript belongs to the main thread.
    private func appleScript(source: SourceApp, recorder: RunRecorder) -> ReadTally? {
        var labels = source.labels
        labels["strategy"] = "appleScript"
        let javascript = "window.getSelection().toString()"
        let body: String
        switch source.family {
        case "webkit": body = "do JavaScript \"\(javascript)\" in front document"
        case "chromium": body = "execute front window's active tab javascript \"\(javascript)\""
        default:
            recorder.observe("strategy.appleScript", .info, "Not a browser family with a scripting dictionary for this.", labels: labels)
            return nil
        }
        let text = "tell application id \"\(source.bundleID)\" to \(body)"

        var tally = ReadTally()
        var lastError = ""
        for _ in 0..<Self.scriptIterations {
            let start = ContinuousClock.now
            let (result, error): (String?, String?) = onMain {
                var info: NSDictionary?
                // Compiled each time: the first execution is what an attempt pays, and that is the number wanted.
                let output = NSAppleScript(source: text)?.executeAndReturnError(&info)
                guard let info else { return (output?.stringValue ?? "", nil) }
                return (nil, "error \(info[NSAppleScript.errorNumber] ?? "?"): \(info[NSAppleScript.errorMessage] ?? "")")
            }
            var read = result.map { SelectionRead(text: $0, hasBounds: false) } ?? SelectionRead(outcome: .failed, detail: error ?? "")
            read.elapsed = start.duration(to: .now)
            tally.add(read)
            labels["outcome"] = read.gotText ? "text" : "noText"
            recorder.record("selection.read", labels: labels, duration: read.elapsed)
            if let error {
                lastError = error
                // A refusal is the same every time, and a denied prompt should not be asked for again.
                break
            }
        }
        labels["outcome"] = nil
        recorder.observe(
            "strategy.appleScript.coverageIsLow", tally.texts == 0 ? .confirmed : .refuted,
            tally.texts == 0
                ? "No text. \(lastError) -1743 is a refused Automation prompt; 12 or a message about JavaScript is the browser's developer setting."
                : "\(tally.texts)/\(tally.total) read text on a browser with the developer setting on. \(tally.summary)",
            labels: labels
        )
        return tally
    }

    // MARK: Strategy 5

    /// ⌘C, wait for the change count, read, put back what was there.
    ///
    /// This is the measurement only. The broker's rules for ownership, draining and transient marking
    /// are spike 6's subject; the one rule kept here is never to restore over a write that is not ours.
    private func syntheticCopy(source: SourceApp, recorder: RunRecorder) -> ReadTally? {
        var labels = source.labels
        labels["strategy"] = "syntheticCopy"
        guard CGPreflightPostEventAccess() else {
            recorder.observe("strategy.syntheticCopy", .inconclusive, "No post-event access, so ⌘C cannot be sent.", labels: labels)
            return nil
        }
        let pasteboard = NSPasteboard.general
        var tally = ReadTally()
        for _ in 0..<Self.copyIterations {
            let snapshot = recorder.measure("syntheticCopy.snapshot", labels: labels) { PasteboardSnapshot(pasteboard) }
            let start = ContinuousClock.now
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyC, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            while pasteboard.changeCount == snapshot.changeCount, start.duration(to: .now) < Self.copyLimit {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard pasteboard.changeCount != snapshot.changeCount else {
                var read = SelectionRead(outcome: .timedOut, detail: "the change count did not move in \(Self.copyLimit.components.seconds) s")
                read.elapsed = start.duration(to: .now)
                tally.add(read)
                continue
            }
            recorder.record("syntheticCopy.untilChangeCount", labels: labels, duration: start.duration(to: .now))
            var read = SelectionRead(text: pasteboard.string(forType: .string) ?? "", hasBounds: false)
            read.elapsed = start.duration(to: .now)
            tally.add(read)
            labels["outcome"] = read.gotText ? "text" : "noText"
            recorder.record("selection.read", labels: labels, duration: read.elapsed)
            labels["outcome"] = nil

            if pasteboard.changeCount == snapshot.changeCount + 1 {
                recorder.measure("syntheticCopy.restore", labels: labels) { snapshot.restore(to: pasteboard) }
            } else {
                recorder.observe(
                    "syntheticCopy.someoneElseWrote", .info,
                    "The change count moved by \(pasteboard.changeCount - snapshot.changeCount), not 1. Left alone; stopping.",
                    labels: labels
                )
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let budget = recorder.budgets.budget(for: .read, on: .clipboardFallback).milliseconds
        let series = recorder.finish().measurements.first {
            $0.name == "selection.read" && $0.labels["strategy"] == "syntheticCopy" && $0.labels["outcome"] == "text"
        }
        let p95 = series?.summary?.p95
        let fits: Finding.Outcome = if let p95, p95 <= budget, tally.alwaysText { .confirmed } else { .refuted }
        recorder.observe(
            "strategy.syntheticCopy.fitsTheFallbackReadStage", fits,
            "\(tally.texts)/\(tally.total) read text; p95 \(p95.map(format) ?? "n/a") ms against \(format(budget)) ms, "
                + "which the failed strategies before it also spend from. \(tally.summary)",
            labels: labels
        )
        return tally
    }

    // MARK: Gesture

    private func scriptedDoubleClick(recorder: RunRecorder) {
        guard CGPreflightPostEventAccess(), let location = CGEvent(source: nil)?.location else {
            recorder.observe("gesture.scriptedSelect", .inconclusive, "No post-event access. Select by hand.")
            return
        }
        for click in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
        }
        // The read must not race the app's own handling of the second mouse-up.
        Thread.sleep(forTimeInterval: 0.3)
        recorder.observe("gesture.scriptedSelect", .info, "Double-clicked at the pointer.")
    }

    // MARK: Agreement

    private func agreement(_ digests: [String: Set<String>], source: SourceApp, recorder: RunRecorder) {
        guard digests.count > 1 else { return }
        let all = digests.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let detail = digests.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.sorted().joined(separator: "/"))" }
        recorder.observe(
            "strategies.readTheSameText", all.count == 1 ? .confirmed : .refuted,
            "Digests by strategy. \(detail.joined(separator: "; ")). A difference is often whitespace or a trailing newline, and FLT-2 will care.",
            labels: source.labels
        )
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}

/// Everything on a pasteboard, copied out so it can be written back.
///
/// Reading every type makes a lazy provider deliver, which is one of the costs spike 6 measures.
struct PasteboardSnapshot {
    let changeCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { pairs in
            let item = NSPasteboardItem()
            pairs.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
