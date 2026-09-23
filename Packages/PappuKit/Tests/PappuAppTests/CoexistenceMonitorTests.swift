import Foundation
import PappuApp
import PappuSelection
import PappuTestSupport
import Testing

/// ONB-6's detection and ACT-10j's "or while PopClip is running", from the side the chain cannot test:
/// that the app finds out. The chain's refusal given the flag is `DetectionPolicyTests`'.
@Suite struct CoexistenceMonitorTests {
    private let popClip = "com.pilotmoon.popclip"
    private let maccy = "org.p0deje.Maccy"
    private let editor = "com.example.editor"

    @Test func nothingIsRunningUntilTheWatcherHasSaid() {
        let monitor = CoexistenceMonitor(watcher: FakeRunningApplications(running: [popClip]))
        #expect(monitor.current == .none)
    }

    /// PopClip may have been running since before PappuClip launched. No notice will ever say so, so the
    /// first reading has to come from the list and not from a launch.
    @Test func popClipAlreadyRunningAtLaunchIsSeenAtOnce() {
        let monitor = CoexistenceMonitor(watcher: FakeRunningApplications(running: [editor, popClip]))
        monitor.start()
        #expect(monitor.current == Coexistence(popClipIsRunning: true, clipboardManagerIsRunning: false))
    }

    @Test func popClipLaunchingAndQuittingLaterIsFollowed() {
        let apps = FakeRunningApplications(running: [editor])
        let monitor = CoexistenceMonitor(watcher: apps)
        monitor.start()
        #expect(!monitor.current.popClipIsRunning)

        apps.send([editor, popClip])
        #expect(monitor.current.popClipIsRunning)

        apps.send([editor])
        #expect(!monitor.current.popClipIsRunning)
    }

    /// The two questions are separate: a manager changes the settle and never takes strategy 5 away.
    @Test func aClipboardManagerIsNotPopClip() {
        let monitor = CoexistenceMonitor(watcher: FakeRunningApplications(running: [maccy]))
        monitor.start()
        #expect(monitor.current == Coexistence(popClipIsRunning: false, clipboardManagerIsRunning: true))
    }

    /// What the coordinator and the chain are handed has to keep answering after it was made.
    @Test func theReaderHandedOutSeesEveryLaterChange() {
        let apps = FakeRunningApplications()
        let monitor = CoexistenceMonitor(watcher: apps)
        let reader = monitor.reader
        monitor.start()

        apps.send([popClip, maccy])
        #expect(reader() == Coexistence(popClipIsRunning: true, clipboardManagerIsRunning: true))
    }

    @Test func stoppingStopsWatching() {
        let apps = FakeRunningApplications()
        let monitor = CoexistenceMonitor(watcher: apps)
        monitor.start()
        #expect(apps.isObserving)

        monitor.stop()
        #expect(!apps.isObserving)
        #expect(!apps.send([popClip]))
        #expect(!monitor.current.popClipIsRunning)
    }

    /// Only an exact identifier counts. A prefix match would put any app named after PopClip, or a
    /// PopClip extension's helper, in PopClip's place.
    @Test func onlyTheNamedIdentifiersCount() {
        #expect(Coexistence(running: ["com.pilotmoon.popclip.helper"]) == .none)
    }
}
