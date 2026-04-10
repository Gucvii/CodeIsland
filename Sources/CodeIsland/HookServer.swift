import Foundation
import Network
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

/// Actor that holds pending socket connections for blocking permission and question requests.
/// Isolating these connections on a dedicated actor prevents the @MainActor queue from stalling
/// while waiting for user interaction, allowing concurrent requests to be processed in parallel.
actor PermissionResponder {
    struct Pending {
        let connection: NWConnection
        let event: HookEvent
    }

    private var permissions: [String: Pending] = [:]
    private var questions: [String: Pending] = [:]

    func storePermission(id: String, connection: NWConnection, event: HookEvent) {
        permissions[id] = Pending(connection: connection, event: event)
    }

    func storeQuestion(id: String, connection: NWConnection, event: HookEvent) {
        questions[id] = Pending(connection: connection, event: event)
    }

    /// Respond to a pending permission and close its connection.
    /// Returns true if the request existed and was handled.
    func respondToPermission(id: String, data: Data) -> Bool {
        guard let pending = permissions.removeValue(forKey: id) else { return false }
        sendResponse(connection: pending.connection, data: data)
        return true
    }

    /// Respond to a pending question and close its connection.
    /// Returns true if the request existed and was handled.
    func respondToQuestion(id: String, data: Data) -> Bool {
        guard let pending = questions.removeValue(forKey: id) else { return false }
        sendResponse(connection: pending.connection, data: data)
        return true
    }

    /// Cancel a specific pending permission by id.
    /// Returns true if it existed and was cancelled.
    @discardableResult
    func cancelPermission(id: String) -> Bool {
        guard let pending = permissions.removeValue(forKey: id) else { return false }
        pending.connection.cancel()
        return true
    }

    /// Cancel a specific pending question by id.
    /// Returns true if it existed and was cancelled.
    @discardableResult
    func cancelQuestion(id: String) -> Bool {
        guard let pending = questions.removeValue(forKey: id) else { return false }
        pending.connection.cancel()
        return true
    }

    /// Cancel all pending permissions and questions for a session.
    /// Returns the ids that were cancelled.
    func cancelPending(forSession sessionId: String) -> (permissionIds: [String], questionIds: [String]) {
        let permissionMatches = permissions.filter { $0.value.event.sessionId == sessionId }
        permissionMatches.keys.forEach { id in
            permissions.removeValue(forKey: id)?.connection.cancel()
        }

        let questionMatches = questions.filter { $0.value.event.sessionId == sessionId }
        questionMatches.keys.forEach { id in
            questions.removeValue(forKey: id)?.connection.cancel()
        }

        return (Array(permissionMatches.keys), Array(questionMatches.keys))
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

@MainActor
class HookServer {
    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?
    private let responder = PermissionResponder()

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Restrict socket to current user only (0o700)
                chmod(HookServer.socketPath, 0o700)
                log.info("HookServer listening on \(HookServer.socketPath)")
            case .failed(let error):
                log.error("HookServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(HookServer.socketPath)
    }

    /// Deliver a permission response to the waiting bridge connection.
    func respondToPermission(id: String, data: Data) {
        Task {
            let handled = await responder.respondToPermission(id: id, data: data)
            if !handled {
                log.warning("Permission response for id \(id) had no pending connection")
            }
        }
    }

    /// Deliver a question response to the waiting bridge connection.
    func respondToQuestion(id: String, data: Data) {
        Task {
            let handled = await responder.respondToQuestion(id: id, data: data)
            if !handled {
                log.warning("Question response for id \(id) had no pending connection")
            }
        }
    }

    /// Cancel all pending requests for a session (used when peer disconnects).
    func cancelPending(forSession sessionId: String) {
        Task {
            await responder.cancelPending(forSession: sessionId)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 1_048_576  // 1MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    private static let autoApproveTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite",
        "EnterPlanMode", "ExitPlanMode",
    ]

    private func processRequest(data: Data, connection: NWConnection) {
        guard let event = HookEvent(from: data) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        if event.eventName == "PermissionRequest" {
            let sessionId = event.sessionId ?? "default"

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            let requestId = UUID().uuidString

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                Task {
                    await responder.storeQuestion(id: requestId, connection: connection, event: event)
                }
                monitorPeerDisconnect(connection: connection, sessionId: sessionId, requestId: requestId, kind: .askUserQuestion)
                appState.handleAskUserQuestion(event, id: requestId)
                return
            }

            // Store connection on the responder actor immediately so the bridge
            // stays alive, then queue it for UI on the main actor.
            Task {
                await responder.storePermission(id: requestId, connection: connection, event: event)
            }
            monitorPeerDisconnect(connection: connection, sessionId: sessionId, requestId: requestId, kind: .permission)
            appState.handlePermissionRequest(event, id: requestId)
        } else if EventNormalizer.normalize(event.eventName) == "Notification",
                  QuestionPayload.from(event: event) != nil {
            let questionSessionId = event.sessionId ?? "default"
            let requestId = UUID().uuidString
            Task {
                await responder.storeQuestion(id: requestId, connection: connection, event: event)
            }
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId, requestId: requestId, kind: .question)
            appState.handleQuestion(event, id: requestId)
        } else {
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    private enum RequestKind {
        case permission
        case question
        case askUserQuestion
    }

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String, requestId: String, kind: RequestKind) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    let wasPending = await self.removePending(requestId: requestId, kind: kind)
                    if wasPending {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                default:
                    break
                }
            }
        }
    }

    private func removePending(requestId: String, kind: RequestKind) async -> Bool {
        switch kind {
        case .permission:
            return await responder.cancelPermission(id: requestId)
        case .question, .askUserQuestion:
            return await responder.cancelQuestion(id: requestId)
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
