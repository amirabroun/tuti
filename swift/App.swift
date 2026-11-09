import SwiftUI

/// v1 hard-codes where things live; the app launches the Python server from the tuti repo.
enum Config {
    static let serverURL = URL(string: "ws://127.0.0.1:8765")!
    static let repoURL = URL(fileURLWithPath: "/Users/amirabroun/Documents/repos/tuti")
    static let uvURL = URL(fileURLWithPath: "/Users/amirabroun/.local/bin/uv")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tuti/server.log")
    static let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/tuti/history.jsonl")
}

@main
struct TutiApp: App {
    @State private var model = TranscriptViewModel()

    var body: some Scene {
        // one window as the only scene: closing it quits the app, which stops the server and the mic
        Window("Tuti", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 420)
                .onAppear { model.appStart() }
        }
    }
}

struct ContentView: View {
    let model: TranscriptViewModel
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText)
                Spacer()
                if model.phase == .recording {
                    Text(String(format: "%.0f dB", model.levelDb)).monospacedDigit()
                }
                Picker("Style", selection: Bindable(model).spoken) {
                    Text("Spoken").tag(true)
                    Text("Formal").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .controlSize(.mini)
                Toggle("Auto-stop", isOn: Bindable(model).autoStop).toggleStyle(.checkbox)
                Button("Re-clean", action: model.reclean).buttonStyle(.borderless)
                    .disabled(model.cards.last?.text.isEmpty != false)
                Button("History") { showHistory = true }.buttonStyle(.borderless)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.cards.isEmpty {
                            Text("Press Record (Space) — click a card to copy it")
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(model.cards) { card in
                            CardView(card: card,
                                     isActive: !card.isFinal && card.id == model.cards.last?.id,
                                     partial: card.id == model.cards.last?.id && !card.isFinal
                                        ? model.partial : "",
                                     cleaning: model.cleaning)
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

            Button(action: model.toggleRecord) {
                Label(model.phase == .recording ? "Stop" : "Record",
                      systemImage: model.phase == .recording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.phase != .ready && model.phase != .recording)
        }
        .padding()
        .sheet(isPresented: $showHistory) { HistoryPanel(model: model) }
    }

    private var statusText: String {
        switch model.phase {
        case .starting: return "Loading the model…"
        case .ready: return model.copied ? "Ready · copied" : "Ready"
        case .recording: return "Listening"
        case .finalizing: return "Finishing…"
        }
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

/// One dictation card: click to copy. The active recording card also shows the live partial
/// and the AI round-trip (pulsing dot + thin progress bar).
struct CardView: View {
    let card: Card
    let isActive: Bool
    let partial: String
    let cleaning: Bool
    @State private var copied = false
    @State private var pulse = false

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
                Text(copied ? "copied ✓" : card.ts).font(.caption2).foregroundStyle(.secondary)
            }
            if !card.text.isEmpty {
                Text(card.text).multilineTextAlignment(.leading)
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
            NSPasteboard.general.setString(card.text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
    }
}

/// Message history: every resolved segment, newest first; click a row to copy it.
struct HistoryPanel: View {
    let model: TranscriptViewModel
    @State private var entries: [HistoryEntry] = []
    @State private var search = ""
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Clear") { confirmClear = true }
                    .disabled(entries.isEmpty)
                Button("Done") { dismiss() }
            }
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List(filtered.reversed()) { entry in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.clean ?? entry.raw, forType: .string)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.ts).font(.caption).foregroundStyle(.secondary)
                        Text(entry.clean ?? entry.raw)
                            .foregroundStyle(entry.clean == nil ? .secondary : .primary)
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .environment(\.layoutDirection, .rightToLeft)  // Persian rows: leading edge is the right
        }
        .padding()
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { entries = model.loadHistory() }
        .confirmationDialog("Delete the whole history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.clearHistory()
                entries = []
            }
        }
    }

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { [$0.ts, $0.raw, $0.clean ?? ""].contains { $0.localizedStandardContains(q) } }
    }
}
