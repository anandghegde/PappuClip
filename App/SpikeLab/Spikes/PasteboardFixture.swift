import AppKit
import PappuHarness

/// The other process of spike 6: SpikeLab started again as `SpikeLab --pasteboard-fixture <name>`, playing
/// an app that owns a pasteboard. A provider in the spike's own process would be called in line and
/// measure nothing; this one is asked through the pasteboard server, as a real source app is.
///
/// It reads one command per line on standard input and answers with one event per line on standard output:
///
///     write <afterMs> <kind> <payload>    ->  wrote <kind> <payload> <startNanos> <clearedNanos> <endNanos> <changeCount>
///     burst <count> <gapMicros>           ->  burstDone <count> <changeCount>
///     quit
///
/// Times are `CLOCK_UPTIME_RAW` nanoseconds, which both processes read from the same clock.
enum PasteboardFixture {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let blobType = NSPasteboard.PasteboardType("app.pappuclip.spike.blob")

    static func uptimeNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    @MainActor
    static func main(pasteboardName: String) -> Never {
        nonisolated(unsafe) let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        let writer = Writer(pasteboard: pasteboard)
        let reader = Thread {
            while let line = readLine() {
                let words = line.split(separator: " ").map(String.init)
                switch words.first {
                case "write" where words.count == 4:
                    let after = TimeInterval(words[1]).map { $0 / 1_000 } ?? 0
                    // A thread per command, so that offsets are kept to a fraction of a millisecond
                    // and two commands can be pending at once.
                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: after)
                        DispatchQueue.main.sync { writer.write(kind: words[2], payload: words[3]) }
                    }
                case "burst" where words.count == 3:
                    let count = Int(words[1]) ?? 0
                    let gap = (TimeInterval(words[2]) ?? 0) / 1_000_000
                    Thread.detachNewThread {
                        for index in 0..<count {
                            pasteboard.clearContents()
                            pasteboard.setString("burst-\(index)", forType: .string)
                            Thread.sleep(forTimeInterval: gap)
                        }
                        emit("burstDone \(count) \(pasteboard.changeCount)")
                    }
                case "quit":
                    exit(0)
                default:
                    emit("unknown \(line)")
                }
            }
            // The spike went away.
            exit(0)
        }
        reader.name = "fixture.commands"
        reader.start()

        // Lazy data is asked for through the main run loop, so there has to be one.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        emit("ready \(getpid())")
        app.run()
        exit(0)
    }

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Main thread only, like an app's copy command.
    final class Writer: @unchecked Sendable {
        private let pasteboard: NSPasteboard
        /// A pasteboard does not retain its providers.
        private var providers: [LazyProvider] = []
        private var promiseDelegate = PromiseDelegate()

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }

        func write(kind: String, payload: String) {
            let parts = kind.split(separator: ":").map(String.init)
            let start = uptimeNanos()
            var cleared = start
            func clear() {
                pasteboard.clearContents()
                cleared = uptimeNanos()
            }

            switch parts[0] {
            case "text":
                clear()
                pasteboard.setString(payload, forType: .string)

            case "declare":
                // The pre-10.6 way, which plenty of apps and toolkits still use.
                pasteboard.declareTypes([.string], owner: nil)
                cleared = uptimeNanos()
                pasteboard.setString(payload, forType: .string)

            case "gapped":
                // An app that clears, does some work, and only then writes.
                clear()
                Thread.sleep(forTimeInterval: (TimeInterval(parts.dropFirst().first ?? "") ?? 0) / 1_000)
                pasteboard.setString(payload, forType: .string)

            case "rich":
                clear()
                let item = NSPasteboardItem()
                item.setString(payload, forType: .string)
                item.setData(Data("{\\rtf1\\ansi \(payload)}".utf8), forType: .rtf)
                item.setString("<p>\(payload)</p>", forType: .html)
                pasteboard.writeObjects([item])

            case "multi":
                clear()
                pasteboard.writeObjects((0..<3).map { index in
                    let item = NSPasteboardItem()
                    item.setString("\(payload)-\(index)", forType: .string)
                    item.setString("<p>\(payload)-\(index)</p>", forType: .html)
                    return item
                })

            case "big":
                clear()
                let item = NSPasteboardItem()
                item.setString(payload, forType: .string)
                item.setData(Data(repeating: 0x5a, count: Int(parts.dropFirst().first ?? "") ?? 0), forType: blobType)
                pasteboard.writeObjects([item])

            case "lazy":
                // lazy:<delayMs>:<bytes>. The string is there at once; the blob is a promise kept on demand.
                clear()
                let provider = LazyProvider(
                    delay: (TimeInterval(parts.dropFirst().first ?? "") ?? 0) / 1_000,
                    bytes: Int(parts.dropFirst(2).first ?? "") ?? 0
                )
                providers.append(provider)
                let item = NSPasteboardItem()
                item.setString(payload, forType: .string)
                item.setDataProvider(provider, forTypes: [blobType])
                pasteboard.writeObjects([item])

            case "fileURL":
                clear()
                pasteboard.writeObjects([URL(filePath: "/System/Library/CoreServices/SystemVersion.plist") as NSURL])

            case "promise":
                clear()
                pasteboard.writeObjects([NSFilePromiseProvider(fileType: "public.plain-text", delegate: promiseDelegate)])

            case "transient":
                // What a password manager writes.
                clear()
                let item = NSPasteboardItem()
                item.setString(payload, forType: .string)
                item.setData(Data(), forType: transientType)
                item.setData(Data(), forType: concealedType)
                pasteboard.writeObjects([item])

            default:
                emit("unknown \(kind)")
                return
            }
            emit("wrote \(kind) \(payload) \(start) \(cleared) \(uptimeNanos()) \(pasteboard.changeCount)")
        }
    }

    final class LazyProvider: NSObject, NSPasteboardItemDataProvider {
        private let delay: TimeInterval
        private let bytes: Int

        init(delay: TimeInterval, bytes: Int) {
            self.delay = delay
            self.bytes = bytes
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            emit("providing \(uptimeNanos())")
            Thread.sleep(forTimeInterval: delay)
            item.setData(Data(repeating: 0x61, count: bytes), forType: type)
            emit("provided \(uptimeNanos())")
        }
    }

    final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            "promised.txt"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL) async throws {
            try Data("promised".utf8).write(to: url)
        }
    }
}

