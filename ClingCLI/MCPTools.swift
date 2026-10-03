//
//  MCPTools.swift
//  ClingCLI
//
//  What `cling mcp serve` can actually do: how a tool reaches Cling, the elicitation questions, and the
//  switch. Split from MCPServer.swift, which is the protocol and the loop.
//

import ArgumentParser
import CryptoKit
import Foundation

// MARK: - Running a command

extension MCPServer {
    /// A reindex that waits gives up after this, and says it is still going.
    static let reindexTimeout: TimeInterval = 600

    /// One Cling command, run in this process.
    ///
    /// The commands live here, so they are parsed and run in place, and what they print is captured. They
    /// still reach the app the only way the CLI ever does, over its Mach port, and every request they
    /// build carries `CLI_ORIGIN`, which `serve()` pins to "mcp" for the life of the process.
    static func runCommand(_ args: [String], timeout: TimeInterval) -> (out: String, err: String, code: Int32, message: String) {
        var thrown: Error?
        CLI_DEADLINE = Date().addingTimeInterval(timeout)
        let captured = capture {
            do {
                var command = try ClingCLI.parseAsRoot(args)
                try command.run()
            } catch {
                thrown = error
            }
        }
        CLI_DEADLINE = nil

        // The command's own stderr keeps flowing to the client's log, where it was going before.
        if !captured.err.isEmpty {
            FileHandle.standardError.write(Data(captured.err.utf8))
        }
        guard let thrown else {
            return (captured.out, captured.err, 0, "")
        }
        return (captured.out, captured.err, ClingCLI.exitCode(for: thrown).rawValue, ClingCLI.message(for: thrown))
    }

    /// The arguments with the free text last. `tail` is what an agent typed (a query, a path, a rule line),
    /// and a rule like `-Users-` or a query starting with a dash must never be read as an option, so it goes
    /// after `--`. Commands whose arguments are parsed with `.remaining` take it raw instead.
    static func argv(_ args: [String], _ tail: [String], terminator: Bool) -> [String] {
        guard !tail.isEmpty else { return args }
        return args + (terminator ? ["--"] : []) + tail
    }

    /// Run a command with `--json` and parse what it prints.
    static func run(_ args: [String], tail: [String] = [], terminator: Bool = true, timeout: TimeInterval = 30) throws -> ToolOutput {
        let result = runCommand(argv(args + ["--json"], tail, terminator: terminator), timeout: timeout)
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        let complaint = result.message.isEmpty ? stderr.replacingOccurrences(of: "error: ", with: "") : result.message

        guard result.code == 0 else {
            throw ClingMCPError(annotate(complaint.isEmpty ? (out.isEmpty ? "Cling exited \(result.code)" : out) : complaint))
        }
        guard !out.isEmpty else {
            throw ClingMCPError(annotate(complaint.isEmpty ? "Cling exited \(result.code) with no output" : complaint))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else {
            // An older Cling answers some commands in words only, and they still read.
            return .text(out)
        }
        return .json(prune(parsed))
    }

    /// Run a command whose output is prose, not JSON.
    static func text(_ args: [String], tail: [String] = [], terminator: Bool = true, timeout: TimeInterval = 30) throws -> ToolOutput {
        let result = runCommand(argv(args, tail, terminator: terminator), timeout: timeout)
        let out = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.code == 0 else {
            let complaint = result.message.isEmpty ? (stderr.isEmpty ? out : stderr.replacingOccurrences(of: "error: ", with: "")) : result.message
            throw ClingMCPError(annotate(complaint.isEmpty ? "Cling exited \(result.code)" : complaint))
        }
        return .text(out.isEmpty ? (stderr.isEmpty ? "Done." : stderr) : out)
    }

    /// Cling's own refusals are the words the agent should read, so they come back verbatim. Only the next
    /// step is added.
    static func annotate(_ message: String) -> String {
        let low = message.lowercased()
        if low.contains("cling pro") {
            return message + " The user can buy a licence at \(buyURL)."
        }
        if low.contains("not accepting scripts") {
            return message + " Scripts are behind their own switch, separate from agent changes. Prefer a "
                + "filter or a setting when one can do the job."
        }
        if low.contains("not accepting changes") {
            return message + " Or call cling_start_server, which puts that question on screen for them."
        }
        if low.contains("cannot connect") || low.contains("is it running") {
            return message + " Ask the user to open Cling, or call cling_start_server, which opens it."
        }
        return message
    }

    /// Drops the nulls the Swift encoder leaves behind, so a tool result reads.
    static func prune(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.compactMapValues { $0 is NSNull ? nil : prune($0) }
        }
        if let array = value as? [Any] {
            return array.map { prune($0) }
        }
        return value
    }

