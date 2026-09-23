import Foundation
import PappuApp
import PappuCore
import PappuTestSupport
import Testing

/// FLT-3's "which app the selection came from", from the side that has to be right at any moment: four
/// different parts ask, none of them may touch AppKit, and none of them can wait.
@Suite struct FrontmostAppTests {
    @Test func nothingIsInFrontUntilSomethingComesForward() {
        let frontmost = FrontmostApp(activations: FakeApplicationActivations(), ours: 1)
        #expect(frontmost.current == nil)
    }

    @Test func theAppInFrontIsTheLastOneToComeForward() {
        let activations = FakeApplicationActivations()
        let frontmost = FrontmostApp(activations: activations, ours: 1)
        frontmost.start()

        activations.send(TargetApp(pid: 42, bundleID: "com.example.editor"))
        #expect(frontmost.current == TargetApp(pid: 42, bundleID: "com.example.editor"))

        activations.send(TargetApp(pid: 43, bundleID: "com.example.browser"))
        #expect(frontmost.current?.bundleID == "com.example.browser")
    }

    /// The Settings window and the onboarding window both activate the app to take focus. If that made
    /// PappuClip "the app in front", a shortcut pressed straight afterwards would aim at us.
    @Test func ourOwnWindowsDoNotBecomeTheAppInFront() {
        let activations = FakeApplicationActivations()
        let frontmost = FrontmostApp(activations: activations, ours: 7)
        frontmost.start()

        activations.send(TargetApp(pid: 42, bundleID: "com.example.editor"))
        activations.send(TargetApp(pid: 7, bundleID: ProductIdentity.appBundleID))
        #expect(frontmost.current == TargetApp(pid: 42, bundleID: "com.example.editor"))
    }

    /// The same rule for the app the launch started in, which is read from AppKit rather than observed.
    @Test func anAppSeededAtLaunchIsTheAppInFrontUnlessItIsUs() {
        let seeded = FrontmostApp(
            activations: FakeApplicationActivations(),
            initial: TargetApp(pid: 42, bundleID: "com.example.editor"),
            ours: 7
        )
        #expect(seeded.current?.pid == 42)

        let seededWithUs = FrontmostApp(
            activations: FakeApplicationActivations(),
            initial: TargetApp(pid: 7, bundleID: ProductIdentity.appBundleID),
            ours: 7
        )
        #expect(seededWithUs.current == nil)
    }

    /// What the gate and the verifier are handed is a closure, and it has to keep answering for the life
    /// of the app rather than closing over whatever was in front when it was made (architecture §4.4).
    @Test func theReaderHandedOutSeesEveryLaterChange() {
        let activations = FakeApplicationActivations()
        let frontmost = FrontmostApp(activations: activations, ours: 1)
        frontmost.start()
        let reader = frontmost.reader

        #expect(reader() == nil)
        activations.send(TargetApp(pid: 42, bundleID: "com.example.editor"))
        #expect(reader()?.pid == 42)
    }

    @Test func stoppingLeavesTheLastAnswerStandingAndHearsNoMore() {
        let activations = FakeApplicationActivations()
        let frontmost = FrontmostApp(activations: activations, ours: 1)
        frontmost.start()
        activations.send(TargetApp(pid: 42, bundleID: "com.example.editor"))
        frontmost.stop()

        #expect(!activations.isObserving)
        #expect(!activations.send(TargetApp(pid: 43, bundleID: "com.example.browser")))
        #expect(frontmost.current?.pid == 42)
    }
}
