import AppKit
import Observation

/// One resolved recording in the history file: the raw ASR text and, when cleaning worked, the clean text.
/// `id` exists since 2026-11-09 (deletes find the line again); old lines match by ts+raw.
/// `fallback`/`mode` exist since 2026-11-18 (the manual retry): old lines decode them as nil.
/// `memory` exists since 2026-11-20 (the auto memory merge): old lines decode it as nil.
struct HistoryEntry: Codable {
    let id: UUID?
    let ts: String
    let raw: String
    var clean: String?
    var fallback: Bool?
    var mode: String?
    var memory: Bool?

    enum CodingKeys: String, CodingKey { case id, ts, raw, clean, fallback, mode, memory }

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
    var fallback = false  // the LLM pass returned nothing: text is raw, the retry chip shows
    var mode: String?  // the recording's LLM pass ("message" / nil = clean), resent on retry
    var memorySaved = false  // the server merged this recording into the memory file (passive chip)

    init(id: UUID = UUID(), ts: String, text: String = "", raw: String? = nil, isFinal: Bool = false,
         fallback: Bool = false, mode: String? = nil, memorySaved: Bool = false) {
        self.id = id
        self.ts = ts
        self.text = text
        self.raw = raw
        self.isFinal = isFinal
        self.fallback = fallback
        self.mode = mode
        self.memorySaved = memorySaved
    }
}

/// The «افزودن به حافظه» bar's save state: the merge outcome after a memory recording.
enum MemorySaveState { case none, saving, saved, unchanged, failed }

/// One message of the memory window's chat thread (his message or the AI's reply).
struct ChatTurn: Identifiable {
    let id = UUID()
    let isAI: Bool
    let text: String
}

/// App state: drives the server process, the socket and the mic; the window renders it.
@MainActor @Observable
final class TranscriptViewModel {
    enum Phase { case starting, ready, recording, finalizing }

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
    /// Cards with a manual re-clean in flight (the «تلاش دوباره» chip becomes a spinner).
    private(set) var retryingIds: Set<UUID> = []
    /// The server's "fallback" flag on clean_all: the LLM pass returned nothing and the text
    /// is raw — the HUD says so instead of a plain «کپی شد».
    private var cleanFailed = false
    private(set) var tokensIn = 0  // cumulative LLM tokens the server reports after each call
    private(set) var tokensOut = 0
    private(set) var llmModel = ""   // the config the server actually loaded (Settings panel);
    private(set) var llmBaseURL = "" // the key itself never leaves the server process
    private(set) var llmClean = false
    // the memory file, re-read for the panel and the menu bar (MemoryView.swift renders it)
    private(set) var memoryExists = true
    private(set) var memoryTasks: [MemoryTask] = []
    private(set) var memoryFacts: [String] = []
    // the «چینش با AI» ask: one server LLM call, answered by "memory_plan_result"
    private(set) var planPending = false
    private(set) var planText: String?
    private(set) var planFailed = false
    // The «افزودن به حافظه» bar's own recorder — deliberately separate from the main
    // cards/clipboard flow: no card is created, phase stays .ready, the bar itself shows
    // the live partial and the merge's save state.
    private(set) var memoryActive = false
    private(set) var memoryPartial = ""
    private(set) var memorySave: MemorySaveState = .none
    // The memory window's chat with the AI ("memory_chat" → "memory_chat_result").
    private(set) var chatTurns: [ChatTurn] = []
    private(set) var chatPending = false
    private(set) var chatFailed = false
    var searchQuery = ""
    var autoStop: Bool { didSet { UserDefaults.standard.set(autoStop, forKey: "autoStop") } }
    /// ON = this recording's LLM pass rewrites the transcript as one clean, flowing
    /// message (server mode "message") instead of a plain clean. Sticky like autoStop;
    /// read at Record.
    var messageMode: Bool { didSet { UserDefaults.standard.set(messageMode, forKey: "messageMode") } }

    var visibleCards: [Card] {
        guard !searchQuery.isEmpty else { return cards }
        return cards.filter {
            $0.text.localizedStandardContains(searchQuery)
                || ($0.raw ?? "").localizedStandardContains(searchQuery)
        }
    }

    /// Words heard so far — the menu bar's live "it is following me" signal.
    var wordCount: Int { partial.split(whereSeparator: \.isWhitespace).count }

