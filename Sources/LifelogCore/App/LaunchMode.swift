import Foundation

/// One executable, two faces: the menu bar app when opened from Finder, at login or with `app`, else the CLI.
public enum LaunchMode: Equatable {
    case menuBar
    case cli([String])

    /// A bare binary (`swift run`) or a terminal with no arguments gets the CLI help, as before. Launch Services
    /// starts the packaged app without a terminal and, on older macOS, with a `-psn_…` argument.
    public static func decide(_ arguments: [String], isTerminal: Bool, isAppBundle: Bool) -> LaunchMode {
        let arguments = arguments.filter { !$0.hasPrefix("-psn_") }
        if arguments == ["app"] { return .menuBar }
        if arguments.isEmpty, isAppBundle, !isTerminal { return .menuBar }
        return .cli(arguments)
    }

    /// This process, as launched.
    public static var current: LaunchMode {
        decide(Array(CommandLine.arguments.dropFirst()), isTerminal: isatty(STDIN_FILENO) == 1,
               isAppBundle: Bundle.main.bundleURL.pathExtension == "app")
    }
}
