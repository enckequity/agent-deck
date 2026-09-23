import Foundation

/// Reads Claude Code's own transcript (read-only) so a Claude task shows its whole
/// conversation: ~/.claude/projects/<encoded path>/<claude session id>.jsonl.
enum ClaudeHistory {
    static let projectsPath = "\(NSHomeDirectory())/.claude/projects"
    /// Only the tail of a long transcript is read, like the newest 800 opencode parts.
    static let tailBytes = 8 << 20

    /// Claude Code names a project's folder after its path with every non-alphanumeric
    /// character replaced by "-" (/Users/me/.x → -Users-me--x).
    static func transcriptPath(directory: String, claudeSessionID: String) -> String {
        let encoded = String(directory.unicodeScalars.map {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-"
        })
        return "\(projectsPath)/\(encoded)/\(claudeSessionID).jsonl"
    }

    static func load(path: String) -> Conversation? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]  // drop the partial first line
        }
        return parse(data)
    }

    /// Builds the same model as opencode: user bubbles, assistant text, and each run of
    /// tool calls folded into one steps entry. Meta, sidechain and command noise is skipped.
    static func parse(_ data: Data) -> Conversation {
        var conversation = Conversation()
        var steps: [String] = []
        var lastAssistantText = ""
        func flushSteps() {
            if !steps.isEmpty { conversation.entries.append(.steps(steps)); steps = [] }
        }

        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(RawEntry.self, from: line),
                  entry.isSidechain != true, let message = entry.message else { continue }
            switch entry.type {
            case "user":
                let text = message.content.text
                if text.hasPrefix("Stop hook feedback:") {
                    flushSteps()
                    conversation.entries.append(.autoContinued)
                    conversation.busy = true
                    lastAssistantText = ""
                    continue
                }
                if message.content.hasToolResult { conversation.busy = true; continue }
                guard entry.isMeta != true, entry.isCompactSummary != true,
                      let prompt = userPrompt(text) else { continue }
                flushSteps()
                conversation.entries.append(prompt.hasPrefix("Auto-continue (") ? .autoContinued : .user(prompt))
                conversation.busy = true
                lastAssistantText = ""
            case "assistant":
                conversation.busy = message.stop_reason != "end_turn"
                for block in message.content.blocks {
                    switch block.type {
                    case "text":
                        let text = block.text ?? ""
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        flushSteps()
                        var scratch = Conversation()
                        let cleaned = scratch.absorbMarkers(text)
                        if !cleaned.isEmpty { conversation.entries.append(.assistant(cleaned)) }
                        lastAssistantText = text
                        if let url = scratch.pullRequest { conversation.pullRequest = url }
                    case "tool_use":
                        let input = block.input
                        let tool = block.name.map(toolName)
                        if let label = OpenCodeHistory.stepLabel(tool: tool, file: input?.file_path ?? input?.notebook_path,
                                                                 command: input?.command, description: input?.description,
                                                                 pattern: input?.pattern) {
                            steps.append(label)
                        }
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }
        flushSteps()
        var tail = Conversation()
        _ = tail.absorbMarkers(lastAssistantText)
        conversation.marker = tail.marker
        return conversation
    }

    /// The person's words from a user turn, or nil for harness noise (slash-command echoes,
    /// task notifications, system reminders, interruptions).
    static func userPrompt(_ text: String) -> String? {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // agent-deck wraps what it sends in <pasted_content id="…"> tags.
        prompt = prompt.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
        prompt = OpenCodeHistory.stripLauncherContext(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !prompt.hasPrefix("<"), !prompt.hasPrefix("[Request interrupted") else { return nil }
        return prompt
    }

    /// Maps Claude Code tool names onto the opencode names `stepLabel` knows.
    static func toolName(_ name: String) -> String {
        if name.hasPrefix("mcp__") { return name.split(separator: "_").last.map(String.init) ?? name }
        switch name {
        case "Agent", "Task": return "task"
        case "NotebookEdit": return "edit"
        case "ToolSearch", "TodoWrite", "AskUserQuestion", "Skill", "ExitPlanMode", "EnterPlanMode": return "todowrite"
        default: return name.lowercased()
        }
    }

    // MARK: JSONL shapes (only the fields Deck reads)

    private struct RawEntry: Decodable {
        let type: String?
        let isMeta: Bool?
        let isSidechain: Bool?
        let isCompactSummary: Bool?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let content: RawContent
        let stop_reason: String?
    }

    /// `content` is either a plain string or an array of blocks.
    private struct RawContent: Decodable {
        var blocks: [RawBlock] = []

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                blocks = [RawBlock(type: "text", text: text, name: nil, input: nil)]
            } else {
                blocks = (try? container.decode([RawBlock].self)) ?? []
            }
        }

        var text: String { blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n") }
        var hasToolResult: Bool { blocks.contains { $0.type == "tool_result" } }
    }

    private struct RawBlock: Decodable {
        let type: String
        let text: String?
        let name: String?
        let input: RawInput?

        init(type: String, text: String?, name: String?, input: RawInput?) {
            self.type = type; self.text = text; self.name = name; self.input = input
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? c.decode(String.self, forKey: .type)) ?? ""
            text = try? c.decode(String.self, forKey: .text)
            name = try? c.decode(String.self, forKey: .name)
            input = try? c.decode(RawInput.self, forKey: .input)
        }

        private enum CodingKeys: String, CodingKey { case type, text, name, input }
    }

    private struct RawInput: Decodable {
        let file_path: String?
        let notebook_path: String?
        let command: String?
        let description: String?
        let pattern: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file_path = try? c.decode(String.self, forKey: .file_path)
            notebook_path = try? c.decode(String.self, forKey: .notebook_path)
            command = try? c.decode(String.self, forKey: .command)
            description = try? c.decode(String.self, forKey: .description)
            pattern = try? c.decode(String.self, forKey: .pattern)
        }

        private enum CodingKeys: String, CodingKey { case file_path, notebook_path, command, description, pattern }
    }
}
