import AppKit
import SwiftUI

/// The "copied" feedback: a soft pop plus a small capsule floating under the menu bar that
/// fades out after ~3 s. Fired once per finished recording (finishCard), never for card
/// clicks — those are the user's own action. Borderless, non-activating, click-through:
/// it can never steal focus from the app a hotkey recording is about to paste into.
enum CopyHud {
    /// How long the capsule stays fully visible before fading out — tweak to taste.
    private static let visibleFor: TimeInterval = 3
    private static let size = NSSize(width: 460, height: 60)
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(text: String, failed: Bool) {
        NSSound(named: "Pop")?.play()
        let panel = CopyHud.panel ?? makePanel()
        CopyHud.panel = panel
        panel.contentView = NSHostingView(rootView: HudBody(text: text, failed: failed))
        if let screen = NSScreen.main {  // the screen with keyboard focus, not screen 0
            panel.setFrame(NSRect(origin: NSPoint(x: screen.frame.midX - size.width / 2,
                                                  y: screen.frame.maxY - 46 - size.height),
                                  size: size), display: false)
        } else {
            panel.setContentSize(size)
        }
        hide?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        let task = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hide = task
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: task)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

private struct HudBody: View {
    let text: String
    let failed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(failed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(failed ? "LLM خطا — متن خام کپی شد" : "کپی شد")
                    .font(.system(size: 12, weight: .semibold))
                Text(text.count > 60 ? String(text.prefix(60)) + "…" : text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}
