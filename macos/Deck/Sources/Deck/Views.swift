import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            if let task = store.selectedTask {
                TaskDetail(task: task).id(task.id)
            } else {
                Composer()
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List(selection: $store.selection) {
            Label("New Task", systemImage: "square.and.pencil")
                .tag(Store.newTaskID)
                .padding(.vertical, 3)

            section("Needs you", .needsYou)
            section("Working", .working)
            section("Finished", .finished)
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if let error = store.listError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if store.loaded && store.tasks.isEmpty {
                Text("No tasks yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ phase: Phase) -> some View {
        let tasks = store.section(phase)
        if !tasks.isEmpty {
            Section(title) {
                ForEach(tasks) { task in
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        TaskRow(task: task)
                    }
                    .tag(task.id)
                }
            }
        }
    }
}

struct TaskRow: View {
    let task: DeckTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(phase: task.phase)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if let note = task.note, task.phase == .needsYou { return note }
        let when = task.created.map { RelativeDateTimeFormatter.short.localizedString(for: $0, relativeTo: Date()) }
        return [task.repo, when].compactMap { $0 }.joined(separator: " · ")
    }
}

struct StatusDot: View {
    let phase: Phase
    @State private var pulse = false

    var body: some View {
        switch phase {
        case .needsYou:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .working:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What should I work on?")
                .font(.system(size: 28, weight: .semibold))

            TextField("Describe the task…", text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(4...12)
                .focused($focused)
                .onSubmit(store.startTask)
                .disabled(store.starting)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)

            HStack(spacing: 14) {
                Picker("", selection: $store.repo) {
                    ForEach(Repo.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Picker("", selection: $store.engine) {
                    ForEach(Engine.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Spacer()

                if store.starting {
                    ProgressView().controlSize(.small)
                    Text("Setting up…").foregroundStyle(.secondary)
                } else {
                    Button("Start", action: store.startTask)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let error = store.startError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else {
                Text("Press Return to start. It works on its own branch and opens a pull request when it's done.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 620)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .onChange(of: store.composerFocus) { focused = true }
    }
}

// MARK: - Task detail

struct TaskDetail: View {
    @EnvironmentObject var store: Store
    let task: DeckTask
    @State private var message = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var confirmArchive = false
    @FocusState private var replyFocused: Bool

    private var conversation: Conversation? { store.conversations[task.id] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if task.phase == .needsYou, let note = task.note {
                            callout(note)
                        }
                        if let pr = conversation?.pullRequest {
                            Button {
                                NSWorkspace.shared.open(pr)
                            } label: {
                                Label("Open pull request", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                        }
                        Divider()
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: conversation?.entries.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            replyBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Open in Terminal") { store.openInTerminal(task) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.path)])
                    }
                    if !task.branch.isEmpty {
                        Button("Copy Branch Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(task.branch, forType: .string)
                        }
                    }
                    Divider()
                    Button("Archive", role: .destructive) { confirmArchive = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
            }
        }
        .confirmationDialog("Archive “\(task.title)”?", isPresented: $confirmArchive) {
            Button("Archive", role: .destructive) { store.archive(task) }
        } message: {
            Text("The session stops and leaves the list. Its branch and any pull request stay.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.system(size: 24, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                StatusDot(phase: task.phase)
                Text(statusText)
                Text("·")
                Text(task.repo)
                Text("·")
                Text(task.tool == "claude" ? "Claude" : "DeepSeek")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch task.phase {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .finished: return "Finished"
        }
    }

    private func callout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    @ViewBuilder
    private var content: some View {
        let entries = conversation?.entries ?? []
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .user(let text):
                    HStack {
                        Spacer(minLength: 80)
                        Text(text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.7)))
                    }
                case .assistant(let text):
                    MarkdownView(text: text)
                case .steps(let steps):
                    StepsView(steps: steps)
                case .autoContinued:
                    Text("Continued automatically")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            if task.phase == .working {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working on it…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if entries.isEmpty {
                Text("Nothing to show yet.").foregroundStyle(.tertiary)
            }
        }
    }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(task.phase == .working ? "Add a note…" : "Reply…", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($replyFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.quaternary.opacity(0.6)))
                if sending {
                    ProgressView().controlSize(.small).padding(.bottom, 8)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(message.isEmpty ? Color.secondary : Color.accentColor)
                    .disabled(message.isEmpty)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func send() {
        guard !sending else { return }
        let text = message
        sending = true
        sendError = nil
        Task {
            let error = await store.reply(to: task, text)
            sending = false
            if let error { sendError = error } else { message = "" }
        }
    }
}

/// A run of tool steps, condensed to one quiet line that expands on click.
struct StepsView: View {
    let steps: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Text(step).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.leading, 15)
            }
        }
    }

    private var summary: String {
        let count = steps.count == 1 ? "1 step" : "\(steps.count) steps"
        return "\(count) · \(steps.suffix(2).joined(separator: ", "))"
    }
}

// MARK: - Markdown

/// Renders an agent reply: headings, code blocks and paragraphs with inline Markdown.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(String), code(String), paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s):
                    Text(inline(s)).font(.headline).padding(.top, 4)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.system(.callout, design: .monospaced))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                case .paragraph(let s):
                    Text(inline(s)).lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
        .font(.system(size: 14))
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if let bullet = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                let indent = line[..<bullet.lowerBound].count / 2
                paragraph.append(String(repeating: "    ", count: indent) + "•  " + line[bullet.upperBound...])
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }

    private func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

extension RelativeDateTimeFormatter {
    static let short: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
