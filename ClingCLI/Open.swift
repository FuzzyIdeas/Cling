import ArgumentParser
import Foundation

// MARK: - Open

struct Open: ParsableCommand {
    enum How: String, EnumerableFlag {
        case reveal, terminal, editor, shelve

        static func help(for value: How) -> ArgumentHelp? {
            switch value {
            case .reveal: "Show them in Finder"
            case .terminal: "Open them in the terminal set in Cling, a file's folder for a file"
            case .editor: "Open them in the editor set in Cling"
            case .shelve: "Put them on the shelf set in Cling, or in Cling's stash"
            }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Open files the way Cling's toolbar does",
        discussion: """
        With no flag, each path opens in its default app. The terminal, editor and shelf are the ones set in \
        Cling Settings, Apps. The paths count as opened from Cling, so they rank higher in search and show in \
        recent files.
        """
    )

    @Flag(exclusivity: .exclusive)
    var how: How?

    @Argument(help: "Paths to open")
    var paths: [String]

    mutating func run() throws {
        let resolved = paths.map { ($0 as NSString).expandingTildeInPath }
        let request = ClingRequest(command: .open, paths: resolved, action: how?.rawValue ?? "open")
        guard let data = try sendMachPort(data: request.encoded()) else {
            fputs("error: no response from Cling app\n", stderr)
            throw ExitCode.failure
        }
        guard let response = try? JSONDecoder().decode(ClingResponse.self, from: data) else {
            fputs("error: invalid response\n", stderr)
            throw ExitCode.failure
        }
        if let error = response.error {
            fputs("error: \(error)\n", stderr)
            throw ExitCode.failure
        }
    }
}
