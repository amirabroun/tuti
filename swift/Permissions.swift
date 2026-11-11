import AVFoundation
import ApplicationServices
import SwiftUI

/// The three macOS permissions tuti lives on. All asked together on the first launch instead
/// of each at first use; the panel reopens from the menu bar to repair a deny.
@Observable
final class PermissionsModel {
    private static let askedKey = "permissionsAsked"      // the first-launch asks fire once
    private static let remindersKey = "remindersGranted"  // automation TCC has no read API

    private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    private(set) var axTrusted = false
    private(set) var remindersGranted: Bool
    private(set) var probing = false

    var micGranted: Bool { micStatus == .authorized }

    init() {
        remindersGranted = UserDefaults.standard.bool(forKey: Self.remindersKey)
        refresh()
    }

    /// First launch: fire every ask once (mic prompt + Reminders probe). True = open the panel —
    /// its Accessibility row is the guide for the one thing macOS only grants manually.
    func firstLaunchCheck() -> Bool {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.askedKey) else { return false }
        d.set(true, forKey: Self.askedKey)
        askMic()
        probeReminders()
        return true
    }

    func askMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in self?.refresh() }
    }

    /// Triggers the Reminders automation prompt by reading the app's name — macOS has no
    /// pre-prompt API, sending an event is the only ask. Woke Reminders just for this → quit it.
    func probeReminders() {
        guard !probing else { return }
        probing = true
        let wokeIt = !Self.remindersRunning()  // captured before the probe blocks on the prompt
        Task.detached {
            let failed = DictationAction.osa("tell application \"Reminders\" to get name")
            if wokeIt, await MainActor.run(body: { Self.remindersRunning() }) {
                _ = DictationAction.osa("tell application \"Reminders\" to quit")
            }
            let granted = failed == nil
            await MainActor.run {
                self.remindersGranted = granted
                UserDefaults.standard.set(granted, forKey: Self.remindersKey)
                self.probing = false
            }
        }
    }

    func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        axTrusted = AXIsProcessTrusted()
    }

    /// Opens a Privacy & Security pane (Privacy_Microphone / Privacy_Accessibility /
    /// Privacy_Automation) — the repair path for anything macOS will not re-ask by itself.
    static func openSettings(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url { NSWorkspace.shared.open(url) }
    }

    private static func remindersRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.reminders" }
    }
}

/// The settings panel: the three permission cards on top, the LLM config the server actually
/// loaded below (model + URL — the key never leaves the server process). Cards match the
/// main window's dictation-card look: quaternary fill, 10-pt radius, icon + title + status.
struct PermissionsView: View {
    let model: TranscriptViewModel
    @Environment(PermissionsModel.self) private var perms

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("تنظیمات tuti").font(.title3.bold()).padding(.bottom, 2)

                sectionLabel("دسترسی‌ها")
                permCard(icon: "mic.fill", name: "میکروفون", why: "ضبط گفتار", ok: perms.micGranted) {
                    switch perms.micStatus {
                    case .authorized: grantedBadge
                    case .notDetermined: Button("اجازه بده") { perms.askMic() }.controlSize(.small)
                    default: paneButton("Privacy_Microphone")  // denied: only Settings undoes it
                    }
                }
                permCard(icon: "hand.raised.fill", name: "دسترسی‌پذیری", why: "paste با ⌥Space در بقیهٔ اپ‌ها",
                         ok: perms.axTrusted) {
                    if perms.axTrusted { grantedBadge } else { paneButton("Privacy_Accessibility") }
                }
                permCard(icon: "bell.fill", name: "یادآورها", why: "فرمان‌های صوتی", ok: perms.remindersGranted) {
                    if perms.remindersGranted {
                        grantedBadge
                    } else {
                        HStack(spacing: 8) {
                            Button(perms.probing ? "…" : "دوباره بپرس") { perms.probeReminders() }
                                .controlSize(.small)
                                .disabled(perms.probing)
                            paneButton("Privacy_Automation")
                        }
                    }
                }
                Text("دسترسی‌پذیری فقط با تیک دستی در تنظیمات سیستم داده می‌شود؛ بعد از تیک، همین پنجره سبز می‌شود.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                sectionLabel("ویرایش متن (LLM)")
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            statusIcon("wand.and.stars", ok: model.llmClean, offColor: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ویرایشگر متن").font(.body.weight(.medium))
                                Text("یک تمیزکاری LLM پس از پایان ضبط").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.llmClean ? "روشن" : "خاموش")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(model.llmClean ? Color.green : Color.orange)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill((model.llmClean ? Color.green : Color.orange).opacity(0.12)))
                        }
                        Divider()
                        infoRow("مدل", model.llmModel.isEmpty ? "در انتظار سرور…" : model.llmModel)
                        infoRow("سرور", model.llmBaseURL.isEmpty ? "—" : model.llmBaseURL)
                        if !model.llmClean {
                            Text("خاموش: متن خامِ گفتار ضبط و paste می‌شود.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 360)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { perms.refresh() }
        .task {  // the Accessibility tick lands in System Settings: catch it while we are open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                perms.refresh()
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    /// One permission row as a card: colored icon chip, name + purpose, trailing state control.
    private func permCard<Trailing: View>(icon: String, name: String, why: String, ok: Bool,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        card {
            HStack(spacing: 10) {
                statusIcon(icon, ok: ok, offColor: .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium))
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailing()
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    /// The row icon inside a tinted circle — color + the trailing badge, never color alone.
    private func statusIcon(_ systemName: String, ok: Bool, offColor: Color) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ok ? Color.green : offColor)
            .frame(width: 28, height: 28)
            .background(Circle().fill((ok ? Color.green : offColor).opacity(0.12)))
    }

    private var grantedBadge: some View {
        Label("داده شد", systemImage: "checkmark.circle.fill")
            .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
    }

    private func paneButton(_ pane: String) -> some View {
        Button("تنظیمات") { PermissionsModel.openSettings(pane) }
            .controlSize(.small)
    }

    /// A label-value line for the LLM config; the value is selectable so a long URL can be copied.
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }
}
