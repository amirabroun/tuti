import Foundation

/// WebSocket link to server.py. Retries every second until the server is up (it only
/// listens once the model is loaded), so "connected" means "ready".
final class WSClient: @unchecked Sendable {
    var onConnectionChange: (@MainActor (Bool) -> Void)?
    var onMessage: (@MainActor ([String: Any]) -> Void)?

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?  // guarded by lock
    private var shouldRun = false  // guarded by lock

    func connect() {
        lock.withLock { shouldRun = true }
        open()
    }

    func disconnect() {
        let t = lock.withLock { () -> URLSessionWebSocketTask? in
            shouldRun = false
            defer { task = nil }
            return task
        }
        t?.cancel(with: .goingAway, reason: nil)
    }

    func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        current()?.send(.string(text)) { _ in }
    }

    /// Called on the audio thread.
    func sendAudio(_ data: Data) {
        current()?.send(.data(data)) { _ in }
    }

    private func current() -> URLSessionWebSocketTask? { lock.withLock { task } }

    private func open() {
        let t = URLSession.shared.webSocketTask(with: Config.serverURL)
        lock.withLock { task = t }
        t.resume()
        t.sendPing { [weak self] error in
            if error == nil { self?.notify(connected: true) } else { self?.fail(t) }
        }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.onMessage?(json) }
                }
                self.receive(t)
            case .success:
                self.receive(t)
            case .failure:
                self.fail(t)
            }
        }
    }

    /// The socket closed or never opened: report it and retry in a second.
    /// Ping and receive both fail for the same dead task; only the first one counts.
    private func fail(_ t: URLSessionWebSocketTask) {
        let retry = lock.withLock { () -> Bool in
            guard task === t else { return false }
            task = nil
            return shouldRun
        }
        guard retry else { return }
        notify(connected: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.lock.withLock({ self.shouldRun && self.task == nil }) else { return }
            self.open()
        }
    }

    private func notify(connected: Bool) {
        Task { @MainActor [weak self] in self?.onConnectionChange?(connected) }
    }
}
