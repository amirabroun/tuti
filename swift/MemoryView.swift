import SwiftUI

/// One checkbox line of the memory file: `- [ ] 2026-11-21 — خرید کاپشن چرم`.
struct MemoryTask: Identifiable {
    let id: Int  // the line's order in the file — the merge prompt keeps it stable
    let done: Bool
    let date: String?  // the ISO «YYYY-MM-DD» prefix when the line carries one
    let category: String?  // the «##» heading it sits under; nil = directly under «# کارها» (not yet categorized)
    let text: String

    /// An open task whose day has passed — shown in orange so it nags without a sound.
    var overdue: Bool {
        guard let date, !done else { return false }
        return date < Self.today
    }

    static let today: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()
}

/// The parsed memory file: the two sections tuti keeps («# کارها» checkbox lines grouped
/// under the AI-chosen «##» category headings, «# حقایق» bullets). Anything else in the
/// file is ignored, so it stays hand-editable.
struct MemoryFile {
    var tasks: [MemoryTask] = []
    var facts: [String] = []

    static func load() -> MemoryFile {
        guard let s = try? String(contentsOf: Config.memoryURL, encoding: .utf8) else {
            return MemoryFile()  // no file yet: the panel shows its empty state
        }
        return parse(s)
    }

    static func parse(_ s: String) -> MemoryFile {
        var f = MemoryFile()
        var section = ""
        var category: String? = nil  // the current «##» heading; a «# کارها» line resets it
        for line in s.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("# ") {
                section = String(l.dropFirst(2))
                category = nil
            } else if l.hasPrefix("## "), section == "کارها" {
                category = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("- ") {
                let body = String(l.dropFirst(2))
                if section == "کارها", let task = task(from: body, category: category, id: f.tasks.count) {
                    f.tasks.append(task)
                } else if section == "حقایق" {
                    f.facts.append(body)
                }
            }
        }
        return f
    }

