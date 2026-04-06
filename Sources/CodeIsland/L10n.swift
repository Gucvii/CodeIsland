import Foundation
import Combine

final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: SettingsKey.appLanguage) }
    }

    init() {
        self.language = UserDefaults.standard.string(forKey: SettingsKey.appLanguage) ?? "system"
    }

    var effectiveLanguage: String {
        if language == "system" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh" : "en"
        }
        return language
    }

    subscript(_ key: String) -> String {
        Self.strings[effectiveLanguage]?[key] ?? Self.strings["en"]?[key] ?? key
    }

    // MARK: - Translations

    private static let strings: [String: [String: String]] = [
        "en": en,
        "zh": zh,
    ]

    private static let en: [String: String] = [
        // Settings pages
        "general": "General",
        "behavior": "Behavior",
        "appearance": "Appearance",
        "mascots": "Mascots",
        "sound": "Sound",
        "hooks": "Hooks",
        "about": "About",

        // Language
        "language": "Language",
        "system_language": "System",

        // General
        "launch_at_login": "Launch at Login",
        "display": "Display",
        "auto": "Auto",
        "notch": "(Notch)",

        // Behavior
        "display_section": "Display",
        "hide_in_fullscreen": "Hide in Fullscreen",
        "hide_when_no_session": "Auto-hide When No Active Session",
        "smart_suppress": "Smart Suppress",
        "smart_suppress_desc": "Don't auto-expand panel when agent's terminal tab is in foreground",
        "collapse_on_mouse_leave": "Auto-collapse on Mouse Leave",
        "sessions": "Sessions",
        "session_cleanup": "Idle Session Cleanup",
        "no_cleanup": "Never",
        "10_minutes": "10 Minutes",
        "30_minutes": "30 Minutes",
        "1_hour": "1 Hour",
        "2_hours": "2 Hours",
        "tool_history_limit": "Tool History Limit",

        // Appearance
        "panel": "Panel",
        "max_panel_height": "Max Panel Height",
        "default": "Default",
        "content": "Content",
        "content_font_size": "Content Font Size",
        "11pt_default": "11pt (Default)",
        "ai_reply_lines": "AI Reply Lines",
        "1_line_default": "1 Line (Default)",
        "2_lines": "2 Lines",
        "3_lines": "3 Lines",
        "5_lines": "5 Lines",
        "unlimited": "Unlimited",
        "show_agent_details": "Show Agent Activity Details",

        // Mascots
        "preview_status": "Preview Status",
        "processing": "Processing",
        "idle": "Idle",
        "waiting_approval": "Waiting Approval",

        // Sound
        "enable_sound": "Enable Sound Effects",
        "volume": "Volume",
        "session_start": "Session Start",
        "new_claude_session": "New Claude Code session",
        "task_complete": "Task Complete",
        "ai_completed_reply": "AI completed this round's reply",
        "task_error": "Task Error",
        "tool_or_api_error": "Tool failure or API error",
        "interaction": "Interaction",
        "approval_needed": "Approval Needed",
        "waiting_approval_desc": "Waiting for permission approval or answer",
        "task_confirmation": "Task Confirmation",
        "you_sent_message": "You sent a message",

        // Hooks
        "cli_status": "CLI Status",
        "activated": "Activated",
        "not_installed": "Not Installed",
        "not_detected": "Not Detected",
        "management": "Management",
        "reinstall": "Reinstall",
        "uninstall": "Uninstall",
        "hooks_installed": "Hooks installed successfully",
        "install_failed": "Installation failed",
        "hooks_uninstalled": "Hooks uninstalled",

        // About
        "about_desc1": "Real-time AI coding agent status panel for macOS",
        "about_desc2": "Supports 8 CLI/IDE tools via Unix socket IPC",

        // Window
        "settings_title": "CodeIsland Settings",

        // Menu
        "settings_ellipsis": "Settings...",
        "reinstall_hooks": "Reinstall Hooks",
        "remove_hooks": "Remove Hooks",
        "quit": "Quit",

        // NotchPanel
        "mute": "Mute",
        "enable_sound_tooltip": "Enable Sound",
        "settings": "Settings",
        "deny": "DENY",
        "allow_once": "ALLOW ONCE",
        "always": "ALWAYS",
        "type_answer": "Type your answer...",
        "skip": "SKIP",
        "submit": "SUBMIT",
        "open_path": "Open",

        // Session grouping
        "status_running": "Running",
        "status_waiting": "Waiting",
        "status_processing": "Processing",
        "status_idle": "Idle",
        "other": "Other",
        "n_sessions": "sessions",
        "lines": "lines",
    ]

    private static let zh: [String: String] = [
        // Settings pages
        "general": "通用",
        "behavior": "行为",
        "appearance": "外观",
        "mascots": "角色",
        "sound": "声音",
        "hooks": "Hooks",
        "about": "关于",

        // Language
        "language": "语言",
        "system_language": "跟随系统",

        // General
        "launch_at_login": "登录时打开",
        "display": "显示器",
        "auto": "自动",
        "notch": "(刘海)",

        // Behavior
        "display_section": "显示",
        "hide_in_fullscreen": "全屏时隐藏",
        "hide_when_no_session": "无活跃会话时自动隐藏",
        "smart_suppress": "智能抑制",
        "smart_suppress_desc": "Agent 所在终端标签页在前台时不自动展开面板",
        "collapse_on_mouse_leave": "鼠标离开时自动收起",
        "sessions": "会话",
        "session_cleanup": "空闲会话清理",
        "no_cleanup": "不清理",
        "10_minutes": "10 分钟",
        "30_minutes": "30 分钟",
        "1_hour": "1 小时",
        "2_hours": "2 小时",
        "tool_history_limit": "工具历史上限",

        // Appearance
        "panel": "面板",
        "max_panel_height": "最大面板高度",
        "default": "默认",
        "content": "内容",
        "content_font_size": "内容字体大小",
        "11pt_default": "11pt (默认)",
        "ai_reply_lines": "AI 回复行数",
        "1_line_default": "1 行 (默认)",
        "2_lines": "2 行",
        "3_lines": "3 行",
        "5_lines": "5 行",
        "unlimited": "不限制",
        "show_agent_details": "显示代理活动详情",

        // Mascots
        "preview_status": "预览状态",
        "processing": "工作中",
        "idle": "空闲",
        "waiting_approval": "等待审批",

        // Sound
        "enable_sound": "启用音效",
        "volume": "音量",
        "session_start": "会话开始",
        "new_claude_session": "新的 Claude Code 会话",
        "task_complete": "任务完成",
        "ai_completed_reply": "AI 完成了本轮回复",
        "task_error": "任务错误",
        "tool_or_api_error": "工具失败或 API 错误",
        "interaction": "交互",
        "approval_needed": "需要审批",
        "waiting_approval_desc": "等待权限审批或回答问题",
        "task_confirmation": "任务确认",
        "you_sent_message": "你发送了一条消息",

        // Hooks
        "cli_status": "CLI 状态",
        "activated": "已激活",
        "not_installed": "未安装",
        "not_detected": "未检测到",
        "management": "管理",
        "reinstall": "重新安装",
        "uninstall": "卸载",
        "hooks_installed": "Hooks 安装成功",
        "install_failed": "安装失败",
        "hooks_uninstalled": "Hooks 已卸载",

        // About
        "about_desc1": "macOS 实时 AI 编码 Agent 状态面板",
        "about_desc2": "通过 Unix socket IPC 支持 8 种 CLI/IDE 工具",

        // Window
        "settings_title": "CodeIsland 设置",

        // Menu
        "settings_ellipsis": "设置...",
        "reinstall_hooks": "重新安装 Hooks",
        "remove_hooks": "卸载 Hooks",
        "quit": "退出",

        // NotchPanel
        "mute": "静音",
        "enable_sound_tooltip": "开启音效",
        "settings": "设置",
        "deny": "拒绝",
        "allow_once": "允许一次",
        "always": "始终允许",
        "type_answer": "输入回答…",
        "skip": "跳过",
        "submit": "提交",
        "open_path": "打开",

        // Session grouping
        "status_running": "运行中",
        "status_waiting": "等待中",
        "status_processing": "处理中",
        "status_idle": "空闲",
        "other": "其他",
        "n_sessions": "个会话",
        "lines": "行",
    ]
}
