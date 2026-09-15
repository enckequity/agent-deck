import Foundation
import SQLite3

/// What Deck shows for one task: the human-readable conversation, with tool steps
/// condensed and auto-continue nudges hidden.
struct Conversation: Equatable {
    enum Entry: Equatable {
        case user(String)
        case assistant(String)
        case steps([String])
        case autoContinued
    }

    enum Marker: Equatable { case none, done, blocked(String), waiting(String) }

    var entries: [Entry] = []
    /// opencode's generated session title, when there is one.
    var title: String?
    /// True while the agent is mid-turn (an assistant message has not completed).
    var busy = false
    var marker: Marker = .none
    var pullRequest: URL?

    static let doneMarker = "===AGENTDECK_DONE==="

    /// Builds from the last assistant reply only (Claude sessions, via `agent-deck session output`).
    static func lastReply(_ text: String) -> Conversation {
        var c = Conversation()
        let cleaned = c.absorbMarkers(text)
        if !cleaned.isEmpty { c.entries = [.assistant(cleaned)] }
        return c
    }

    /// Removes the done marker and records the terminal marker of the final reply.
    fileprivate mutating func absorbMarkers(_ text: String) -> String {
        var kept: [String] = []
        marker = .none
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(Self.doneMarker) {
                marker = .done
                continue
            }
            if trimmed.hasPrefix("BLOCKED:") {
                marker = .blocked(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("WAITING:") {
                marker = .waiting(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces))
            }
            kept.append(line)
        }
        let cleaned = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = cleaned.range(of: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#, options: .regularExpression) {
            pullRequest = URL(string: String(cleaned[range]))
        }
        return cleaned
    }
}

/// Reads opencode's own session store (read-only) so the app never scrapes a terminal.
enum OpenCodeHistory {
    static let databasePath = "\(NSHomeDirectory())/.local/share/opencode/opencode.db"

    static func load(directory: String) -> Conversation? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        let sessionSQL = """
            SELECT id, title FROM session WHERE directory IN (?, ?) AND parent_id IS NULL
            ORDER BY time_updated DESC LIMIT 1
            """
        guard let sessionRow = query(db, sessionSQL, [directory, resolved]).first, let sessionID = sessionRow[0] else { return nil }

        // Newest 800 parts, oldest first. Only the small JSON fields are extracted.
        let partsSQL = """
            SELECT * FROM (
              SELECT json_extract(m.data, '$.role'),
                     json_extract(m.data, '$.time.completed'),
                     json_extract(p.data, '$.type'),
                     json_extract(p.data, '$.text'),
                     json_extract(p.data, '$.tool'),
                     json_extract(p.data, '$.state.input.filePath'),
                     json_extract(p.data, '$.state.input.command'),
                     json_extract(p.data, '$.state.input.description'),
                     json_extract(p.data, '$.state.input.pattern'),
                     json_extract(p.data, '$.synthetic'),
                     m.time_created, p.id
              FROM part p JOIN message m ON m.id = p.message_id
              WHERE p.session_id = ?
              ORDER BY m.time_created DESC, p.id DESC LIMIT 800
            ) ORDER BY 11, 12
            """
        let rows = query(db, partsSQL, [sessionID])

        var conversation = Conversation()
        if let title = sessionRow[1], !title.isEmpty, !title.hasPrefix("New session") { conversation.title = title }
        var steps: [String] = []
        var lastAssistantText = ""
        func flushSteps() {
            if !steps.isEmpty { conversation.entries.append(.steps(steps)); steps = [] }
        }
        for row in rows {
            let role = row[0], completed = row[1], type = row[2], text = row[3] ?? ""
            if role == "assistant" { conversation.busy = completed == nil }
            switch (role, type) {
            case ("user", "text"):
                guard row[9] != "1", !text.isEmpty else { continue }
                flushSteps()
                conversation.busy = true
                if text.hasPrefix("Auto-continue (") {
                    conversation.entries.append(.autoContinued)
                } else {
                    conversation.entries.append(.user(stripLauncherContext(text)))
                }
                lastAssistantText = ""
            case ("assistant", "text"):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flushSteps()
                var scratch = Conversation()
                let cleaned = scratch.absorbMarkers(text)
                if !cleaned.isEmpty { conversation.entries.append(.assistant(cleaned)) }
                lastAssistantText = text
            case ("assistant", "tool"):
                if let label = stepLabel(tool: row[4], file: row[5], command: row[6], description: row[7], pattern: row[8]) {
                    steps.append(label)
                }
            default:
                continue
            }
        }
        flushSteps()
        var tail = Conversation()
        _ = tail.absorbMarkers(lastAssistantText)
        conversation.marker = tail.marker
        conversation.pullRequest = rows.reversed().lazy.compactMap { row -> URL? in
            guard let text = row[3],
                  let range = text.range(of: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#, options: .regularExpression)
            else { return nil }
            return URL(string: String(text[range]))
        }.first
        return conversation
    }

    /// deck-task appends worktree instructions to the task; show only what the person typed.
    static func stripLauncherContext(_ text: String) -> String {
        guard let range = text.range(of: "\n\nContext: you are in a fresh git worktree") else { return text }
        return String(text[..<range.lowerBound])
    }

    static func stepLabel(tool: String?, file: String?, command: String?, description: String?, pattern: String?) -> String? {
        let name = file.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool ?? "" {
        case "read": return "Read \(name ?? "a file")"
        case "edit", "write", "patch", "multiedit", "apply_patch": return "Edited \(name ?? "files")"
        case "bash":
            if let description, !description.isEmpty { return description }
            let first = (command ?? "a command").split(separator: "\n").first.map(String.init) ?? "a command"
            return "Ran \(first.count > 48 ? first.prefix(48) + "…" : first)"
        case "grep", "glob", "list", "codesearch": return pattern.map { "Searched for \($0)" } ?? "Searched the code"
        case "webfetch", "websearch": return "Looked something up"
        case "task": return description ?? "Delegated a subtask"
        case "todowrite", "todoread", "question", "skill": return nil
        default: return tool.map { "Used \($0)" }
        }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ args: [String]) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            sqlite3_bind_text(statement, Int32(i + 1), arg, -1, transient)
        }
        var rows: [[String?]] = []
        let columns = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<columns).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                      let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
        return rows
    }
}
