import AppKit
import PappuHarness
import SwiftUI

/// `SpikeLab` opens the window. `SpikeLab --run <spike-id> [--enable a,b] [--state text] [--out dir]`
/// runs one spike without it, writes the result and exits; see Scripts/run-spike.sh.
/// `SpikeLab --pasteboard-fixture <name>` is spike 6 starting its other process.
@main
enum Main {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--run"), arguments.indices.contains(index + 1) {
            runHeadless(spikeID: arguments[index + 1], arguments: arguments)
        } else if let name = value(of: "--pasteboard-fixture", in: arguments) {
            PasteboardFixture.main(pasteboardName: name)
        } else if arguments.contains("--list") {
            SpikeRegistry.all.forEach { print("\($0.id)\t\($0.title)") }
        } else {
            SpikeLabApp.main()
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    private static func runHeadless(spikeID: String, arguments: [String]) -> Never {
        guard let spike = SpikeRegistry.spike(withID: spikeID) else {
            FileHandle.standardError.write(Data("Unknown spike '\(spikeID)'. Try --list.\n".utf8))
            exit(2)
        }
        let enabled = value(of: "--enable", in: arguments).map { Set($0.split(separator: ",").map(String.init)) }
            ?? Set(spike.options.filter(\.defaultOn).map(\.id))
        let store = value(of: "--out", in: arguments).map { ResultsStore(directory: URL(filePath: $0)) }
            ?? SpikeRunner.defaultResultsStore
        let parameters = ["mode": "headless", "tccState": value(of: "--state", in: arguments) ?? "not recorded"]

        Task {
            let recorder = await SpikeRunner.run(spike, enabled: enabled, parameters: parameters) { print($0) }
            do {
                let result = recorder.finish()
                let url = try store.write(result)
                print("\n" + result.summaryText() + "\n\nWrote \(url.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Could not write the result: \(error)\n".utf8))
                exit(1)
            }
        }
        // Spikes hop to the main thread for AppKit calls and put panels on screen, so it has to run an
        // AppKit event loop, not just serve its queue. Accessory, with no Dock icon or menu bar, is what
        // the product will be (PRD §12: LSUIElement).
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }
}

struct SpikeLabApp: App {
    @State private var model = LabModel()

    var body: some Scene {
        Window("SpikeLab", id: "main") {
            LabView(model: model)
                .frame(minWidth: 860, minHeight: 600)
        }
    }
}