    /// Same for the memory window's recorder (the menu bar shows it while it runs).
    var memoryWordCount: Int { memoryPartial.split(whereSeparator: \.isWhitespace).count }

    var statusText: String {
        switch phase {
        case .starting: return "Loading the model…"
        case .ready: return copied ? "Ready · copied" : "Ready"
        case .recording: return "Listening"
        case .finalizing: return cleaning ? "Editing…" : "Finishing…"
        }
    }

    private let sidecar = SidecarManager()
    private let socket = WSClient()
    private let mic = MicStreamer()
    private var started = false
    private var autoStopTask: Task<Void, Never>?
    private var finalRaw: String?  // asr_final's raw text, saved to history once its clean resolves
    private var hotkey: HotkeyCenter?
    private var spaceMonitor: Any?
    private var pasteTask: Task<Void, Never>?
    /// Watches the memory folder so a merge lands in the panel/menu bar without a refresh.
    private var memoryWatch: DispatchSourceFileSystemObject?
    /// The app that was frontmost when ⌥Space started the recording; the result pastes back into it.
    private var pasteTarget: NSRunningApplication?

    init() {
        let d = UserDefaults.standard
        autoStop = (d.object(forKey: "autoStop") as? Bool) ?? true
        messageMode = (d.object(forKey: "messageMode") as? Bool) ?? false
    }