    /// Everything the command prints, with fd 1 and fd 2 pointed at pipes for the duration.
    ///
    /// The commands print with `print` and `fputs`, so this is where their output is taken from. Both pipes
    /// are drained on their own threads: a command that writes more than a pipe buffer would otherwise block
    /// on its own output and never return.
    static func capture(_ body: () -> Void) -> (out: String, err: String) {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { body(); return ("", "") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            body()
            return ("", "")
        }

        fflush(stdout)
        fflush(stderr)
        let savedOut = dup(1)
        let savedErr = dup(2)
        dup2(outPipe[1], 1)
        dup2(errPipe[1], 2)
        close(outPipe[1])
        close(errPipe[1])

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            group.enter()
            DispatchQueue.global().async {
                var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = read(fd, &chunk, chunk.count)
                    if count <= 0 {
                        break
                    }
                    if isOut {
                        outData.append(contentsOf: chunk[0 ..< count])
                    } else {
                        errData.append(contentsOf: chunk[0 ..< count])
                    }
                }
                close(fd)
                group.leave()
            }
        }

        body()

        // Restoring fd 1 and 2 closes the last write ends, which is what the drain threads read as the end
        // of the output.
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, 1)
        dup2(savedErr, 2)
        close(savedOut)
        close(savedErr)
        group.wait()

        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - Argument helpers

extension MCPServer {
    /// A JSON value as one command-line argument.
    static func argument(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(number) {
                return "\(number.doubleValue)"
            }
            return "\(number.intValue)"
        }
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }

    /// `--flag=value`, attached, so a value starting with a dash (`-1`, `-old`) is never read as an option.
    /// An empty string is passed on: for the text fields of a filter it means "clear this".
    static func opt(_ args: [String: Any], _ flag: String, _ key: String) -> [String] {
        guard let value = args[key], !(value is NSNull) else { return [] }
        let string = argument(value)
        return string.isEmpty && !(value is String) ? [] : ["\(flag)=\(string)"]
    }

    static func flag(_ args: [String: Any], _ key: String, _ flag: String) -> [String] {
        (args[key] as? Bool == true) ? [flag] : []
    }

    /// A list argument, which a client may also send as a single string.
    static func list(_ args: [String: Any], _ key: String) -> [String] {
        if let items = args[key] as? [Any] {
            return items.map { argument($0) }.filter { !$0.isEmpty }
        }
        if let single = args[key], !(single is NSNull) {
            let text = argument(single)
            return text.isEmpty ? [] : [text]
        }
        return []
    }

    /// Paths as the user wrote them, with `~` expanded.
    static func paths(_ args: [String: Any], key: String = "paths") throws -> [String] {
        let paths = list(args, key).map { ($0 as NSString).expandingTildeInPath }
        guard !paths.isEmpty else {
            throw ClingMCPError("no paths given")
        }
        return paths
    }
}

// MARK: - The switch

