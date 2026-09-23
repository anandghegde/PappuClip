import Foundation
import PappuCore

/// Everything the menu bar item can be asked to do (PRD §7.5).
///
/// One closed list, so that the menu, the keyboard shortcut and anything a script route adds later all
/// name the same commands and the switch that carries them out has no default case.
public enum MenuCommand: String, Sendable, Equatable, Codable, CaseIterable {
    case appearAutomatically
    case pauseForOneHour
    case pauseUntilResumed
    case resume
    /// ONB-1: the grant is missing or stale, and this is the way back to the screen that explains it.
    case onboarding
    case settings
    case quit
}

/// The menu the status item drops down, as a value (PRD §7.5, ACT-18).
///
/// Built fresh each time the menu opens, from the settings as they stand and the grant as last
/// observed, which is what keeps a stale tick out of it: `NSMenu` is told what to draw, it is never
/// asked to remember. Everything about what the menu *says* is decided here, where a test can read it,
/// and `MenuBarItem` does nothing but turn these entries into `NSMenuItem`s and send the commands back.
public struct MenuBarMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var command: MenuCommand
        public var title: String
        /// Always with ⌘ held; nothing in this menu uses another modifier.
        public var keyEquivalent: String?
        /// Drawn with a tick (PRD §7.5's "Appear automatically").
        public var isOn: Bool

        public init(command: MenuCommand, title: String, keyEquivalent: String? = nil, isOn: Bool = false) {
            self.command = command
            self.title = title
            self.keyEquivalent = keyEquivalent
            self.isOn = isOn
        }
    }

    public enum Entry: Sendable, Equatable {
        /// A line that says something and does nothing: ACT-18's pause status.
        case status(String)
        case item(Item)
        case separator
    }

    public var entries: [Entry]
    /// Whether the icon itself is drawn as paused. ACT-18 asks for the pause to be visible, and a user
    /// who has paused for an hour should not have to open a menu to find out whether they did.
    public var isPaused: Bool

    public init(
        rules: PrivacyRules,
        grant: AccessibilityGrant = .working,
        now: Date = Date(),
        locale: Locale = .current
    ) {
        let pause = rules.pause.settled(at: now)
        isPaused = pause != .running

        var entries: [Entry] = []

        // First, because it is the reason nothing else in the menu is working. A grant that is merely
        // untested says nothing: it is the ordinary state of a launch where no bar has been asked for
        // yet, and a warning there would be a warning in every quiet moment.
        switch grant {
        case .notTrusted:
            entries.append(.item(Item(command: .onboarding, title: AppStrings.accessibilityMissing)))
            entries.append(.separator)
        case .stale:
            entries.append(.item(Item(command: .onboarding, title: AppStrings.accessibilityStale)))
            entries.append(.separator)
        case .working, .untested:
            break
        }

        if let status = Self.status(for: pause, locale: locale) {
            entries.append(.status(status))
            entries.append(.separator)
        }

        entries.append(.item(Item(
            command: .appearAutomatically,
            title: AppStrings.appearAutomatically,
            isOn: rules.appearAutomatically
        )))

        // While paused there is one command, and it is the way out. Leaving "Pause for One Hour" beside
        // "Resume" would offer to restart a pause that is already running and read as though it were
        // something else.
        if isPaused {
            entries.append(.item(Item(command: .resume, title: AppStrings.resume)))
        } else {
            entries.append(.item(Item(command: .pauseForOneHour, title: AppStrings.pauseForOneHour)))
            entries.append(.item(Item(command: .pauseUntilResumed, title: AppStrings.pauseUntilResumed)))
        }

        entries.append(.separator)
        entries.append(.item(Item(command: .settings, title: AppStrings.settings, keyEquivalent: ",")))
        entries.append(.separator)
        entries.append(.item(Item(command: .quit, title: AppStrings.quit, keyEquivalent: "q")))

        self.entries = entries
    }

    /// The commands the menu offers, in order. What a test asserts over, and what says that a command
    /// the user cannot reach is not in the menu at all rather than in it and disabled.
    public var commands: [MenuCommand] {
        entries.compactMap {
            if case .item(let item) = $0 { return item.command }
            return nil
        }
    }

    public func item(_ command: MenuCommand) -> Item? {
        for entry in entries {
            if case .item(let item) = entry, item.command == command { return item }
        }
        return nil
    }

    /// What ACT-18's status line says, or nil when nothing is paused and there is no line at all.
    public var statusLine: String? {
        for entry in entries {
            if case .status(let text) = entry { return text }
        }
        return nil
    }

    /// The status line, or nil when there is nothing to say because nothing is paused.
    static func status(for pause: PauseState, locale: Locale) -> String? {
        switch pause {
        case .running:
            return nil
        case .untilResumed:
            return AppStrings.pausedUntilResumed
        case .until(let expiry):
            // A time of day and not a countdown, because that is what the stored value is: a pause
            // survives a quit, and "43 minutes left" would be wrong the moment the menu stayed open.
            let time = expiry.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            return AppStrings.pausedUntil(time)
        }
    }
}