/// The spike's end of a fixture process.
final class FixtureProcess: @unchecked Sendable {
    let pasteboardName: String
    private(set) var pid: pid_t = 0
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var lines: [String] = []
    private var partial = ""

    /// Nil when the fixture does not come up.
    init?(pasteboardName: String) {
        self.pasteboardName = pasteboardName
        guard let executable = Bundle.main.executableURL else { return nil }
        process.executableURL = executable
        process.arguments = ["--pasteboard-fixture", pasteboardName]
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            condition.lock()
            partial += text
            var pieces = partial.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            partial = pieces.removeLast()
            lines += pieces
            condition.broadcast()
            condition.unlock()
        }
        do { try process.run() } catch { return nil }
        guard let ready = wait(for: "ready", timeout: .seconds(10)), let pid = pid_t(ready[1]) else {
            process.terminate()
            return nil
        }
        self.pid = pid
    }

    func send(_ command: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    /// The words of the first unread event that starts with `event`. Events before it stay unread.
    func wait(for event: String, timeout: Duration) -> [String]? {
        let deadline = Date(timeIntervalSinceNow: timeout.milliseconds / 1_000)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = lines.firstIndex(where: { $0.hasPrefix(event + " ") }) {
                return lines.remove(at: index).split(separator: " ").map(String.init)
            }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    func discardEvents() {
        condition.lock()
        lines.removeAll()
        condition.unlock()
    }

    func kill() {
        Darwin.kill(pid, SIGKILL)
        process.waitUntilExit()
    }

    func quit() {
        output.fileHandleForReading.readabilityHandler = nil
        send("quit")
        process.waitUntilExit()
    }
}

/// One `wrote` event, with times as the fixture's clock gave them.
struct FixtureWrite {
    var kind: String
    var payload: String
    var start: UInt64
    var cleared: UInt64
    var end: UInt64
    var changeCount: Int

    init?(_ words: [String]?) {
        guard let words, words.count == 7, let start = UInt64(words[3]), let cleared = UInt64(words[4]),
              let end = UInt64(words[5]), let changeCount = Int(words[6]) else { return nil }
        kind = words[1]
        payload = words[2]
        self.start = start
        self.cleared = cleared
        self.end = end
        self.changeCount = changeCount
    }
}