extension MCPServer {
    /// The discovery card the app writes on every launch. A hint, never a requirement.
    static func card() -> [String: Any] {
        let path = ("~/.well-known/mcp/cling.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Hands `cling://mcp/<action>` to the app, launching it if it is not running.
    ///
    /// Aimed at the app the card names: with a debug build next to /Applications, plain `open` picks
    /// whichever LaunchServices prefers, which may not be the one this server belongs to.
    static func openControlURL(_ action: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = (card()["app"] as? [String: Any])?["path"] as? String, FileManager.default.fileExists(atPath: app) {
            process.arguments = ["-a", app, "cling://mcp/\(action)"]
        } else {
            process.arguments = ["cling://mcp/\(action)"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ClingMCPError("could not run /usr/bin/open: \(error)")
        }
        process.waitUntilExit()
    }

    /// Asks Cling to allow changes through MCP, launching it if it is not running.
    ///
    /// Opening the URL is what makes this work while nothing is listening: macOS hands `cling://` to the app
    /// and launches it first if needed. Cling then shows an alert and waits for a person, so the wait here is
    /// a person's wait.
    static func startServer(wait: TimeInterval = 90) throws -> ToolOutput {
        try openControlURL("start")
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if case let .json(payload)? = try? run(["mcp", "status"], timeout: 5),
               let mcp = (payload as? [String: Any])?["mcp"] as? [String: Any],
               mcp["enabled"] as? Bool == true
            {
                return try status()
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw ClingMCPError("Cling asked and the answer did not come (or it was no). Nothing changed. "
            + "Ask the user to allow it in Cling Settings, MCP.")
    }

    static func stopServer() throws -> ToolOutput {
        // Taking permission away needs no alert, so this never waits and never checks.
        try openControlURL("stop")
        return .json([
            "ok": true, "stopped": true,
            "note": "Cling will refuse changes from agents until it is started again. Reading still works.",
        ])
    }

    static func status() throws -> ToolOutput {
        guard case let .json(payload) = try run(["mcp", "status"]), var object = payload as? [String: Any] else {
            return try run(["mcp", "status"])
        }
        let card = card()
        for key in ["version", "displayName", "description"] where object[key] == nil {
            if let value = card[key] {
                object[key] = value
            }
        }
        return .json(object)
    }

    /// Raises if a change is going to be refused anyway.
    ///
    /// Elicitation costs the USER something: a dialog, or a question in the chat. Asking which way they
    /// want a path brought back and then answering "not accepting changes" spends their attention on a
    /// decision that was never going to be acted on.
    static func refuseBeforeAsking() throws {
        guard case let .json(payload)? = try? run(["mcp", "status"], timeout: 10),
              let mcp = (payload as? [String: Any])?["mcp"] as? [String: Any]
        else {
            return // If status cannot be read, let the real call produce the real error.
        }
        guard mcp["enabled"] as? Bool == true else {
            throw ClingMCPError(annotate(
                "Cling is not accepting changes from agents. Ask the user to allow it in Cling Settings, MCP."
            ))
        }
    }
}

// MARK: - NeedInput

/// MRTR: the tool call returns, and the client calls again with the answers.
struct NeedInput: Error {
    let key: String
    let message: String
    let schema: [String: Any]
}

extension MCPServer {
    enum ElicitOutcome {
        case answered([String: Any])
        /// The user said no, the dialog was dismissed, nobody answered, or the client cannot ask. All four end
        /// the same way: say what happened, then repeat the options so the agent can ask in its own chat. A
        /// non-interactive session declares the capability and then cancels every request, so this is the
        /// common path and not the rare one.
        case declined
        case unanswered
        case unsupported
    }

    static func elicitationModes(_ capabilities: [String: Any]?) -> Set<String> {
        guard let elicitation = capabilities?["elicitation"] as? [String: Any] else { return [] }
        if elicitation.isEmpty {
            return ["form"]
        }
        return Set(["form", "url"].filter { elicitation[$0] != nil })
    }

    static var usesMRTR: Bool {
        state.protocolVersion >= mrtrFrom
    }

    /// Answers for `key`, however this client can give them. Throws `NeedInput` on the MRTR path, so a tool
    /// body is written once and neither path leaks into it.
    static func ask(_ key: String, _ message: String, _ schema: [String: Any]) throws -> ElicitOutcome {
        if usesMRTR {
            if let responses = current.params["inputResponses"] as? [String: Any],
               let answer = responses[key] as? [String: Any]
            {
                guard openState(current.params["requestState"], tool: current.name, args: current.args) else {
                    throw ClingMCPError("requestState did not check out, so the answers were dropped. Call the tool again.")
                }
                switch answer["action"] as? String {
                case "accept": return .answered(answer["content"] as? [String: Any] ?? [:])
                case "decline": return .declined
                default: return .unanswered
                }
            }
            // 2026-07-28 moved capabilities into each request's `_meta`.
            let meta = current.params["_meta"] as? [String: Any] ?? [:]
            let caps = meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any]
            guard elicitationModes(caps).contains("form") else { return .unsupported }
            throw NeedInput(key: key, message: message, schema: schema)
        }
        return elicit(message, schema)
    }

    /// Asks the user one question mid-call, servicing the client while we wait.
    ///
    /// The loop answers anything else the client sends while the dialog is up: another tools/call, a ping,
    /// a cancellation. Blocking on a read of one id instead would deadlock a client that pipelines requests.
    static func elicit(_ message: String, _ schema: [String: Any], timeout: TimeInterval? = nil) -> ElicitOutcome {
        guard state.modes.contains("form") else { return .unsupported }
        // One level of nesting is fine. Deeper loses track of which dialog belongs to which call, and can
        // leave one on screen after its tool has returned.
        guard depth <= 1 else { return .unsupported }

        elicitCounter += 1
        // A string id with our own prefix can never collide with the client's integer ids, which is what
        // makes dispatch by id safe.
        let rid = "cling-elicit-\(elicitCounter)"
        pending[rid] = .some(nil)
        owner[rid] = String(describing: current.requestID ?? "")
        send([
            "jsonrpc": "2.0", "id": rid, "method": "elicitation/create",
            "params": ["mode": "form", "message": message, "requestedSchema": schema],
        ])

        let limit = timeout ?? elicitTimeout
        let deadline = Date().timeIntervalSince1970 + limit
        defer {
            pending.removeValue(forKey: rid)
            owner.removeValue(forKey: rid)
        }

        while true {
            if let answer = pending[rid], let answer {
                return interpret(answer)
            }
            let line: Data
            do {
                line = try reader.nextLine(deadline: deadline)
            } catch is LineReader.TimedOut {
                // Never block forever: the client's own tool timeout would fire first and leave a dialog on
                // screen with no result behind it.
                send([
                    "jsonrpc": "2.0", "method": "notifications/cancelled",
                    "params": ["requestId": rid, "reason": "no answer within \(Int(limit))s"],
                ])
                return .unanswered
            } catch {
                exit(0) // the client is gone, nothing to reply to
            }
            guard !line.isEmpty, let message = parse(line) else { continue }
            dispatch(message)
        }
    }

    static func interpret(_ message: [String: Any]) -> ElicitOutcome {
        if message["error"] != nil {
            // -32602 means we sent a mode the client did not declare, -32601 means it declared the
            // capability and does not route the method. Either way, fall back to text.
            log("elicitation error: \(message["error"] ?? "")")
            return .unsupported
        }
        let result = message["result"] as? [String: Any] ?? [:]
        switch result["action"] as? String {
        case "accept": return .answered(result["content"] as? [String: Any] ?? [:])
        case "decline": return .declined
        // Anything that is not exactly accept or decline is read as a dismissal, which is the safe reading
        // of a shape we did not expect.
        default: return .unanswered
        }
    }

    /// The client gave up on the outer tools/call, so let the handler unwind.
    static func onCancelled(_ params: [String: Any]) {
        let requested = String(describing: params["requestId"] ?? "")
        for (rid, ownerID) in owner where ownerID == requested {
            if let slot = pending[rid], slot == nil {
                pending[rid] = .some(["id": rid, "result": ["action": "cancel"]])
            }
        }
    }

    /// Clients are allowed to hand back a string where the schema said a number.
    static func asInt(_ content: [String: Any], _ key: String, _ fallback: Int?) -> Int? {
        guard let value = content[key] else { return fallback }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return Int(argument(value).trimmingCharacters(in: .whitespaces)) ?? fallback
    }

    // MARK: MRTR state, for the day a stdio client negotiates 2026-07-28

    /// The server keeps nothing between the two calls: everything needed to resume goes into
    /// `requestState`, which the spec says to treat as attacker-controlled. So it is signed with a
    /// per-process key, carries a TTL and names the tool and the arguments it was issued for. A restarted
    /// server rejecting old state is correct rather than a bug.
    static func sealState(tool: String, args: [String: Any]) -> String {
        let payload: [String: Any] = [
            "tool": tool,
            "args": argsDigest(args),
            "at": Date().timeIntervalSince1970,
        ]
        guard let raw = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "" }
        let tag = HMAC<SHA256>.authenticationCode(for: raw, using: stateKey)
        return (raw + Data(tag)).base64EncodedString()
    }

    static func openState(_ blob: Any?, tool: String, args: [String: Any]) -> Bool {
        guard let string = blob as? String, let data = Data(base64Encoded: string), data.count > 32 else { return false }
        let raw = data.prefix(data.count - 32)
        let tag = data.suffix(32)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: raw, using: stateKey),
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              payload["tool"] as? String == tool,
              payload["args"] as? String == argsDigest(args),
              let at = payload["at"] as? TimeInterval, Date().timeIntervalSince1970 - at < 300
        else { return false }
        return true
    }

    static func argsDigest(_ args: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
