import AppKit
import Observation

/// One resolved recording in the history file: the raw ASR text and, when cleaning worked, the clean text.
/// `id` exists since 2026-11-09 (edits/deletes find the line again); old lines match by ts+raw.
struct HistoryEntry: Codable {
    let id: UUID?
    let ts: String
    let raw: String
    var clean: String?

    enum CodingKeys: String, CodingKey { case id, ts, raw, clean }

    func matches(id: UUID, ts: String, raw: String?) -> Bool {
        if let own = self.id { return own == id }
        return self.ts == ts && self.raw == (raw ?? "")
    }
}

/// One dictation card in the main list: the cleaned text of one recording, kept until quit.
struct Card: Identifiable {
    let id: UUID
    let ts: String
    var text = ""
    var raw: String?  // the original ASR text of a finished card (the «خام» before/after view)
    var isFinal = false
    var intent: DictationAction?  // a parsed voice command, run only when its chip is clicked
    var intentDone = false

    init(id: UUID = UUID(), ts: String, text: String = "", raw: String? = nil, isFinal: Bool = false) {
        self.id = id
        self.ts = ts
        self.text = text
        self.raw = raw
        self.isFinal = isFinal
    }
}

/// App state: drives the server process, the socket and the mic; the window renders it.
@MainActor @Observable
final class TranscriptViewModel {
    enum Phase { case starting, ready, recording, finalizing }

    /// A speech pause this long sends the new speech for cleaning (the cleaned text before it is locked).
    let cutAfter: TimeInterval = 3
    /// With autoStop on, silence this long (since the last new text) ends the recording.
    let stopAfter: TimeInterval = 4

    private(set) var phase = Phase.starting
    private(set) var cards: [Card] = []  // one card per recording; the last non-final one is live
    private(set) var partial = ""  // raw speech since the last cut
    private(set) var levelDb: Float = -120
    private(set) var lastError = ""
    private(set) var copied = false
    private(set) var serverFailed = false
    private(set) var cleaning = false
    private(set) var tokensIn = 0  // cumulative LLM tokens the server reports after each call
    private(set) var tokensOut = 0
    var searchQuery = ""
    var autoStop: Bool { didSet { UserDefaults.standard.set(autoStop, forKey: "autoStop") } }

    var visibleCards: [Card] {
        guard !searchQuery.isEmpty else { return cards }
        return cards.filter {
            $0.text.localizedStandardContains(searchQuery)
                || ($0.raw ?? "").localizedStandardContains(searchQuery)
        }
    }

    var statusText: String {
        switch phase {
        case .starting: return "Loading the model…"
        case .ready: return copied ? "Ready · copied" : "Ready"
        case .recording: return "Listening"
        case .finalizing: return "Finishing…"
        }
    }

    private let sidecar = SidecarManager()
    private let socket = WSClient()
    private let mic = MicStreamer()
    private var started = false
    private var stallTask: Task<Void, Never>?
    private var finalRaw: String?  // asr_final's raw text, saved to history once its clean resolves
    private var hotkey: HotkeyCenter?
    private var pasteTask: Task<Void, Never>?
    /// The app that was frontmost when ⌥Space started the recording; the result pastes back into it.
    private var pasteTarget: NSRunningApplication?

    init() {
        let d = UserDefaults.standard
        autoStop = (d.object(forKey: "autoStop") as? Bool) ?? true
    }

    func appStart() {
        guard !started else { return }
        started = true
        cards = loadHistory().suffix(50)  // past recordings show as cards from the start
            .map { Card(id: $0.id ?? UUID(), ts: $0.ts, text: $0.clean ?? $0.raw, raw: $0.raw, isFinal: true) }
        socket.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        socket.onMessage = { [weak self] message in self?.handle(message) }
        sidecar.onExit = { [weak self] reason in
            self?.lastError = reason
            self?.serverFailed = true
        }
        mic.onChunk = { [socket] data in socket.sendAudio(data) }
        mic.onLevel = { [weak self] db in Task { @MainActor in self?.levelDb = db } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        hotkey = HotkeyCenter()
        hotkey?.onToggle = { [weak self] in Task { @MainActor in self?.hotkeyToggleRecord() } }
        hotkey?.start()
        sidecar.start()
        socket.connect()
    }

    /// Record/Stop button or Space, inside the window: the result stays a card, nothing is pasted.
    func uiToggleRecord() {
        pasteTarget = nil
        toggleRecord()
    }

    /// ⌥Space from any app: remember where the result should paste back when it's done.
    func hotkeyToggleRecord() {
        if phase == .recording {
            toggleRecord()
        } else if phase == .ready {
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                pasteTarget = app
            }
            toggleRecord()
        }
    }

