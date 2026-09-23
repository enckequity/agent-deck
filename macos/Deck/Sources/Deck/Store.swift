import AppKit
import Foundation
import UserNotifications

enum Phase: Int {
    case needsYou, working, finished
}

struct DeckTask: Identifiable, Equatable {
    let id: String
    let title: String
    let repo: String
    let path: String
    let tool: String
    let status: String
    let created: Date?
    var phase: Phase
    var note: String?
}

enum Repo: String, CaseIterable, Identifiable {
    case teamshift, enckOS = "enck-os"
    var id: String { rawValue }
    var name: String { self == .teamshift ? "TeamShift" : "Enck OS" }
}

enum Engine: String, CaseIterable, Identifiable {
    case opencode, claude
    var id: String { rawValue }
    var name: String { self == .opencode ? "Fast · DeepSeek" : "Smart · Claude" }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let newTaskID = "__new__"

    @Published private(set) var tasks: [DeckTask] = []
    private var sessions: [RawSession] = []
    @Published private(set) var conversations: [String: Conversation] = [:]
    // `open Deck.app --args -select <session id>` opens straight to a task.
    @Published var selection: String? = UserDefaults.standard.string(forKey: "select") ?? Store.newTaskID
    @Published private(set) var loaded = false
    @Published private(set) var listError: String?