    func appStart() {
        guard !started else { return }
        started = true
        cards = loadHistory().suffix(50)  // past recordings show as cards from the start
            .map { Card(id: $0.id ?? UUID(), ts: $0.ts, text: $0.clean ?? $0.raw, raw: $0.raw,
                        isFinal: true,
                        // pre-2026-11-18 lines carry no flag: clean == raw is the fallback signature
                        fallback: $0.fallback ?? ($0.clean != nil && $0.clean == $0.raw),
                        mode: $0.mode, memorySaved: $0.memory ?? false) }
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
        // Space toggles Record — claimed only when nothing else has focus: a text view
        // first responder (the search field) keeps its spaces.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      event.charactersIgnoringModifiers == " ",
                      event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty,
                      !event.isARepeat,
                      let window = NSApp.keyWindow, window.firstResponder === window,
                      self.mainWindow == nil || window === self.mainWindow else { return event }
                self.toggleRecord()
                return nil
            }
        }
        sidecar.start()
        socket.connect()
        reloadMemory()
    }

    /// Record/Stop button or Space, inside the window: the result stays a card, nothing is pasted.
    func uiToggleRecord() {
        pasteTarget = nil
        toggleRecord()
    }

    /// ⌥Space from any app: remember where the result should paste back when it's done.
    func hotkeyToggleRecord() {
        guard !memoryActive else { return }  // the memory window's recorder owns the mic
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

    /// Record/Stop for the main window's cards flow (the memory window has its own
    /// recorder below — one mic, so the two refuse to run at the same time).
    func toggleRecord() {
        switch phase {
        case .ready:
            guard !memoryActive else { return }
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
            let mode = messageMode ? "message" : nil
            cards.append(Card(ts: stamp(), mode: mode))
            var start: [String: Any] = ["v": 1, "type": "control", "action": "start",
                                        "sample_rate": mic.sampleRate]
            if let mode { start["mode"] = mode }  // absent = clean (old servers ignore it)
            socket.send(start)
            phase = .recording
            scheduleAutoStop()
        case .recording:
            autoStopTask?.cancel()
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

    func deleteCard(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: idx)
        rewriteHistory { entries in
            entries.removeAll { $0.matches(id: card.id, ts: card.ts, raw: card.raw) }
        }
    }

    /// The «افزودن به حافظه» bar: its own recorder, fully separate from the main cards
    /// flow — no card, no clipboard, no phase change; stopping merges the transcript
    /// straight into the memory file (mode "memory") and the bar shows the save state.
    func toggleMemoryRecord() {
        if memoryActive {
            autoStopTask?.cancel()
            mic.stop()
            socket.send(["v": 1, "type": "control", "action": "stop"])
            memorySave = .saving
            return
        }
        guard phase == .ready else { return }  // the main flow owns the mic
        do {
            try mic.start()
        } catch {
            lastError = "Microphone: \(error.localizedDescription)"
            return
        }
        lastError = ""
        memoryPartial = ""
        memorySave = .none
        socket.send(["v": 1, "type": "control", "action": "start",
                     "sample_rate": mic.sampleRate, "mode": "memory"])
        memoryActive = true
        scheduleAutoStop()
    }

    /// The bar's save state is transient feedback («حفظ شد» lingers ~4 s, then clears).
    private var memorySaveClearTask: Task<Void, Never>?

    private func scheduleMemorySaveClear() {
        memorySaveClearTask?.cancel()
        memorySaveClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.memorySave != .saving else { return }
            self.memorySave = .none
        }
    }

    /// The main window, for the Space monitor: a bare Space must toggle Record only when
    /// THIS window is key — the memory/settings windows would start recordings otherwise.
    @ObservationIgnored weak var mainWindow: NSWindow?

    /// Called from ContentView.onAppear; the title is the stable handle (SwiftUI sets
    /// NSWindow.title from the scene title, so keyWindow timing never matters here).
    func captureMainWindow() {
        mainWindow = NSApp.windows.first { $0.title == "Tuti" }
    }

    /// The «تلاش دوباره» chip on a fallback card: re-run the LLM pass on that recording's
    /// raw text, in the mode it was recorded in (old cards take the current toggle). The
    /// clipboard is not touched — the card click that follows copies.
    func retryClean(_ id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }),
              let raw = cards[idx].raw, !raw.isEmpty, !retryingIds.contains(id) else { return }
        retryingIds.insert(id)
        socket.send(["v": 1, "type": "retry", "id": id.uuidString, "text": raw,
                     "mode": cards[idx].mode ?? (messageMode ? "message" : "clean")])
    }

    /// The «چینش با AI» ask: one LLM call on the server with the whole memory file; the
    /// reply replaces any previous plan text. The question is optional ("" = the prompt's
    /// default order: simple first, soonest deadline first).
    func askPlan(_ question: String) {
        guard !planPending else { return }
        planPending = true
        planFailed = false
        planText = nil
        socket.send(["v": 1, "type": "memory_plan", "text": question])
    }

    /// One message to the memory window's AI chat: the recent thread rides along (last 8
    /// turns) so a follow-up like «اسمش رو عوض کن» has its context. One server LLM call;
    /// the model may rewrite the memory file (the answer carries "changed").
    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatPending, phase == .ready, !memoryActive else { return }
        chatTurns.append(ChatTurn(isAI: false, text: trimmed))
        chatPending = true
        chatFailed = false
        let turns = chatTurns.dropLast().suffix(8).map { ["who": $0.isAI ? "ai" : "me", "text": $0.text] }
        socket.send(["v": 1, "type": "memory_chat", "text": trimmed, "turns": turns])
    }

    /// Clears the session's chat thread (the server's memory_log.jsonl keeps everything).
    func clearChat() {
        guard !chatPending else { return }
        chatTurns = []
        chatFailed = false
    }

    /// Open tasks, soonest date first (undated last) — the menu bar's next-3 list.
    var openMemoryTasks: [MemoryTask] {
        memoryTasks.filter { !$0.done }.sorted { ($0.date ?? "9999-99-99") < ($1.date ?? "9999-99-99") }
    }

    /// Re-reads the memory file for the panel and menu bar; also starts the directory
    /// watcher the first time — the merge writes via os.replace (a new inode), so only
    /// watching the folder catches every save.
    func reloadMemory() {
        if memoryWatch == nil { watchMemoryFile() }
        memoryExists = FileManager.default.fileExists(atPath: Config.memoryURL.path)
        let f = MemoryFile.load()
        memoryTasks = f.tasks
        memoryFacts = f.facts
    }

    private func watchMemoryFile() {
        let dir = Config.memoryURL.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }  // no folder yet: the first save creates it, retry then
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.reloadMemory() }
        src.setCancelHandler { close(fd) }
        src.resume()
        memoryWatch = src
    }

    /// Runs a card's parsed voice command (stage 3): the chip was clicked. The osascript can
    /// take seconds (Reminders may be launching), so it never blocks the UI thread; the chip
    /// disappears immediately and returns only when the action failed.
    func runIntent(on id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }), let action = cards[idx].intent,
              !cards[idx].intentDone else { return }
        cards[idx].intentDone = true  // also guards a double-click from firing the action twice
        Task { [weak self] in
            let error = await Task.detached { DictationAction.run(action) }.value
            guard let self, let error else { return }
            if let i = self.cards.firstIndex(where: { $0.id == id }) { self.cards[i].intentDone = false }
            self.lastError = error
        }
    }

    /// Restart the no-new-text timer on every partial (either recorder). When it fires
    /// (autoStop on): the active recording ends by the Stop path — the one clean/merge
    /// happens after stop, not here.
    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        guard phase == .recording || memoryActive, autoStop else { return }
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.stopAfter ?? 4))
            guard let self, !Task.isCancelled else { return }
            if self.memoryActive { self.toggleMemoryRecord() } else { self.toggleRecord() }
        }
    }

    private func connectionChanged(_ connected: Bool) {
        if connected {
            lastError = ""
            phase = .ready
        } else {
            mic.stop()
            autoStopTask?.cancel()
            planFailed = planPending  // an in-flight ask can no longer be answered
            planPending = false
            chatFailed = chatPending
            chatPending = false
            memoryActive = false  // a merge in flight can no longer report back
            memoryPartial = ""
            memorySave = .none
            phase = .starting
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "asr_partial":
            if memoryActive {
                memoryPartial = message["text"] as? String ?? memoryPartial
                scheduleAutoStop()
                return
            }
            partial = message["text"] as? String ?? partial
            scheduleAutoStop()
        case "clean_state":
            cleaning = message["on"] as? Bool ?? false
            if !cleaning, let raw = finalRaw {  // no clean is coming: the raw text is final
                finalRaw = nil
                if dropDeletedRecording() { return }
                phase = .ready
                if !raw.isEmpty {
                    finishCard(raw: raw, clean: nil)
                }
            }
        case "clean_all":
            // the cleaned whole transcript, once, after stop
            cleaning = false
            cleanFailed = message["fallback"] as? Bool ?? false
            if dropDeletedRecording() { return }
            if let text = message["text"] as? String, !text.isEmpty {
                updateLastCard { $0.text = text; $0.fallback = cleanFailed }
            }
            if let raw = finalRaw {
                finalRaw = nil
                finishCard(raw: raw, clean: cards.last?.text.isEmpty == false ? cards.last?.text : nil)
            } else {
                updateLastCard { $0.isFinal = true }
                maybePaste()
            }
            phase = .ready
        case "cleaned":
            // a manual retry resolved: swap that card's text (anywhere in the list) and its
            // history line. Still failed = the flag stays, the chip offers another try.
            guard let id = (message["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let text = message["text"] as? String else { return }
            retryingIds.remove(id)
            let failedAgain = message["fallback"] as? Bool ?? false
            guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
            cards[idx].fallback = failedAgain
            if !failedAgain, !text.isEmpty {
                cards[idx].text = paragraphs(text)
            }
            updateHistory(cards[idx]) { entry in
                entry.fallback = failedAgain
                if !failedAgain, !text.isEmpty { entry.clean = text }
                if entry.mode == nil { entry.mode = cards[idx].mode }
            }
        case "usage":
            tokensIn = message["in"] as? Int ?? tokensIn
            tokensOut = message["out"] as? Int ?? tokensOut
        case "config":
            llmModel = message["model"] as? String ?? llmModel
            llmBaseURL = message["base_url"] as? String ?? llmBaseURL
            llmClean = message["clean"] as? Bool ?? llmClean
        case "intent":
            // arrives after the final clean; attach to the most recent finished card
            if let action = DictationAction.from(message: message),
               let idx = cards.lastIndex(where: { $0.isFinal }) {
                cards[idx].intent = action
                cards[idx].intentDone = false
            }
        case "memory_saved":
            // the merge outcome for the «افزودن به حافظه» bar (no card anymore; old
            // history lines still show the card chip via loadHistory). unchanged = the
            // model judged the file already covers the speech; failed = nothing landed.
            if message["failed"] as? Bool == true {
                memorySave = .failed
            } else if message["unchanged"] as? Bool == true {
                memorySave = .unchanged
            } else {
                memorySave = .saved
                reloadMemory()  // the panel and menu bar show the new content right away
            }
            scheduleMemorySaveClear()
        case "memory_plan_result":
            // the «چینش با AI» answer for the memory panel
            planPending = false
            if let text = message["text"] as? String, !(message["failed"] as? Bool ?? false) {
                planText = text
            } else {
                planFailed = true
            }
        case "memory_chat_result":
            // the memory chat's reply; changed = the memory file was rewritten on disk
            chatPending = false
            if let text = message["text"] as? String, !(message["failed"] as? Bool ?? false),
               !text.isEmpty {
                chatTurns.append(ChatTurn(isAI: true, text: text))
                if message["changed"] as? Bool == true { reloadMemory() }
            } else {
                chatFailed = true
            }
        case "asr_final":
            if memoryActive {
                // the memory recorder's terminator: the merge follows, the bar shows
                // «در حال ذخیره…»; no card, no history, main phase untouched
                memoryActive = false
                memoryPartial = ""
                autoStopTask?.cancel()
                mic.stop()  // the server can end a recording itself (idle timeout)
                memorySave = (message["text"] as? String ?? "").isEmpty ? .none : .saving
                return
            }
            // terminator: the one clean (clean_all, or clean_state off) may still arrive
            finalRaw = message["text"] as? String
            partial = ""
            autoStopTask?.cancel()
            mic.stop()  // the server can end a recording itself (idle timeout); a live tap would crash the next start
            if dropDeletedRecording() { return }
            if let last = cards.last, !last.isFinal, last.text.isEmpty, finalRaw?.isEmpty != false {
                cards.removeLast()  // nothing was said: no blank card, no history entry
                pasteTarget = nil  // …and nowhere to paste
                phase = .ready
            } else if let raw = finalRaw {
                updateLastCard { $0.raw = raw }  // stays .finalizing until the clean resolves
            }
        case "error":
            lastError = message["message"] as? String ?? "Unknown error"
            partial = ""
            autoStopTask?.cancel()
            mic.stop()
            pasteTarget = nil
            if memoryActive {
                memoryActive = false
                memoryPartial = ""
                memorySave = .failed
                return
            }
            if phase == .recording || phase == .finalizing { phase = .ready }
            if let last = cards.last, !last.isFinal {
                if last.text.isEmpty { cards.removeLast() } else { updateLastCard { $0.isFinal = true } }
            }
        default:
            break
        }
    }

    /// A recording whose card was deleted mid-flight is dropped whole: finishing it would
    /// write onto the previous card (updateLastCard/saveHistory always target cards.last).
    /// True = dropped, caller returns; the recording never reaches history or the clipboard.
    private func dropDeletedRecording() -> Bool {
        guard let last = cards.last, !last.isFinal else {
            finalRaw = nil
            pasteTarget = nil
            phase = .ready
            return true
        }
        return false
    }

    /// One place where a main-flow recording resolves: paragraph the display text, save
    /// history, copy, and paste back if the recording came from the hotkey. Memory
    /// recordings never reach here — their product is the memory file, not a card.
    private func finishCard(raw: String, clean: String?) {
        let text = paragraphs(clean ?? raw)
        updateLastCard { $0.text = text; $0.raw = raw; $0.isFinal = true }
        saveHistory(raw, clean: clean)
        copyToPasteboard(text)
        CopyHud.show(text: text, failed: cleanFailed)
        cleanFailed = false
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
        guard let card = cards.last else { return }
        do {
            try FileManager.default.createDirectory(at: Config.historyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let line = try JSONEncoder().encode(HistoryEntry(id: card.id, ts: formatter.string(from: Date()),
                                                             raw: raw, clean: clean,
                                                             fallback: card.fallback ? true : nil,
                                                             mode: card.mode,
                                                             memory: card.memorySaved ? true : nil)) + Data("\n".utf8)
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

    /// Updates one card's history line in place (a retry resolving). Id matches where there
    /// is one; the oldest pre-id lines fall back to ts+raw, same rule as deletes.
    private func updateHistory(_ card: Card, _ mutate: (inout HistoryEntry) -> Void) {
        rewriteHistory { entries in
            if let i = entries.firstIndex(where: { $0.matches(id: card.id, ts: card.ts, raw: card.raw) }) {
                mutate(&entries[i])
            }
        }
    }

    private func shutdown() {
        autoStopTask?.cancel()
        memorySaveClearTask?.cancel()
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        memoryWatch?.cancel()
        mic.stop()
        socket.disconnect()
        sidecar.stop()
    }
}
