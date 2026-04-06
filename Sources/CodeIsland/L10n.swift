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
        "builtin_display": "Built-in Display",
        "notch": "(Notch)",

        // Behavior
        "display_section": "Display",
        "hide_in_fullscreen": "Hide in Fullscreen",
        "hide_in_fullscreen_desc": "Automatically hide panel when any app enters fullscreen mode",
        "hide_when_no_session": "Auto-hide When No Active Session",
        "hide_when_no_session_desc": "Hide panel completely when no AI agents are running",
        "smart_suppress": "Smart Suppress",
        "smart_suppress_desc": "Don't auto-expand panel when agent's terminal tab is in foreground",
        "collapse_on_mouse_leave": "Auto-collapse on Mouse Leave",
        "collapse_on_mouse_leave_desc": "Collapse expanded panel back to notch when mouse moves away",
        "sessions": "Sessions",
        "session_cleanup": "Idle Session Cleanup",
        "session_cleanup_desc": "Automatically remove sessions with no activity for the set duration",
        "no_cleanup": "Never",
        "10_minutes": "10 Minutes",
        "30_minutes": "30 Minutes",
        "1_hour": "1 Hour",
        "2_hours": "2 Hours",
        "tool_history_limit": "Tool History Limit",
        "tool_history_limit_desc": "Max number of recent tool calls shown per session",

        // Appearance
        "preview": "Preview",
        "panel": "Panel",
        "max_visible_sessions": "Max Visible Sessions",
        "max_visible_sessions_desc": "Sessions beyond this limit will be scrollable",
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
        "system_section": "System",
        "boot_sound": "Boot Sound",
        "boot_sound_desc": "Play a jingle when CodeIsland starts",
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
        "check_for_updates": "Check for Updates...",
        "reinstall_hooks": "Reinstall Hooks",
        "remove_hooks": "Remove Hooks",
        "quit": "Quit",

        // Update
        "update_available_title": "Update Available",
        "update_available_body": "CodeIsland %@ is available (current: %@). Would you like to download it?",
        "download_update": "Download",
        "later": "Later",
        "no_update_title": "Up to Date",
        "no_update_body": "CodeIsland %@ is the latest version.",
        "ok": "OK",

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
        "scroll_for_more": "Scroll for more",
        "scroll_hidden": "more below",
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
        "builtin_display": "内建显示器",
        "notch": "(刘海)",

        // Behavior
        "display_section": "显示",
        "hide_in_fullscreen": "全屏时隐藏",
        "hide_in_fullscreen_desc": "当任意应用进入全屏模式时自动隐藏面板",
        "hide_when_no_session": "无活跃会话时自动隐藏",
        "hide_when_no_session_desc": "没有 AI Agent 运行时完全隐藏面板",
        "smart_suppress": "智能抑制",
        "smart_suppress_desc": "Agent 所在终端标签页在前台时不自动展开面板",
        "collapse_on_mouse_leave": "鼠标离开时自动收起",
        "collapse_on_mouse_leave_desc": "鼠标移出展开的面板后自动收回到刘海状态",
        "sessions": "会话",
        "session_cleanup": "空闲会话清理",
        "session_cleanup_desc": "自动移除超过指定时间没有活动的会话",
        "no_cleanup": "不清理",
        "10_minutes": "10 分钟",
        "30_minutes": "30 分钟",
        "1_hour": "1 小时",
        "2_hours": "2 小时",
        "tool_history_limit": "工具历史上限",
        "tool_history_limit_desc": "每个会话显示的最近工具调用数量上限",

        // Appearance
        "preview": "预览",
        "panel": "面板",
        "max_visible_sessions": "最大显示会话数",
        "max_visible_sessions_desc": "超出数量的会话将通过滚动查看",
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
        "system_section": "系统",
        "boot_sound": "启动音效",
        "boot_sound_desc": "CodeIsland 启动时播放提示音",
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
        "check_for_updates": "检查更新...",
        "reinstall_hooks": "重新安装 Hooks",
        "remove_hooks": "卸载 Hooks",
        "quit": "退出",

        // Update
        "update_available_title": "发现新版本",
        "update_available_body": "CodeIsland %@ 已发布（当前版本：%@），是否前往下载？",
        "download_update": "前往下载",
        "later": "稍后",
        "no_update_title": "已是最新版本",
        "no_update_body": "CodeIsland %@ 已是最新版本。",
        "ok": "好",

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
        "scroll_for_more": "向下滚动查看更多",
        "scroll_hidden": "个未显示",
        "lines": "行",
    ]
}
