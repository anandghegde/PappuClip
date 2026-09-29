import Foundation
import PappuExtensions
import PappuJSBridge
import PappuSettings

/// DEV-1: which worlds the helper builds as development worlds. Only an approved development folder's
/// extension is ever named, and only with the switches the developer turned on. There is no setting
/// that makes every extension inspectable or verbose.
public enum DevelopmentMode {
    public static func debugging(
        for folders: [LocalIdentity],
        verboseLogging: Bool,
        webInspector: Bool
    ) -> [String: JSDebug] {
        let debug = JSDebug(inspectable: webInspector, verbose: verboseLogging)
        guard !debug.isEmpty else { return [:] }
        return Dictionary(folders.map { ($0.description, debug) }, uniquingKeysWith: { first, _ in first })
    }

    public static func debugging(for folders: [LocalIdentity], preferences: DeveloperPreferences) -> [String: JSDebug] {
        debugging(for: folders, verboseLogging: preferences.verboseLogging, webInspector: preferences.webInspector)
    }
}