    func toggleRecord() {
        switch phase {
        case .ready:
            do {
                try mic.start()
            } catch {
                lastError = "Microphone: \(error.localizedDescription)"
                return
            }
            lastError = ""
            partial = ""
            finalRaw = nil
            copied = false
            cards.append(Card(ts: stamp()))
            socket.send(["v": 1, "type": "control", "action": "start",
                         "sample_rate": mic.sampleRate])
            phase = .recording
            scheduleStall()
        case .recording:
            stallTask?.cancel()
            mic.stop()
            socket.send(["v": 1, "type": "control", "action": "stop"])
            phase = .finalizing
        case .starting, .finalizing:
            break
        }
    }

    func retryServer() {
        lastError = ""
        serverFailed = false
        sidecar.start()
    }

    /// Surface a non-server failure (login toggle, paste, an action) in the window's error line.
    func reportError(_ message: String) {
        lastError = message
    }

    func showLog() {
        NSWorkspace.shared.open(Config.logURL)
    }

    func copyText(_ text: String) {
        copyToPasteboard(text)
    }

    func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: Config.historyURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: $0) }
    }

    /// Saves an edited card: the history line gets the new text as its clean (the raw stays original).
    func editCard(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let ts = cards[idx].ts, raw = cards[idx].raw
        cards[idx].text = trimmed
        rewriteHistory { entries in
            for i in entries.indices where entries[i].matches(id: id, ts: ts, raw: raw) {
                entries[i].clean = trimmed
            }
        }
    }

    func deleteCard(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: idx)
        rewriteHistory { entries in
            entries.removeAll { $0.matches(id: card.id, ts: card.ts, raw: card.raw) }
        }
    }

    /// Runs a card's parsed voice command (stage 3): the chip was clicked.
    func runIntent(on id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }), let action = cards[idx].intent else { return }
        if let error = DictationAction.run(action) {
            lastError = error
        } else {
            cards[idx].intentDone = true
        }
    }

    /// Restart the no-new-text timer on every partial. When it fires: cut (freeze + clean); with
    /// autoStop on, a second stretch of silence ends the recording by the Stop path.
    private func scheduleStall() {
        stallTask?.cancel()
        guard phase == .recording else { return }
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.cutAfter ?? 4.5))
            guard let self, !Task.isCancelled, self.phase == .recording else { return }
            self.socket.send(["v": 1, "type": "control", "action": "cut"])
            guard self.autoStop else { return }
            try? await Task.sleep(for: .seconds(self.stopAfter - self.cutAfter))
            guard !Task.isCancelled, self.phase == .recording else { return }
            self.toggleRecord()  // .finalizing makes a late second fire harmless
        }
    }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            lastError = ""
            phase = .ready
        } else {
            mic.stop()
            stallTask?.cancel()
            phase = .starting
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "asr_partial":
            partial = message["text"] as? String ?? partial
            scheduleStall()
        case "clean_state":
            cleaning = message["on"] as? Bool ?? false
            if !cleaning, let raw = finalRaw {  // no clean is coming: the raw text is final
                finalRaw = nil
                if !raw.isEmpty {
                    finishCard(raw: raw, clean: nil)
                }
            }
        case "clean_all":
            // the cleaned transcript so far: replaces the active card's text, lands on the clipboard
            if let text = message["text"] as? String, !text.isEmpty {
                updateLastCard { $0.text = text }
                copyToPasteboard(text)
            }
            cleaning = false
            if message["final"] as? Bool == true {
                if let raw = finalRaw {
                    finalRaw = nil
                    finishCard(raw: raw, clean: cards.last?.text.isEmpty == false ? cards.last?.text : nil)
                } else {
                    updateLastCard { $0.isFinal = true }
                    maybePaste()
                }
            }
        case "usage":
            tokensIn = message["in"] as? Int ?? tokensIn
            tokensOut = message["out"] as? Int ?? tokensOut
        case "intent":
            // arrives after the final clean; attach to the most recent finished card
            if let action = DictationAction.from(message: message),
               let idx = cards.lastIndex(where: { $0.isFinal }) {
                cards[idx].intent = action
                cards[idx].intentDone = false
            }
        case "asr_final":
            // terminator: the clean of this text (final:true) may still arrive
            finalRaw = message["text"] as? String
            partial = ""
            stallTask?.cancel()
            mic.stop()  // the server can end a recording itself (idle timeout); a live tap would crash the next start
            phase = .ready
            if let last = cards.last, !last.isFinal, last.text.isEmpty, finalRaw?.isEmpty != false {
                cards.removeLast()  // nothing was said: no blank card, no history entry
                pasteTarget = nil  // …and nowhere to paste
            } else if let raw = finalRaw {
                updateLastCard { $0.raw = raw }
            }
        case "error":
            lastError = message["message"] as? String ?? "Unknown error"
            partial = ""
            stallTask?.cancel()
            mic.stop()
            pasteTarget = nil
            if phase == .recording || phase == .finalizing { phase = .ready }
            if let last = cards.last, !last.isFinal {
                if last.text.isEmpty { cards.removeLast() } else { updateLastCard { $0.isFinal = true } }
            }
        default:
            break
        }
    }

    /// One place where a recording resolves: paragraph the display text, save history,
    /// copy, and paste back if the recording came from the hotkey.
    private func finishCard(raw: String, clean: String?) {
        let text = paragraphs(clean ?? raw)
        updateLastCard { $0.text = text; $0.raw = raw; $0.isFinal = true }
        saveHistory(raw, clean: clean)
        copyToPasteboard(text)
        maybePaste()
    }

    /// A hotkey recording pastes itself into the app that was frontmost when ⌥Space fired.
    private func maybePaste() {
        guard let target = pasteTarget else { return }
        pasteTarget = nil
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))  // let the final clipboard write land first
            guard !Task.isCancelled else { return }
            let error = await Task.detached { HotkeyCenter.paste(into: target) }.value
            if let error { self?.lastError = error }
        }
    }

    private func updateLastCard(_ mutate: (inout Card) -> Void) {
        guard !cards.isEmpty else { return }
        mutate(&cards[cards.count - 1])
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    /// One JSONL line per resolved segment; the POSIX locale keeps the stamp ASCII whatever the system locale is.
    private func saveHistory(_ raw: String, clean: String?) {
        guard let id = cards.last?.id else { return }
        do {
            try FileManager.default.createDirectory(at: Config.historyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let line = try JSONEncoder().encode(HistoryEntry(id: id, ts: formatter.string(from: Date()),
                                                             raw: raw, clean: clean)) + Data("\n".utf8)
            if FileManager.default.fileExists(atPath: Config.historyURL.path) {
                let handle = try FileHandle(forWritingTo: Config.historyURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: Config.historyURL)
            }
        } catch {
            lastError = "Could not save history: \(error.localizedDescription)"  // the text still shows in the window
        }
    }

    /// Rewrites the whole history file (a few hundred lines at most) for an edit or delete.
    private func rewriteHistory(_ transform: (inout [HistoryEntry]) -> Void) {
        var entries = loadHistory()
        transform(&entries)
        do {
            let lines = try entries.map { try JSONEncoder().encode($0) }
            try lines.map { $0 + Data("\n".utf8) }.reduce(Data(), +)
                .write(to: Config.historyURL, options: .atomic)
        } catch {
            lastError = "Could not rewrite history: \(error.localizedDescription)"
        }
    }

    private func shutdown() {
        stallTask?.cancel()
        mic.stop()
        socket.disconnect()
        sidecar.stop()
    }
}
