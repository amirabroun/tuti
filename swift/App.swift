import ServiceManagement
import SwiftUI

/// v1 hard-codes where things live; the app launches the Python server from the tuti repo.
enum Config {
    static let serverURL = URL(string: "ws://127.0.0.1:8765")!
    static let repoURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/repos/tuti")
    static let uvURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/uv")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tuti/server.log")
    static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/tuti/history.jsonl")
}

@main
struct TutiApp: App {
    @State private var model = TranscriptViewModel()

    var body: some Scene {
        // closing the window hides to the menu bar (it is a scene too); Quit lives there
        Window("Tuti", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 460, minHeight: 440)
                .onAppear { model.appStart() }
        }
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.phase == .recording ? "mic.fill" : "waveform")
        }
    }
}

/// The menu-bar dropdown: status, record, recent cards, tokens, login toggle.
private struct MenuBarContent: View {
    let model: TranscriptViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(model.statusText)
        Text("tokens: \(model.tokensIn.formatted()) in · \(model.tokensOut.formatted()) out")
        Divider()
        Button(model.phase == .recording ? "Stop" : "Record") { model.uiToggleRecord() }
            .disabled(model.phase != .ready && model.phase != .recording)
        Divider()
        ForEach(model.cards.suffix(5).reversed()) { card in
            Button(menuTitle(card.text)) { model.copyText(card.text) }
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    launchAtLogin = on
                } catch {
                    model.reportError("Launch at Login failed: \(error.localizedDescription)")
                }
            }))
        Button("Open Tuti") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Tuti") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

struct ContentView: View {
    let model: TranscriptViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(model.statusText)
                Spacer()
                if model.phase == .recording {
                    Text(String(format: "%.0f dB", model.levelDb)).monospacedDigit()
                }
                Toggle("Auto-stop", isOn: Bindable(model).autoStop).toggleStyle(.checkbox)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search cards", text: Bindable(model).searchQuery)
                    .textFieldStyle(.roundedBorder)
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.visibleCards.isEmpty {
                            Text(model.searchQuery.isEmpty
                                 ? "Press Record (Space or ⌥Space) — click a card to copy it"
                                 : "Nothing matches")
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(model.visibleCards) { card in
                            CardView(card: card,
                                     isActive: !card.isFinal && card.id == model.cards.last?.id,
                                     partial: card.id == model.cards.last?.id && !card.isFinal
                                        ? model.partial : "",
                                     cleaning: model.cleaning,
                                     onEdit: model.editCard,
                                     onDelete: model.deleteCard,
                                     onRunIntent: model.runIntent)
                                .id(card.id)
                        }
                    }
                    .font(.title3)
                    .padding(.horizontal, 2)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.cards.count) { _, _ in
                    if let id = model.cards.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .environment(\.layoutDirection, .rightToLeft)  // Persian: leading edge is the right
            }

            if !model.lastError.isEmpty {
                HStack {
                    Text(model.lastError).foregroundStyle(.red)
                    if model.serverFailed {
                        Button("Retry", action: model.retryServer).buttonStyle(.borderless)
                        Button("Show Log", action: model.showLog).buttonStyle(.borderless)
                    }
                }
                .font(.caption)
            }

            Button(action: model.uiToggleRecord) {
                Label(model.phase == .recording ? "Stop" : "Record",
                      systemImage: model.phase == .recording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.phase != .ready && model.phase != .recording)
        }
        .padding()
    }

    private var statusColor: Color {
        switch model.phase {
        case .starting: .orange
        case .ready: .green
        case .recording: .red
        case .finalizing: .yellow
        }
    }
}

/// One dictation card: click to copy. Finished cards also carry edit / raw-view / delete
/// buttons and, when the transcript parsed as a command, an action chip. The active
/// recording card shows the live partial and the AI round-trip (pulsing dot + progress bar).
struct CardView: View {
    let card: Card
    let isActive: Bool
    let partial: String
    let cleaning: Bool
    var onEdit: (UUID, String) -> Void
    var onDelete: (UUID) -> Void
    var onRunIntent: (UUID) -> Void

    @State private var copied = false
    @State private var pulse = false
    @State private var editing = false
    @State private var draft = ""
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if isActive && cleaning {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                                   value: pulse)
                        .onAppear { pulse = true }
                    Text("در حال ویرایش…").font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if card.isFinal { controls }
                Text(copied ? "copied ✓" : card.ts).font(.caption2).foregroundStyle(.secondary)
            }
            if editing {
                TextField("text", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit() }
                HStack {
                    Button("Save") { commitEdit() }
                    Button("Cancel") { editing = false }
                }
                .controlSize(.small)
            } else if !display.isEmpty {
                Text(display).multilineTextAlignment(.leading)
            }
            if card.isFinal, let action = card.intent {
                if card.intentDone {
                    Label("انجام شد", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button { onRunIntent(card.id) } label: {
                        Label(action.label, systemImage: action.icon).font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            if isActive {
                if !partial.isEmpty {
                    Text(partial).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                } else if card.text.isEmpty {
                    Text("…").foregroundStyle(.tertiary)
                }
                if cleaning {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(.orange)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isActive ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(.rect)
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(display, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
    }

    /// The «خام» before/after flip: the original ASR text when there is one to compare.
    private var display: String {
        if showRaw, let raw = card.raw, !raw.isEmpty { return raw }
        return card.text
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { draft = card.text; editing = true } label: {
                Image(systemName: "pencil")
            }
            if let raw = card.raw, !raw.isEmpty, raw != card.text {
                Button { showRaw.toggle() } label: {
                    Text(showRaw ? "ویراست" : "خام")
                }
            }
            Button { onDelete(card.id) } label: {
                Image(systemName: "trash")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func commitEdit() {
        editing = false
        onEdit(card.id, draft)
    }
}
