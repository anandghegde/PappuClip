import Foundation

/// Something the parser has to say about a manifest (architecture §9.1, "Report").
///
/// Errors refuse the load; warnings do not. Both name the key the way its author spelled it, with the
/// path to it, because "`actions[2].Regular Expression` does not compile" is a message somebody can act
/// on and "regex invalid" is not. Nothing here carries selection text: a diagnostic is about a file
/// the user installed, and is safe to show, log and export (DIA-4).
public struct ManifestDiagnostic: Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Equatable, Hashable, Codable {
        case warning, error
    }

    public var severity: Severity
    /// Where in the config, as written: `actions[1].Shell Script File`. Empty for the file as a whole.
    public var path: String
    public var message: String

    public init(_ severity: Severity, at path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }

    public var description: String {
        path.isEmpty ? message : "\(path): \(message)"
    }
}

/// A load that did not produce a manifest, with everything that was found on the way.
///
/// The warnings ride along with the errors because a developer fixing the error wants to see them in
/// the same pass rather than one reload later.
public struct ManifestLoadFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var errors: [ManifestDiagnostic]
    public var warnings: [ManifestDiagnostic]

    public init(errors: [ManifestDiagnostic], warnings: [ManifestDiagnostic] = []) {
        self.errors = errors
        self.warnings = warnings
    }

    public init(_ message: String, at path: String = "") {
        self.init(errors: [ManifestDiagnostic(.error, at: path, message)])
    }

    public var description: String {
        errors.map(\.description).joined(separator: "\n")
    }
}
