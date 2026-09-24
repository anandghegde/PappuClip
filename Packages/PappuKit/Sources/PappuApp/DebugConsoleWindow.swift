import AppKit
import Observation
import PappuDiagnostics
import SwiftUI

/// The Debug Console (DIA-1): what extensions printed, and how their actions ended, since launch.
///
/// A first version. It lists the lines, most recent last, and offers Clear and Copy All; filtering by
/// extension and the sample-selection runner are later work. What it shows is `DebugConsole`, which
/// keeps them in memory only — closing the window loses nothing, and quitting loses everything.
@MainActor
public final class DebugConsoleWindow {
    private let model: DebugConsoleModel
    private var window: NSWindow?

    public init(console: DebugConsole) {
        model = DebugConsoleModel(console: console)
    }

    public func show() {
        let window = window ?? make()
        self.window = window
        model.watch()
        // An agent app's window cannot become key until the app is active (as for Settings).
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: DebugConsoleView(model: model))
        window.title = AppStrings.consoleWindowTitle
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("app.pappuclip.debugConsole")
        window.center()
        return window
    }
}

/// The console's lines as the view draws them, refreshed on each of the console's change signals.
@MainActor
@Observable
final class DebugConsoleModel {
    private(set) var entries: [ConsoleEntry] = []
    @ObservationIgnored private let console: DebugConsole
    @ObservationIgnored private var watching: Task<Void, Never>?

    init(console: DebugConsole) {
        self.console = console
    }

    /// Starts following the console, once; the window is kept for the life of the app, so is this.
    func watch() {
        entries = console.entries
        guard watching == nil else { return }
        let changes = console.changes()
        watching = Task { [weak self, console] in
            for await _ in changes {
                self?.entries = console.entries
            }
        }
    }

    func clear() {
        console.clear()
    }

    func copyAll() {
        let text = entries.map(Self.line).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func line(_ entry: ConsoleEntry) -> String {
        let time = entry.date.formatted(date: .omitted, time: .standard)
        return "\(time)  \(entry.source)  \(message(entry))"
    }

    /// The kind's words and the extension's, together. A load failure with no reason says only that.
    static func message(_ entry: ConsoleEntry) -> String {
        guard let label = AppStrings.consoleLabel(entry.kind) else { return entry.text }
        return entry.text.isEmpty ? label : "\(label): \(entry.text)"
    }
}

struct DebugConsoleView: View {
    let model: DebugConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                Text(AppStrings.consoleEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollViewReader { proxy in
                    List(model.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    .onChange(of: model.entries.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(AppStrings.consoleCopy) { model.copyAll() }
                    .disabled(model.entries.isEmpty)
                Button(AppStrings.consoleClear) { model.clear() }
                    .disabled(model.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 220)
    }

    private func row(_ entry: ConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            Text(entry.source)
                .fontWeight(.medium)
            Text(DebugConsoleModel.message(entry))
                .foregroundStyle(entry.kind == .printed ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
    }
}