    /// `- [x] 2026-11-21 — توضیح` → (done, date, text); a non-checkbox line is not a task.
    private static func task(from body: String, category: String?, id: Int) -> MemoryTask? {
        var rest = body
        let done: Bool
        if rest.hasPrefix("[x] ") {
            done = true
        } else if rest.hasPrefix("[ ] ") {
            done = false
        } else {
            return nil
        }
        rest = String(rest.dropFirst(4))
        var date: String? = nil
        if rest.count >= 10 {
            let head = String(rest.prefix(10))
            if head.allSatisfy({ $0.isNumber && $0.isASCII || $0 == "-" }) {
                date = head
                rest = String(rest.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("—") {
                    rest = String(rest.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return MemoryTask(id: id, done: done, date: date, category: category, text: rest)
    }
}

/// The «حافظه» tab: the memory file rendered read-only (the file is the source of truth —
/// hand-edit it via «باز کردن فایل»), grouped into the AI-chosen «##» categories with an
/// «امروز» group on top. Same card language as the Settings tab (quaternary fill, 10-pt
/// radius) so the tabs read as one app.
struct MemoryPanelView: View {
    let model: TranscriptViewModel
    @State private var chatDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer()
                        Button {
                            model.reloadMemory()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("بازخوانی فایل حافظه")
                        Button {
                            NSWorkspace.shared.open(Config.memoryURL)
                        } label: {
                            Image(systemName: "doc.text")
                        }
                        .buttonStyle(.borderless)
                        .help("باز کردن فایل در ویرایشگر (~/Documents/tuti-memory/memory.md)")
                        Button {
                            NSWorkspace.shared.open(Config.memoryLogURL)
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!FileManager.default.fileExists(atPath: Config.memoryLogURL.path))
                        .help("لاگ حافظه (memory_log.jsonl) — هر ضبط و گفت‌وگو: متن خام + جواب AI، برای پردازش بعدی")
                    }

                    chatCard

                    if !model.memoryExists {
                        Text("هنوز چیزی ذخیره نشده — پایین، «ضبط» رو بزن و بگو.")
                            .foregroundStyle(.secondary)
                    }
                    if !model.memoryTasks.isEmpty {
                        // «امروز» first: open tasks due today or overdue, across all categories.
                        if !dueTasks.isEmpty {
                            section("امروز") {
                                ForEach(dueTasks) { taskRow($0) }
                            }
                        }
                        // then the «##» categories in file order; a file with no headings yet
                        // (until the first merge sorts it) renders as the old flat list
                        if let groups = categoryGroups, !(groups.count == 1 && groups[0].name == nil) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                section(group.name ?? "دیگر") {
                                    ForEach(group.tasks) { taskRow($0) }
                                }
                            }
                        } else {
                            section(tasksTitle) {
                                ForEach(model.memoryTasks) { task in
                                    taskRow(task)
                                }
                            }
                        }
                    }
                    if !model.memoryFacts.isEmpty {
                        section("حقایق (\(model.memoryFacts.count))") {
                            ForEach(Array(model.memoryFacts.enumerated()), id: \.offset) { _, fact in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(fact).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            recordBar
                .padding(12)
        }
        .frame(minWidth: 440, minHeight: 380)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { model.reloadMemory() }
    }

    /// The memory window's AI chat: a small thread over the memory file — the model
    /// answers in a sentence or two and may rewrite the file (a save, a rename, a tick);
    /// the list above updates live through the folder watcher.
    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text("گفت‌وگو با AI").font(.body.weight(.medium))
                Spacer()
                if !model.chatTurns.isEmpty {
                    Button {
                        model.clearChat()
                    } label: {
                        Image(systemName: "eraser")
                    }
                    .buttonStyle(.borderless)
                    .help("پاک کردن گفت‌وگوی این نشست — لاگ سرور همه‌چیز را نگه می‌دارد")
                }
            }
            if model.chatTurns.isEmpty {
                Text("به AI حافظه یه چیز بگو — مثلاً «فردا باید فلان کارو بکنم» یا «اسم کار اول رو عوض کن».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.chatTurns) { turn in
                            chatBubble(turn)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .defaultScrollAnchor(.bottom)
            }
            if model.chatPending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("در حال فکر کردن…").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.chatFailed {
                Text("جواب نیامد — دوباره بفرست.").font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                TextField("به AI بگو…", text: $chatDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendChat() }
                Button("بفرست", action: sendChat)
                    .disabled(model.chatPending || model.phase != .ready || model.memoryActive
                              || chatDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func sendChat() {
        model.sendChat(chatDraft)
        chatDraft = ""
    }

    /// His messages in a filled bubble, the AI's as a plain sparkles line — a quiet
    /// transcript look, no chat-app chrome.
    @ViewBuilder
    private func chatBubble(_ turn: ChatTurn) -> some View {
        if turn.isAI {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                Text(turn.text).font(.callout).textSelection(.enabled)
            }
        } else {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text).font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                    .textSelection(.enabled)
            }
        }
    }

    /// The «افزودن به حافظه» bar: the memory window's own recorder, separate from the
    /// main window's cards/clipboard flow — nothing is copied or pasted and no card is
    /// created; stopping merges the transcript straight into the memory file (the list
    /// updates live). Purple + brain, deliberately nothing like the main window's Record.
    private var recordBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("افزودن به حافظه").font(.caption).foregroundStyle(.secondary)
                Spacer()
                saveStateLine
            }
            if model.memoryActive {
                Text(model.memoryPartial.isEmpty ? "…" : model.memoryPartial)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                model.toggleMemoryRecord()
            } label: {
                Label(model.memoryActive ? "توقف" : "ضبط",
                      systemImage: model.memoryActive ? "stop.circle.fill" : "brain")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
            .disabled(model.phase != .ready && !model.memoryActive)
            .help("ضبط برای حافظه — با توقف، متن مستقیم توی memory.md ذخیره می‌شود")
        }
    }

    /// The merge outcome of the last memory recording, until it clears itself.
    @ViewBuilder
    private var saveStateLine: some View {
        switch model.memorySave {
        case .none:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("در حال ذخیره…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved:
            Label("حفظ شد", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .unchanged:
            Text("تغییری نکرد").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("ذخیره نشد", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// Open tasks due today or already overdue — the «امروز» group on top of the list.
    private var dueTasks: [MemoryTask] {
        model.memoryTasks.filter { !$0.done && ($0.date == MemoryTask.today || $0.overdue) }
    }

    /// Tasks folded into their «##» categories, file order preserved; a task directly under
    /// «# کارها» lands in the nil-name group. nil = the file has no headings at all.
    private var categoryGroups: [(name: String?, tasks: [MemoryTask])]? {
        guard !model.memoryTasks.isEmpty else { return nil }
        var order: [String?] = []
        var buckets: [String?: [MemoryTask]] = [:]
        for task in model.memoryTasks {
            if buckets[task.category] == nil { order.append(task.category) }
            buckets[task.category, default: []].append(task)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// «کارها — ۲ باز از ۳» (or just the count when everything is open) — a glance at the
    /// state without reading the rows.
    private var tasksTitle: String {
        let open = model.memoryTasks.filter { !$0.done }.count
        return open == model.memoryTasks.count
            ? "کارها (\(model.memoryTasks.count))"
            : "کارها — \(open) باز از \(model.memoryTasks.count)"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            content()
        }
    }

    /// File order is respected (the merge owns it); done rows gray out with a strike,
    /// an open past-date task tints its date orange.
    private func taskRow(_ task: MemoryTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.done ? "checkmark.square.fill" : "square")
                .foregroundStyle(task.done ? Color.green : Color.secondary)
            Text(task.text)
                .strikethrough(task.done)
                .foregroundStyle(task.done ? Color.primary.opacity(0.35) : Color.primary)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let date = task.date {
                Text(date).font(.caption).monospacedDigit()
                    .foregroundStyle(task.overdue ? Color.orange : Color.secondary)
            }
        }
    }
}
