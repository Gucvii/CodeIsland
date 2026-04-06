import SwiftUI
import CodeIslandCore

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var size: CGFloat = 27

    var body: some View {
        switch source {
        case "codex":
            DexView(status: status, size: size)
        case "gemini":
            GeminiView(status: status, size: size)
        case "cursor":
            CursorView(status: status, size: size)
        case "qoder":
            QoderView(status: status, size: size)
        case "droid":
            DroidView(status: status, size: size)
        case "codebuddy":
            BuddyView(status: status, size: size)
        case "opencode":
            OpenCodeView(status: status, size: size)
        default:
            ClawdView(status: status, size: size)
        }
    }
}
