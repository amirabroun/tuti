import AppKit
import Foundation

/// A voice command the server parsed off a final transcript (stage 3). The app runs it only
/// when its chip on the card is clicked — never automatically.
enum DictationAction: Equatable {
    case reminder(title: String, when: String?)
    case search(query: String)
    case open(url: String)

    /// From the server's `intent` message; nil = nothing runnable.
    static func from(message: [String: Any]) -> DictationAction? {
        switch message["action"] as? String {
        case "reminder":
            return .reminder(title: message["title"] as? String ?? "یادآور",
                             when: message["when"] as? String)
        case "search":
            return (message["query"] as? String).map { .search(query: $0) }
        case "open":
            return (message["url"] as? String).map { .open(url: $0) }
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .reminder(let title, _): "یادآور: \(title)"
        case .search(let query): "جست‌وجو: \(query)"
        case .open(let url): "باز کردن \(url)"
        }
    }

    var icon: String {
        switch self {
        case .reminder: "bell"
        case .search: "magnifyingglass"
        case .open: "safari"
        }
    }

    /// Runs the action; an error string goes to the window's error line, nil = done.
    @discardableResult
    static func run(_ action: DictationAction) -> String? {
        switch action {
        case .reminder(let title, let when):
            var properties = "name:\"\(osa(title))\""
            if let when, let date = appleScriptDate(when) { properties += ", due date:date \"\(date)\"" }
            return osa("tell application \"Reminders\" to make new reminder with properties {\(properties)}")
        case .search(let query):
            guard let url = URL(string: "https://www.google.com/search?q="
                                        + query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) else {
                return "bad search query"
            }
            NSWorkspace.shared.open(url)
            return nil
        case .open(let raw):
            let full = raw.hasPrefix("http") ? raw : "https://" + raw
            guard let url = URL(string: full) else { return "bad url: \(raw)" }
            NSWorkspace.shared.open(url)
            return nil
        }
    }

    private static func osa(_ title: String) -> String { title.replacingOccurrences(of: "\"", with: "\\\"") }

    /// Runs an AppleScript; its stderr comes back as the error message.
    private static func osa(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        return p.terminationStatus == 0
            ? nil
            : String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "osascript failed"
    }

    /// "2026-11-10T09:00" (LLM ISO, seconds optional) -> AppleScript's "2026-11-10 09:00:00".
    private static func appleScriptDate(_ iso: String) -> String? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            let inFormat = DateFormatter()
            inFormat.locale = Locale(identifier: "en_US_POSIX")
            inFormat.dateFormat = format
            guard let date = inFormat.date(from: iso) else { continue }
            let out = DateFormatter()
            out.locale = Locale(identifier: "en_US_POSIX")
            out.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return out.string(from: date)
        }
        return nil
    }
}
