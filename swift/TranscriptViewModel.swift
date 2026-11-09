import AppKit
import Observation

/// One resolved recording in the history file: the raw ASR text and, when cleaning worked, the clean text.
struct HistoryEntry: Codable, Identifiable {
    let id = UUID()
    let ts: String
    let raw: String
    let clean: String?

    enum CodingKeys: String, CodingKey { case ts, raw, clean }  // id is display-only, not persisted
}

/// One dictation card in the main list: the cleaned text of one recording, kept until quit.
struct Card: Identifiable {
    let id = UUID()
    let ts: String
    var text = ""
    var isFinal = false
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
    var spoken: Bool { didSet { UserDefaults.standard.set(spoken, forKey: "spoken") } }
    var autoStop: Bool { didSet { UserDefaults.standard.set(autoStop, forKey: "autoStop") } }

    private let sidecar = SidecarManager()
    private let socket = WSClient()
    private let mic = MicStreamer()
    private var started = false
    private var stallTask: Task<Void, Never>?
    private var finalRaw: String?  // asr_final's raw text, saved to history once its clean resolves

    init() {
        let d = UserDefaults.standard
        spoken = (d.object(forKey: "spoken") as? Bool) ?? true
        autoStop = (d.object(forKey: "autoStop") as? Bool) ?? true
    }

    func appStart() {
        guard !started else { return }
        started = true
        cards = loadHistory().suffix(50)  // past recordings show as cards from the start
            .map { Card(ts: $0.ts, text: $0.clean ?? $0.raw, isFinal: true) }
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
        sidecar.start()
        socket.connect()
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
                         "sample_rate": mic.sampleRate, "style": spoken ? "spoken" : "formal"])
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

    /// Re-clean the whole raw transcript in one request, replacing the last card's text.
    func reclean() {
        socket.send(["v": 1, "type": "control", "action": "reclean"])
    }

    func retryServer() {
        lastError = ""
        serverFailed = false
        sidecar.start()
    }

    func showLog() {
        NSWorkspace.shared.open(Config.logURL)
    }

    func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: Config.historyURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: $0) }
    }

    func clearHistory() {
        try? Data().write(to: Config.historyURL)  // empty file; the panel reloads nothing
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
                if !raw.isEmpty {
                    saveHistory(raw, clean: nil)
                    updateLastCard { if $0.text.isEmpty { $0.text = raw }; $0.isFinal = true }
                }
                finalRaw = nil
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
                    saveHistory(raw, clean: cards.last?.text.isEmpty == false ? cards.last?.text : nil)
                    finalRaw = nil
                }
                updateLastCard { $0.isFinal = true }
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
            }
        case "error":
            lastError = message["message"] as? String ?? "Unknown error"
            partial = ""
            stallTask?.cancel()
            mic.stop()
            if phase == .recording || phase == .finalizing { phase = .ready }
            if let last = cards.last, !last.isFinal {
                if last.text.isEmpty { cards.removeLast() } else { updateLastCard { $0.isFinal = true } }
            }
        default:
            break
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
        do {
            try FileManager.default.createDirectory(at: Config.historyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let line = try JSONEncoder().encode(HistoryEntry(ts: formatter.string(from: Date()),
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

    private func shutdown() {
        stallTask?.cancel()
        mic.stop()
        socket.disconnect()
        sidecar.stop()
    }
}
