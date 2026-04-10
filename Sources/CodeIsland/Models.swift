import Foundation
import CodeIslandCore

struct PermissionRequest {
    let id: String
    let event: HookEvent
}

struct QuestionRequest {
    let id: String
    let event: HookEvent
    let question: QuestionPayload
    /// true when converted from AskUserQuestion PermissionRequest
    let isFromPermission: Bool

    init(id: String, event: HookEvent, question: QuestionPayload, isFromPermission: Bool = false) {
        self.id = id
        self.event = event
        self.question = question
        self.isFromPermission = isFromPermission
    }
}
