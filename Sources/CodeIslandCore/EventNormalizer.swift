import Foundation

public enum EventNormalizer {
    /// Normalize event names from various CLIs to internal PascalCase names
    public static func normalize(_ name: String) -> String {
        switch name {
        // Cursor (camelCase)
        case "beforeSubmitPrompt":    return "UserPromptSubmit"
        case "beforeShellExecution":  return "PreToolUse"
        case "afterShellExecution":   return "PostToolUse"
        case "beforeReadFile":        return "PreToolUse"
        case "afterFileEdit":         return "PostToolUse"
        case "beforeMCPExecution":    return "PreToolUse"
        case "afterMCPExecution":     return "PostToolUse"
        case "afterAgentThought":     return "Notification"
        case "afterAgentResponse":    return "AfterAgentResponse"
        case "stop":                  return "Stop"
        // Gemini
        case "BeforeTool":            return "PreToolUse"
        case "AfterTool":             return "PostToolUse"
        case "BeforeAgent":           return "SubagentStart"
        case "AfterAgent":            return "SubagentStop"
        default:                      return name
        }
    }
}
