import Foundation

/// §8.4 Shell Script: which program is started, with which arguments, to run an action's script.
///
/// **Two questions, answered in turn.**
///
/// 1. *What runs the script.* An `interpreter` runs it when there is one, and it may carry its own
///    arguments (`/usr/bin/env python3`, `sh -e`). A file with no interpreter was accepted at load
///    because it is an executable with a `#!` line, and it is run as itself. An inline script with no
///    interpreter is run as itself if it begins with `#!` and by `/bin/sh` otherwise
///    *(unverified: PopClip's documentation does not say what it does here, and `/bin/sh` is what it
///    does for a `.sh` file with no interpreter)*.
/// 2. *How it is started (`shellMode`).* `login`, the default, starts it through the user's shell as
///    a login shell, so that `python3` is found where the user's own Terminal finds it — the corpus
///    names interpreters by bare name (`python3`, `ruby`, `zsh`), and the app's own `PATH` is the
///    system's four directories. `nonlogin` goes through the same shell without its login files.
///    `none` starts the program directly, and a bare name is looked for in `defaultPath`.
///
/// The shell is handed the command as its positional parameters and told `exec "$@"`, so nothing of
/// the command — a path with a space, an interpreter with a quote in it — is ever parsed as shell
/// source. The user's shell is used only if it is one that reads that the same way; `fish` and the
/// like are replaced by `/bin/zsh`, the macOS default.
public struct ShellInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Why a script cannot be started. Each is an extension that loaded and cannot run here.
    public enum Refusal: Error, Sendable, Equatable {
        /// `none` mode and a bare interpreter name that is in none of `defaultPath`'s directories.
        case interpreterNotFound(String)
        /// An interpreter key that is only white space.
        case emptyInterpreter
    }

    /// Shells that read `-l -c 'exec "$@"' name args…` as POSIX sh does.
    public static let posixShells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    public static let fallbackShell = "/bin/zsh"
    /// Where `none` looks for a bare name: the system's directories, then Homebrew's two.
    public static let defaultPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
    /// `$0` inside the shell, which is what an error message from it names.
    static let shellArgumentZero = "pappuclip"

    /// - Parameters:
    ///   - script: The script file's absolute path. An inline script has been written to a file by
    ///     the time this is asked, so that every interpreter is given a path and none a `-c` string.
    ///   - inlineSource: The inline script's text, which decides whether it is its own interpreter.
    ///     Nil for a script that came from a file.
    ///   - userShell: `$SHELL`, or the account's shell.
    ///   - isExecutable: Whether a path names an executable file. Only asked in `none` mode.
    public static func plan(
        _ action: ShellScriptAction,
        script: String,
        inlineSource: String?,
        userShell: String?,
        isExecutable: (String) -> Bool
    ) throws(Refusal) -> ShellInvocation {
        var command: [String]
        if let interpreter = action.interpreter {
            let words = interpreter.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { throw .emptyInterpreter }
            command = words + [script]
        } else if let inlineSource, !inlineSource.hasPrefix("#!") {
            command = ["/bin/sh", script]
        } else {
            command = [script]
        }

        switch action.mode ?? .login {
        case .none:
            if !command[0].contains("/") {
                guard let found = defaultPath.map({ "\($0)/\(command[0])" }).first(where: isExecutable) else {
                    throw .interpreterNotFound(command[0])
                }
                command[0] = found
            }
            return ShellInvocation(executable: command[0], arguments: Array(command.dropFirst()))
        case .login, .nonlogin:
            let shell = shell(userShell)
            let flags = action.mode == .nonlogin ? ["-c"] : ["-l", "-c"]
            return ShellInvocation(executable: shell, arguments: flags + ["exec \"$@\"", shellArgumentZero] + command)
        }
    }

    /// The user's shell when it is an absolute path to a POSIX one, else the macOS default.
    static func shell(_ userShell: String?) -> String {
        guard let userShell, userShell.hasPrefix("/"),
              let name = userShell.split(separator: "/").last.map(String.init),
              posixShells.contains(name)
        else { return fallbackShell }
        return userShell
    }
}

/// §8.4: how a script's exit reads.
public enum ScriptExit: Sendable, Equatable {
    /// Exit 0. Standard output is the result.
    case succeeded
    /// Exit 2: the extension wants its settings looked at — a missing API key, usually.
    case needsSettings
    /// Any other exit, or a signal.
    case failed

    public init(status: Int32, signalled: Bool) {
        self = switch (signalled, status) {
        case (false, 0): .succeeded
        case (false, 2): .needsSettings
        default: .failed
        }
    }
}
