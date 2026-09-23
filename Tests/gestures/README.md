# Gesture corpus

Pointer-event streams with the gestures the recogniser should make of them (architecture §4.2, §17). Every
`*.json` file here is an array of `GestureRecording` (`Packages/PappuKit/Sources/PappuTestSupport`), and
`PappuSelectionTests/everyRecordingReplaysToItsExpectedGestures` replays all of them on every test run.

    {
      "name": "double-click a word",
      "source": "synthetic",
      "events": [
        {"kind": "down", "location": [100, 100], "modifiers": [], "clickCount": 1, "timestampNs": 0, "windowNumber": 7},
        ...
      ],
      "expected": [{"multiClick": {"count": 2, "dragged": false}}]
    }

- `events` are what the mouse tap copies out of each `CGEvent`: coordinates, flags, click state, time and the
  window number under the pointer. No text, no app name, nothing of what was selected.
- `expected` is empty for a non-trigger interaction. PRD §3.3 measures false positives against those, so keep
  adding them: ordinary clicks, scrolling, drags of things that are not text, suppressed selections.
- The replay stands in for the long-press timer, so a press held past 0.5 s needs no extra event.

`synthetic.json` was written by hand from the rules in architecture §4.2. It pins the recogniser's behaviour; it
says nothing about what real apps and real hands produce. Recordings made through the tap go in files named for
where they came from, with `source` set to the app and macOS version. None exist yet: the tap needs the
Accessibility grant (`docs/spikes/RUNBOOK.md`).

This corpus stops at the gesture. Whether a bar should have appeared also depends on the element under the
pointer and on the selection read, which the release corpus of PRD §3.3 records per app.
