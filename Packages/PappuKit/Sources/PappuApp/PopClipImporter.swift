import Foundation
import PappuCore
import PappuExtensions
import Synchronization

/// Import from PopClip (EXM-11): offered once on first run and from the menu afterwards, whenever
/// PopClip's `Extensions` folder exists.
///
/// The order is the safety argument. The user is asked first, with what was found; then every package
/// is staged and analysed and shown on one batch review (EXM-15), where a gated extension stays
/// installed but off unless its own switch is turned on; only a confirmed review brings the
/// exclusions across, each as an appearance exclusion (`hotkeyOnly`) for an app that has no rule of
/// its own yet. A cancelled review imports nothing at all. PopClip's files are read, never changed.
@MainActor
public final class PopClipImporter {
    /// What the offer says was found.
    public struct Offer: Sendable, Equatable {
        public var extensions: Int
        public var excludedApps: Int
    }

    /// What an import did, for the closing alert.
    public struct Report: Sendable, Equatable {
        /// Installed and approved.
        public var approved: [String] = []
        /// Installed, waiting for approval in Extension Info (EXM-15d).
        public var waiting: [String] = []
        /// Already installed with the same bytes.
        public var alreadyInstalled = 0
        /// Folder name, and why.
        public var failed: [Failure] = []
        /// Apps newly excluded.
        public var excludedApps: [String] = []
        public var cancelled = false

        public struct Failure: Sendable, Equatable {
            public var name: String
            public var reason: String
        }
    }

    public static let offeredKey = "import.popClip.offered"

    private let find: @Sendable () -> PopClipImport?
    private let offered: SettingsValue<Bool>
    private let ask: @MainActor (Offer) async -> Bool
    private let install: @MainActor ([ExtensionLibrary.Source], @escaping ExtensionLibrary.BatchReviewer) async throws -> [ExtensionLibrary.BatchEntry]
    private let review: ExtensionLibrary.BatchReviewer
    private let rules: PrivacyRulesStore
    private var running = false

    public init(
        find: @escaping @Sendable () -> PopClipImport? = { PopClipImport.find() },
        storage: any SettingsStorage,
        rules: PrivacyRulesStore,
        ask: @escaping @MainActor (Offer) async -> Bool,
        install: @escaping @MainActor ([ExtensionLibrary.Source], @escaping ExtensionLibrary.BatchReviewer) async throws -> [ExtensionLibrary.BatchEntry],
        review: @escaping ExtensionLibrary.BatchReviewer
    ) {
        self.find = find
        self.offered = SettingsValue(key: Self.offeredKey, default: false, storage: storage)
        self.ask = ask
        self.install = install
        self.review = review
        self.rules = rules
    }

    /// Whether the menu offers it: PopClip's `Extensions` folder is there.
    public var isAvailable: Bool { find() != nil }

    /// EXM-11's first-run offer: once per install, and only when there is something to import.
    /// Nil when nothing was offered.
    public func offerAtFirstRun() async -> Report? {
        guard !offered.value, let found = find(), !found.isEmpty else { return nil }
        offered.set(true)
        return await run(found)
    }

    /// The menu's Import from PopClip. Nil when PopClip's folder is not there or an import is running.
    public func importNow() async -> Report? {
        guard let found = find() else { return nil }
        offered.set(true)
        return await run(found)
    }

    private func run(_ found: PopClipImport) async -> Report? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        guard await ask(Offer(extensions: found.packages.count, excludedApps: found.excludedApps.count)) else { return nil }

        var report = Report()
        if !found.packages.isEmpty {
            // The review's own answer says whether the user confirmed; a list of outcomes cannot tell a
            // cancelled sheet from one where everything was already installed.
            let confirmed = Mutex<Bool?>(nil)
            let review = self.review
            let entries: [ExtensionLibrary.BatchEntry]
            do {
                entries = try await install(found.packages.map(ExtensionLibrary.Source.popClipPackage)) { proposals in
                    let answers = await review(proposals)
                    confirmed.withLock { $0 = answers != nil }
                    return answers
                }
            } catch {
                report.failed.append(.init(name: found.packages.first?.lastPathComponent ?? "", reason: String(describing: error)))
                return report
            }
            if confirmed.withLock({ $0 }) == false {
                report.cancelled = true
                return report
            }
            for entry in entries {
                let name = Self.name(of: entry.source)
                switch entry.result {
                case .success(.installed), .success(.updated):
                    if entry.approved == true { report.approved.append(name) } else { report.waiting.append(name) }
                case .success(.alreadyInstalled):
                    report.alreadyInstalled += 1
                case .success(.cancelled):
                    break
                case .failure(let error):
                    report.failed.append(.init(name: name, reason: String(describing: error)))
                }
            }
        }
        report.excludedApps = importExclusions(found.excludedApps)
        return report
    }

    /// Each PopClip exclusion becomes an appearance exclusion — the bar stays away, the shortcut still
    /// works, as PopClip's list does — for an app the user has no rule for yet. A rule already there,
    /// and a hard block, are the user's and are left alone.
    private func importExclusions(_ bundleIDs: [String]) -> [String] {
        let current = rules.rules
        var added: [String] = []
        for bundleID in bundleIDs where current.appModes[bundleID] == nil && !current.hardBlockedApps.contains(bundleID) {
            rules.setMode(.hotkeyOnly, forApp: bundleID)
            added.append(bundleID)
        }
        return added
    }

    static func name(of source: ExtensionLibrary.Source) -> String {
        switch source {
        case .packageFolder(let url), .zippedPackage(let url), .snippetFile(let url), .popClipPackage(let url):
            url.deletingPathExtension().lastPathComponent
        case .selectedText:
            ""
        }
    }
}
