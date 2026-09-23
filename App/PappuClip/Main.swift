import AppKit
import PappuApp
import PappuCore

/// The product's entry point. It reads the bundle, builds the app and runs the loop — nothing else
/// (architecture §19).
///
/// Everything that could be decided somewhere testable was: `AppResources` reads the bundle,
/// `AppAssembly` does the wiring, and each part of the app has its own suite. What is left here is the
/// handful of lines that can only run inside a real bundle, and the one decision that belongs to the
/// executable rather than to the library — what to do when the bundle it was launched from is damaged.
@main
enum Main {
    @MainActor
    static func main() {
        // A developer's check of the Runner (M2 week 4), which only a built app can reach.
        if CommandLine.arguments.contains("--check-runner") {
            Task { @MainActor in
                let lines = await RunnerCheck.run()
                for line in lines { print("\(line.passed ? "PASS" : "FAIL")  \(line.name): \(line.detail)") }
                exit(lines.allSatisfy(\.passed) ? 0 : 1)
            }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        // PRD §12: an agent app. No Dock icon and no menu bar of its own; the status item is the whole
        // of the app the user can point at, and every window it opens activates the app by hand.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Holds the assembly for the life of the process, because nothing else would.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var assembly: AppAssembly?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources: AppResources
        do {
            resources = try AppResources.bundled(in: .main)
        } catch {
            // Without the built-in manifests or the detection policies there is no app to bring up: the
            // bar would have no buttons, or there would be no rule saying how text may be read. Saying
            // so and stopping is the honest answer, and it is a packaging fault rather than the user's.
            report(error)
            return
        }

        // The assembly reaches `AXActor` to build the Accessibility probes, so it cannot be built
        // inside this call. Nothing is on screen until it finishes, which is the intended order: the
        // status item and the first-run window go up together, in `start`.
        Task { @MainActor in
            let assembly = await AppAssembly(resources: resources)
            self.assembly = assembly
            await assembly.start()
        }
    }

    /// The taps, the status item and the hotkey all die with the process, so this is about the parts
    /// that talk to something outside it — the trust-database observer and the workspace notices.
    func applicationWillTerminate(_ notification: Notification) {
        guard let assembly else { return }
        self.assembly = nil
        Task { await assembly.stop() }
    }

    private func report(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(ProductIdentity.appName) cannot start."
        alert.informativeText = String(describing: error)
        alert.runModal()
        NSApp.terminate(nil)
    }
}