    @Published var draft = ""
    @Published var repo: Repo = Repo(rawValue: UserDefaults.standard.string(forKey: "repo") ?? "") ?? .teamshift {
        didSet { UserDefaults.standard.set(repo.rawValue, forKey: "repo") }
    }
    @Published var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .opencode {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published private(set) var starting = false
    @Published var startError: String?
    @Published var composerFocus = 0

    private var pendingSelectAfter: Date?
    private var claudeStatus: [String: String] = [:]
    /// Deck session id → its Claude Code transcript, and the file stamp last read from it.
    private var claudeTranscripts: [String: String] = [:]
    private var transcriptStamps: [String: FileStamp] = [:]
    private var claudeLoading: Set<String> = []
    private var claudeDirty: Set<String> = []
    private var watcher: FileWatcher?
    private var refreshing = false
    private var refreshQueued = false
    private var queuedFull = false

    var selectedTask: DeckTask? { tasks.first { $0.id == selection } }

    func section(_ phase: Phase) -> [DeckTask] { tasks.filter { $0.phase == phase } }

    // MARK: polling

    /// Event-driven: agent-deck registry writes re-list sessions; opencode history writes only
    /// re-read that history in-process, and a Claude transcript write re-reads just that task.
    /// A slow timer remains for crashes, which leave no file trace.
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let share = "\(CLI.home)/.local/share"
        let watched = ["\(share)/agent-deck/profiles", "\(share)/opencode", ClaudeHistory.projectsPath]
        watcher = FileWatcher(paths: watched) { [weak self] paths in
            let names = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
            let transcripts = Set(paths.filter { $0.hasSuffix(".jsonl") })
            Task { @MainActor in
                guard let self else { return }
                let changed = self.claudeTranscripts.filter { transcripts.contains($0.value) }.map(\.key)
                if !changed.isEmpty { self.reloadClaude(changed) }
                if !names.isDisjoint(with: ["state.db", "state.db-wal"]) {
                    self.requestRefresh(full: true)
                } else if !names.isDisjoint(with: ["opencode.db", "opencode.db-wal"]) {
                    self.requestRefresh(full: false)
                }
            }
        }
        requestRefresh(full: true)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                requestRefresh(full: true)
            }
        }
    }

    /// Coalesces bursts of file events (a streaming reply writes many times a second) into
    /// at most one refresh in flight plus one queued behind it.
    func requestRefresh(full: Bool = true) {
        guard !refreshing else {
            queuedFull = queuedFull || full
            refreshQueued = true
            return
        }
        refreshing = true
        Task {
            if full { await refresh() } else { await loadConversations(); recompute() }
            if ProcessInfo.processInfo.environment["DECK_DEBUG"] != nil {
                FileHandle.standardError.write("refresh full=\(full) \(Date())\n".data(using: .utf8)!)
            }
            try? await Task.sleep(for: .milliseconds(400))
            refreshing = false
            if refreshQueued {
                let nextFull = queuedFull
                refreshQueued = false
                queuedFull = false
                requestRefresh(full: nextFull)
            }
        }
    }

    func refresh() async {
        let result = await CLI.deck("list", "--json")
        let raw: [RawSession]
        if result.ok, let decoded = try? JSONDecoder().decode([RawSession].self, from: result.stdout) {
            raw = decoded
            listError = nil
        } else if result.text.contains("No sessions") || result.stderr.contains("No sessions") {
            raw = []
            listError = nil
        } else {
            listError = "agent-deck isn't responding (\(result.reason))"
            return
        }

        sessions = raw.filter { $0.archived != true }
        await loadConversations()
        recompute()
        if let after = pendingSelectAfter, let newest = tasks.first(where: { ($0.created ?? .distantPast) >= after }) {
            selection = newest.id
            pendingSelectAfter = nil
        }
        if let sel = selection, sel != Store.newTaskID, loaded, !tasks.contains(where: { $0.id == sel }) {
            selection = Store.newTaskID
        }
    }

    /// Rebuilds tasks from the latest session list and replies; notifies on phase changes.
    private func recompute() {
        let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.phase) })
        let next = sessions.map { makeTask($0) }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        if loaded {
            for task in next where previous[task.id].map({ $0 != task.phase }) ?? false {
                notify(task)
            }
        }
        tasks = next
        loaded = true
        let waiting = next.filter { $0.phase == .needsYou }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    private func makeTask(_ s: RawSession) -> DeckTask {
        let conversation = conversations[s.id]
        var phase: Phase
        var note: String?
        if s.status == "error" {
            phase = .needsYou
            note = "Stopped unexpectedly"
        } else if s.status == "running" || s.status == "starting" || (s.status != "stopped" && conversation?.busy == true) {
            phase = .working
        } else {
            switch conversation?.marker {
            case .done: phase = .finished
            case .blocked(let why): phase = .needsYou; note = why
            case .waiting(let why): phase = .needsYou; note = why
            default: phase = s.status == "waiting" ? .needsYou : .finished
            }
        }
        let url = URL(fileURLWithPath: s.path)
        var repoName = s.group.isEmpty ? url.lastPathComponent : s.group
        if repoName == "teamshift" { repoName = "TeamShift" }
        if repoName == "enck-os" { repoName = "Enck OS" }
        return DeckTask(id: s.id, title: conversation?.title ?? Self.prettyTitle(s.title), repo: repoName,
                        path: s.path, tool: s.tool, status: s.status,
                        created: Self.parseDate(s.created_at), phase: phase, note: note)
    }

    /// opencode history is read straight from its database on every poll (cheap, read-only).
    /// Claude history is read from its transcript file; `agent-deck session show` names that
    /// file, refetched when the session's status changes (a restart can start a new transcript).
    private func loadConversations() async {
        let opencode = sessions.filter { $0.tool != "claude" }.map { ($0.id, $0.path) }
        let loaded = await Task.detached(priority: .userInitiated) {
            opencode.compactMap { id, path in OpenCodeHistory.load(directory: path).map { (id, $0) } }
        }.value
        for (id, conversation) in loaded where conversations[id] != conversation {
            conversations[id] = conversation
        }

        let claude = sessions.filter { $0.tool == "claude" }
        // Looked up once per status, so a session without a transcript yet costs no extra CLI calls;
        // its path is still watched, so the file's first write loads it.
        let stale = claude.filter { claudeStatus[$0.id] != $0.status }
        let located = await withTaskGroup(of: (RawSession, String?).self) { group in
            for session in stale {
                group.addTask {
                    let result = await CLI.deck("session", "show", session.id, "--json")
                    guard let show = try? JSONDecoder().decode(RawShow.self, from: result.stdout),
                          let claudeID = show.claude_session_id, !claudeID.isEmpty else { return (session, nil) }
                    return (session, ClaudeHistory.transcriptPath(directory: show.path ?? session.path, claudeSessionID: claudeID))
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (session, path) in located {
            let statusChanged = claudeStatus[session.id] != session.status
            claudeStatus[session.id] = session.status
            if let path {
                if claudeTranscripts[session.id] != path { transcriptStamps[session.id] = nil }
                claudeTranscripts[session.id] = path
            }
            if statusChanged, !FileManager.default.fileExists(atPath: path ?? "") {
                loadLastReply(session.id)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for id in claude.map(\.id) where claudeTranscripts[id] != nil {
                group.addTask { await self.loadClaude(id) }
            }
        }
    }

    /// Re-reads just these tasks' transcripts after a file event, then updates the list.
    private func reloadClaude(_ ids: [String]) {
        Task {
            for id in ids { await loadClaude(id) }
            recompute()
        }
    }

    /// Reads one transcript off the main thread when its file changed since the last read.
    /// Overlapping requests for the same task collapse into one re-read after the current one.
    private func loadClaude(_ id: String) async {
        guard claudeTranscripts[id] != nil else { return }
        guard !claudeLoading.contains(id) else { claudeDirty.insert(id); return }
        claudeLoading.insert(id)
        defer { claudeLoading.remove(id) }
        repeat {
            claudeDirty.remove(id)
            guard let path = claudeTranscripts[id] else { break }
            let stamp = FileStamp(path: path)
            guard stamp == nil || stamp != transcriptStamps[id] else { continue }
            if let conversation = await Task.detached(priority: .userInitiated, operation: { ClaudeHistory.load(path: path) }).value {
                transcriptStamps[id] = stamp
                if conversations[id] != conversation { conversations[id] = conversation }
            }
        } while claudeDirty.contains(id)
    }

    /// Fallback when a Claude session has no transcript on disk: its last reply via the CLI.
    private func loadLastReply(_ id: String) {
        Task {
            let result = await CLI.deck("session", "output", id, "--json")
            let content = (try? JSONDecoder().decode(RawOutput.self, from: result.stdout))?.content ?? ""
            let conversation = Conversation.lastReply(content)
            if transcriptStamps[id] == nil, conversations[id] != conversation {
                conversations[id] = conversation
                recompute()
            }
        }
    }

    // MARK: actions

    func startTask() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        starting = true
        startError = nil
        let began = Date().addingTimeInterval(-2)
        Task {
            let result = await CLI.run(CLI.deckTask, ["-c", engine.rawValue, "-r", repo.rawValue, text], login: true)
            starting = false
            if result.ok {
                draft = ""
                pendingSelectAfter = began
                requestRefresh()
            } else if let free = result.reason.range(of: #"only \d+GiB free"#, options: .regularExpression) {
                let gb = result.reason[free].filter(\.isNumber)
                startError = "Your Mac only has \(gb) GB of free disk space. Free up some space and try again."
            } else {
                startError = result.reason
            }
        }
    }

    func reply(to task: DeckTask, _ message: String) async -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if task.status == "stopped" || task.status == "error" {
            let start = await CLI.run(CLI.agentDeck, ["session", "start", task.id], login: true)
            if !start.ok { return start.reason }
        }
        var args = ["session", "send", task.id, text]
        if task.phase == .working { args.append("--defer-if-busy") }
        let result = await CLI.run(CLI.agentDeck, args, login: true)
        requestRefresh()
        return result.ok ? nil : result.reason
    }

    /// Copies the task's branch using agent-deck's native `worktree info` rather
    /// than inferring it from the worktree path (which the native creator sanitizes).
    func copyBranch(_ task: DeckTask) {
        Task {
            let result = await CLI.deck("worktree", "info", task.id, "--json")
            guard let info = try? JSONDecoder().decode(RawWorktreeInfo.self, from: result.stdout), !info.branch.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.branch, forType: .string)
        }
    }

    func archive(_ task: DeckTask) {
        Task {
            _ = await CLI.deck("session", "archive", task.id)
            selection = Store.newTaskID
            requestRefresh()
        }
    }

    func openInTerminal(_ task: DeckTask) {
        let command = "\(CLI.agentDeck) session attach \(task.id)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func newTask() {
        selection = Store.newTaskID
        composerFocus += 1
    }

    // MARK: notifications

    private func notify(_ task: DeckTask) {
        guard task.phase != .working else { return }
        let content = UNMutableNotificationContent()
        content.title = task.phase == .needsYou ? "Needs you" : "Finished"
        content.body = task.note.map { "\(task.title) — \($0)" } ?? task.title
        content.userInfo = ["id": task.id]
        if task.phase == .needsYou { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(task.id)-\(task.phase)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: parsing

    static func prettyTitle(_ raw: String) -> String {
        let spaced = raw.contains(" ") ? raw : raw.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

struct RawSession: Decodable {
    let id: String
    let title: String
    let path: String
    let group: String
    let tool: String
    let status: String
    let created_at: String?
    let archived: Bool?
}

private struct RawShow: Decodable {
    let claude_session_id: String?
    let path: String?
}

/// Size and modification date, to skip re-reading a transcript that has not changed.
private struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date

    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.size = size
        self.modified = modified
    }
}

private struct RawOutput: Decodable {
    let content: String?
}

private struct RawWorktreeInfo: Decodable {
    let branch: String
}
