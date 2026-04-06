import SwiftUI
import CoreServices
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

@MainActor
@Observable
final class AppState {
    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var permissionQueue: [PermissionRequest] = []
    var questionQueue: [QuestionRequest] = []

    /// Computed: first item in permission queue (backward compat for UI reads)
    var pendingPermission: PermissionRequest? { permissionQueue.first }
    /// Computed: first item in question queue
    var pendingQuestion: QuestionRequest? { questionQueue.first }
    var surface: IslandSurface = .collapsed

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    private var maxHistory: Int { SettingsManager.shared.maxToolHistory }
    private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    private var completionQueue: [String] = []
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false
    private var processMonitors: [String: (source: DispatchSourceProcess, pid: pid_t)] = [:]
    private var saveTimer: Timer?
    private var fsEventStream: FSEventStreamRef?
    private var lastFSScanTime: Date = .distantPast
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }
    private var modelReadAttempted: Set<String> = []

    var rotatingSessionId: String?
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }
    private var rotationTimer: Timer?

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    private func cleanupIdleSessions() {
        // 1. Kill orphaned Claude processes (terminal closed but process survived)
        // Collect first to avoid mutating sessionPids during iteration
        var orphaned: [(String, pid_t)] = []
        for (sessionId, monitor) in processMonitors {
            let pid = monitor.pid
            var info = proc_bsdinfo()
            let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if ret > 0 && info.pbi_ppid <= 1 {
                orphaned.append((sessionId, pid))
            }
        }
        for (sessionId, pid) in orphaned {
            kill(pid, SIGTERM)
            removeSession(sessionId)
        }

        // 2. Reset stuck sessions: if active but no events for 3 minutes
        //    Skip sessions with a live process monitor — the process is still running,
        //    it's just a long operation (e.g. slow build, deep thinking), not stuck.
        let stuckCutoff = Date().addingTimeInterval(-180)
        for (key, session) in sessions where session.status != .idle && session.status != .waitingApproval && session.status != .waitingQuestion && session.lastActivity < stuckCutoff {
            if processMonitors[key] != nil { continue }
            sessions[key]?.status = .idle
            sessions[key]?.currentTool = nil
            sessions[key]?.toolDescription = nil
        }

        // 3. Remove idle sessions past timeout (user setting, or 10 min default for no-monitor sessions)
        let userTimeout = SettingsManager.shared.sessionTimeout
        let defaultStaleMinutes = 10  // for sessions without process monitor
        for (key, session) in sessions where session.status == .idle {
            let idleMinutes = Int(-session.lastActivity.timeIntervalSinceNow / 60)
            let hasMonitor = processMonitors[key] != nil
            if userTimeout > 0 && idleMinutes >= userTimeout {
                // User-configured timeout applies to all sessions
                removeSession(key)
            } else if !hasMonitor && idleMinutes >= defaultStaleMinutes {
                // No process monitor (hook-only sessions): clean up after 10 min idle
                removeSession(key)
            }
        }
    }

    // MARK: - Process Monitoring (DispatchSource)

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard processMonitors[sessionId] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self, self.sessions[sessionId] != nil else { return }
                self.handleProcessExit(sessionId: sessionId, exitedPid: pid)
            }
        }
        source.resume()
        processMonitors[sessionId] = (source: source, pid: pid)

        // Safety: if process already exited before monitor started
        if kill(pid, 0) != 0 && errno == ESRCH {
            handleProcessExit(sessionId: sessionId, exitedPid: pid)
        }
    }

    /// Grace period after process exit — gives 5s for a replacement process or fresh hook event
    /// to claim the session before removal. Prevents flicker during agent restarts.
    private func handleProcessExit(sessionId: String, exitedPid: pid_t) {
        // Tear down the dead monitor immediately
        stopMonitor(sessionId)

        let exitTime = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.sessions[sessionId] != nil else { return }

            // A new monitor was attached during the grace period (new process took over)
            if self.processMonitors[sessionId] != nil { return }

            // Session received fresh activity during the grace period — still alive
            if let lastActivity = self.sessions[sessionId]?.lastActivity,
               lastActivity > exitTime { return }

            self.removeSession(sessionId)
        }
    }

    private func stopMonitor(_ sessionId: String) {
        processMonitors[sessionId]?.source.cancel()
        processMonitors.removeValue(forKey: sessionId)
    }

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible.
    private func removeSession(_ sessionId: String) {
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId)
        drainQuestions(forSession: sessionId)

        if surface.sessionId == sessionId {
            showNextPending()
        }
        sessions.removeValue(forKey: sessionId)
        stopMonitor(sessionId)
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
    }

    // MARK: - Compact bar mascot rotation

    private func startRotationIfNeeded() {
        let activeIds = sessions.filter { $0.value.status != .idle }.keys.sorted()
        if activeIds.count > 1 {
            // Fix up rotatingSessionId if nil or stale
            if rotatingSessionId == nil || !activeIds.contains(rotatingSessionId!) {
                rotatingSessionId = activeIds.first
            }
            if rotationTimer == nil {
                rotationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.rotateToNextSession()
                    }
                }
            }
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            rotatingSessionId = nil
        }
    }

    private func rotateToNextSession() {
        let activeIds = sessions.filter { $0.value.status != .idle }.keys.sorted()
        guard activeIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = activeIds.firstIndex(of: current) {
            rotatingSessionId = activeIds[(idx + 1) % activeIds.count]
        } else {
            rotatingSessionId = activeIds.first
        }
    }

    /// Try to find the Claude PID for a session and start monitoring it
    private func tryMonitorSession(_ sessionId: String) {
        guard processMonitors[sessionId] == nil,
              let cwd = sessions[sessionId]?.cwd else { return }
        Task.detached {
            let pid = Self.findPidForCwd(cwd)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                self.monitorProcess(sessionId: sessionId, pid: pid)
            }
        }
    }

    /// Find a Claude process PID by matching CWD
    private nonisolated static func findPidForCwd(_ cwd: String) -> pid_t? {
        for pid in findClaudePids() {
            if getCwd(for: pid) == cwd { return pid }
        }
        return nil
    }

    private func enqueueCompletion(_ sessionId: String) {
        // Don't queue duplicates
        if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

        if isShowingCompletion {
            // Already showing one — queue this for later
            completionQueue.append(sessionId)
        } else {
            // Show immediately
            showCompletion(sessionId)
        }
    }

    private func showCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false

        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
    }

    private func showNextCompletionOrCollapse() {
        while let next = completionQueue.first {
            completionQueue.removeFirst()
            if sessions[next] != nil {
                withAnimation(NotchAnimation.pop) {
                    showCompletion(next)
                }
                return
            }
        }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // Computed: current display state (highest priority across all sessions)
    /// Source of the highest-priority session (for compact bar character selection)
    var primarySource: String {
        var highest: AgentStatus = .idle
        var source = "claude"
        for s in sessions.values {
            switch s.status {
            case .waitingApproval: return s.source
            case .waitingQuestion: return s.source
            case .running where highest == .idle || highest == .processing:
                highest = .running; source = s.source
            case .processing where highest == .idle:
                highest = .processing; source = s.source
            default: break
            }
        }
        return source
    }

    var status: AgentStatus {
        var highest: AgentStatus = .idle
        for s in sessions.values {
            switch s.status {
            case .waitingApproval: return .waitingApproval
            case .waitingQuestion: return .waitingQuestion
            case .running where highest == .idle || highest == .processing: highest = .running
            case .processing where highest == .idle: highest = .processing
            default: break
            }
        }
        return highest
    }

    var currentTool: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.displayName
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    var activeSessionCount: Int {
        sessions.values.filter { $0.status != .idle }.count
    }

    var totalSessionCount: Int {
        sessions.count
    }

    func handleEvent(_ event: HookEvent) {
        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let sessionId = event.sessionId ?? "default"

        // Skip Codex APP internal sessions (title generation, etc.) — they have no transcript
        if (event.rawJSON["_source"] as? String) == "codex"
            && sessions[sessionId] == nil
            && event.rawJSON["transcript_path"] is NSNull {
            return
        }

        // Model transcript read (side effect, stays here)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if sessions[sessionId]?.model == nil && !modelReadAttempted.contains(sessionId) {
            modelReadAttempted.insert(sessionId)
            let cwd = sessions[sessionId]?.cwd
            let model = Self.readModelFromTranscript(sessionId: sessionId, cwd: cwd)
            sessions[sessionId]?.model = model
        }

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: maxHistory)

        // Detect Cursor YOLO mode once per session (nil = unchecked)
        if event.rawJSON["_source"] as? String == "cursor",
           sessions[sessionId]?.isYoloMode == nil {
            sessions[sessionId]?.isYoloMode = Self.detectCursorYoloMode()
        }

        for effect in effects {
            executeEffect(effect, sessionId: sessionId)
        }

        // Handle the "else if activeSessionId == sessionId → mostActive" edge case
        // (reducer can't check activeSessionId since it's AppState-local)
        if sessions[sessionId]?.status == .idle && activeSessionId == sessionId {
            let eventName = EventNormalizer.normalize(event.eventName)
            if eventName != "Stop" {
                activeSessionId = mostActiveSessionId()
            }
        }

        scheduleSave()
        startRotationIfNeeded()
    }

    private func executeEffect(_ effect: SideEffect, sessionId: String) {
        switch effect {
        case .playSound(let eventName):
            SoundManager.shared.handleEvent(eventName)
        case .tryMonitorSession(let sid):
            if processMonitors[sid] == nil {
                tryMonitorSession(sid)
            }
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .enqueueCompletion(let sid):
            enqueueCompletion(sid)
        case .setActiveSession(let sid):
            activeSessionId = sid
        }
    }

    func handlePermissionRequest(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        // Clear any pending questions for THIS session (mutually exclusive within a session)
        drainQuestions(forSession: sessionId)

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = event.toolName
        sessions[sessionId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.lastActivity = Date()

        let request = PermissionRequest(event: event, continuation: continuation)
        permissionQueue.append(request)

        // Show UI only if this is the first (or only) queued item
        if permissionQueue.count == 1 {
            activeSessionId = sessionId
            surface = .approvalCard(sessionId: sessionId)
            SoundManager.shared.handleEvent("PermissionRequest")
        }
    }

    func approvePermission(always: Bool = false) {
        guard !permissionQueue.isEmpty else { return }
        let pending = permissionQueue.removeFirst()
        let responseData: Data
        if always {
            let toolName = pending.event.toolName ?? ""
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [["toolName": toolName, "ruleContent": "*"]],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        sessions[sessionId]?.status = .running

        showNextPending()
    }

    func denyPermission() {
        guard !permissionQueue.isEmpty else { return }
        let pending = permissionQueue.removeFirst()
        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        pending.continuation.resume(returning: Data(response.utf8))
        let sessionId = pending.event.sessionId ?? "default"
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
    }

    func handleQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        guard let question = QuestionPayload.from(event: event) else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        drainPermissions(forSession: sessionId)

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()

        let request = QuestionRequest(event: event, question: question, continuation: continuation)
        questionQueue.append(request)

        if questionQueue.count == 1 {
            activeSessionId = sessionId
            surface = .questionCard(sessionId: sessionId)
            SoundManager.shared.handleEvent("PermissionRequest")
        }
    }

    func handleAskUserQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        let questionText = event.toolInput?["question"] as? String ?? "Question"
        let options = event.toolInput?["options"] as? [String]
        let payload = QuestionPayload(question: questionText, options: options)

        drainPermissions(forSession: sessionId)
        drainQuestions(forSession: sessionId)

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()

        let request = QuestionRequest(event: event, question: payload, continuation: continuation, isFromPermission: true)
        questionQueue.append(request)

        if questionQueue.count == 1 {
            activeSessionId = sessionId
            surface = .questionCard(sessionId: sessionId)
            SoundManager.shared.handleEvent("PermissionRequest")
        }
    }

    func answerQuestion(_ answer: String) {
        guard !questionQueue.isEmpty else { return }
        let pending = questionQueue.removeFirst()
        let responseData: Data
        if pending.isFromPermission {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answer
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        sessions[sessionId]?.status = .processing

        showNextPending()
    }

    func skipQuestion() {
        guard !questionQueue.isEmpty else { return }
        let pending = questionQueue.removeFirst()
        let responseData: Data
        if pending.isFromPermission {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        } else {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
        }
        pending.continuation.resume(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        sessions[sessionId]?.status = .processing

        showNextPending()
    }

    /// Drain all queued permissions for a specific session, resuming their continuations with deny
    private func drainPermissions(forSession sessionId: String) {
        let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        permissionQueue.removeAll { item in
            guard item.event.sessionId == sessionId else { return false }
            item.continuation.resume(returning: denyResponse)
            return true
        }
    }

    /// Drain all queued questions for a specific session, resuming their continuations with empty
    private func drainQuestions(forSession sessionId: String) {
        questionQueue.removeAll { item in
            guard item.event.sessionId == sessionId else { return false }
            item.continuation.resume(returning: Data("{}".utf8))
            return true
        }
    }

    /// After dequeuing, show next pending item or collapse
    private func showNextPending() {
        if let next = permissionQueue.first {
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            surface = .approvalCard(sessionId: sid)
        } else if let next = questionQueue.first {
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            surface = .questionCard(sessionId: sid)
        } else if case .approvalCard = surface {
            surface = .collapsed
        } else if case .questionCard = surface {
            surface = .collapsed
        }
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        // Prefer non-idle sessions, fall back to most recently active
        let nonIdle = sessions.filter { $0.value.status != .idle }
        let pool = nonIdle.isEmpty ? sessions : nonIdle
        return pool.max(by: { $0.value.lastActivity < $1.value.lastActivity })?.key
    }

    /// Check if Cursor is in YOLO mode by reading its settings
    private static func detectCursorYoloMode() -> Bool {
        let settingsPath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              let str = String(data: data, encoding: .utf8) else { return false }
        let stripped = ConfigInstaller.stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return false }
        if json["cursor.general.yoloMode"] as? Bool == true { return true }
        if json["cursor.agent.enableYoloMode"] as? Bool == true { return true }
        return false
    }

    /// Read model from session transcript file
    private static func readModelFromTranscript(sessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/projects/\(projectDir)/\(sessionId).jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let chunk = handle.readData(ofLength: 32768)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return nil
    }

    // MARK: - Session Discovery (FSEventStream + process scan)

    /// Start continuous monitoring: initial process scan + FSEventStream on ~/.claude/projects/
    // MARK: - Session Persistence

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveSessions()
            }
        }
    }

    func saveSessions() {
        SessionPersistence.save(sessions)
    }

    private func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted where p.lastActivity > cutoff {
            guard sessions[p.sessionId] == nil else { continue }
            var snapshot = SessionSnapshot(startTime: p.startTime)
            snapshot.cwd = p.cwd
            snapshot.source = p.source
            snapshot.model = p.model
            snapshot.lastUserPrompt = p.lastUserPrompt
            snapshot.lastAssistantMessage = p.lastAssistantMessage
            // Rebuild recentMessages from persisted data
            if let prompt = p.lastUserPrompt {
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            if let reply = p.lastAssistantMessage {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            snapshot.termApp = p.termApp
            snapshot.itermSessionId = p.itermSessionId
            snapshot.ttyPath = p.ttyPath
            snapshot.kittyWindowId = p.kittyWindowId
            snapshot.tmuxPane = p.tmuxPane
            snapshot.tmuxClientTty = p.tmuxClientTty
            snapshot.termBundleId = p.termBundleId
            snapshot.lastActivity = p.lastActivity
            sessions[p.sessionId] = snapshot
        }
        SessionPersistence.clear()
    }

    func startSessionDiscovery() {
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions (Claude + Codex)
        Task.detached {
            let claudeSessions = Self.findActiveClaudeSessions()
            let codexSessions = Self.findActiveCodexSessions()
            await MainActor.run { [weak self] in
                self?.integrateDiscovered(claudeSessions)
                self?.integrateDiscovered(codexSessions)
            }
        }
        // Start watching ~/.claude/projects/ for new session files
        startProjectsWatcher()
    }

    /// FSEventStream on ~/.claude/projects/ — fires when .jsonl files are created/modified
    private func startProjectsWatcher() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsPath = "\(home)/.claude/projects"
        guard FileManager.default.fileExists(atPath: projectsPath) else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let appState = Unmanaged<AppState>.fromOpaque(info).takeUnretainedValue()
                // Debounce: re-scan Claude processes on filesystem change
                appState.handleProjectsDirChange()
            },
            &context,
            [projectsPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // 2-second latency (coalesces rapid writes)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.fsEventStream = stream
        log.info("Projects watcher started on \(projectsPath)")
    }

    /// Called by FSEventStream when ~/.claude/projects/ changes (nonisolated for C callback compatibility)
    nonisolated private func handleProjectsDirChange() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Debounce: skip if scanned within the last 3 seconds
            guard Date().timeIntervalSince(self.lastFSScanTime) > 3 else { return }
            self.lastFSScanTime = Date()
            Task.detached {
                let claudeSessions = Self.findActiveClaudeSessions()
                let codexSessions = Self.findActiveCodexSessions()
                await MainActor.run { [weak self] in
                    self?.integrateDiscovered(claudeSessions)
                    self?.integrateDiscovered(codexSessions)
                }
            }
        }
    }

    /// Merge discovered sessions into current state (skip already-known ones)
    private func integrateDiscovered(_ discovered: [DiscoveredSession]) {
        var didAdd = false
        for info in discovered {
            // Session already known — try to attach PID monitor if missing
            if sessions[info.sessionId] != nil {
                if processMonitors[info.sessionId] == nil, let pid = info.pid {
                    monitorProcess(sessionId: info.sessionId, pid: pid)
                }
                continue
            }

            // Dedup: if a hook-created session already exists with same source + cwd,
            // skip the discovered one to avoid duplicate entries (e.g. Codex hooks vs
            // file-based discovery produce different session IDs for the same process).
            let isDuplicate = sessions.values.contains { existing in
                existing.source == info.source &&
                existing.cwd != nil && existing.cwd == info.cwd
            }
            if isDuplicate {
                // Still attach PID monitor to the existing session if possible
                if let pid = info.pid {
                    if let existingKey = sessions.first(where: {
                        $0.value.source == info.source && $0.value.cwd == info.cwd
                    })?.key, processMonitors[existingKey] == nil {
                        monitorProcess(sessionId: existingKey, pid: pid)
                    }
                }
                continue
            }

            var session = SessionSnapshot(startTime: info.modifiedAt)
            session.cwd = info.cwd
            session.model = info.model
            session.ttyPath = info.tty
            session.recentMessages = info.recentMessages
            session.source = info.source
            if let last = info.recentMessages.last(where: { $0.isUser }) {
                session.lastUserPrompt = last.text
            }
            if let last = info.recentMessages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = last.text
            }
            sessions[info.sessionId] = session
            if let pid = info.pid {
                monitorProcess(sessionId: info.sessionId, pid: pid)
            }
            didAdd = true
        }
        if didAdd && activeSessionId == nil {
            activeSessionId = sessions.keys.sorted().first
        }
    }

    func stopSessionDiscovery() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
        for key in Array(processMonitors.keys) { stopMonitor(key) }
    }

    deinit {
        MainActor.assumeIsolated {
            rotationTimer?.invalidate()
            cleanupTimer?.invalidate()
            saveTimer?.invalidate()
            if let stream = fsEventStream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            for (_, m) in processMonitors { m.source.cancel() }
        }
    }

    private struct DiscoveredSession {
        let sessionId: String
        let cwd: String
        let tty: String?
        let model: String?
        let pid: pid_t?
        let modifiedAt: Date
        let recentMessages: [ChatMessage]
        var source: String = "claude"  // "claude" or "codex"
    }

    /// Find running `claude` processes, match to transcript files, extract recent messages
    private nonisolated static func findActiveClaudeSessions() -> [DiscoveredSession] {
        // Step 1: find running claude processes using native APIs
        let claudePids = findClaudePids()
        guard !claudePids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        // Each claude process → its CWD → the single most recent .jsonl
        for pid in claudePids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty else { continue }

            // Skip subagent worktrees — they are child tasks, not independent sessions
            if cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
                continue
            }

            // Get process start time to filter stale transcript files
            let processStart = getProcessStartTime(pid)

            let projectDir = cwd.claudeProjectDirEncoded()
            let projectPath = "\(home)/.claude/projects/\(projectDir)"
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            // Find the most recently modified .jsonl that was written AFTER this process started
            var bestFile: String?
            var bestDate = Date.distantPast
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = "\(projectPath)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified > bestDate {
                    // Skip files from old sessions: must be modified after process started
                    if let start = processStart, modified < start.addingTimeInterval(-10) {
                        continue
                    }
                    bestDate = modified
                    bestFile = file
                }
            }

            guard let file = bestFile else { continue }

            // Skip stale transcripts: only show sessions active within last 5 minutes
            // This filters out orphaned processes (terminal closed but process survived)
            if bestDate.timeIntervalSinceNow < -300 { continue }

            let sessionId = String(file.dropLast(6))
            guard !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromTranscript(path: "\(projectPath)/\(file)")

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: bestDate,
                recentMessages: messages
            ))
        }
        return results
    }

    /// Get PIDs of running Claude Code processes
    /// Claude's binary is named by version (e.g. "2.1.91") under ~/.local/share/claude/versions/
    private nonisolated static func findClaudePids() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size

        let claudeVersionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path

        var claudePids: [pid_t] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuffer)
            // Match processes whose executable is under claude's versions directory
            if path.hasPrefix(claudeVersionsDir) {
                claudePids.append(pid)
            }
        }
        return claudePids
    }

    /// Get the current working directory of a process using proc_pidinfo
    private nonisolated static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Get the start time of a process using proc_pidinfo
    private nonisolated static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    // MARK: - Codex Session Discovery

    /// Find running Codex processes
    private nonisolated static func findCodexPids() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size

        var codexPids: [pid_t] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuffer)
            // Match Codex native binary (under @openai/codex)
            if path.contains("@openai/codex") && path.hasSuffix("/codex") {
                codexPids.append(pid)
            }
        }
        return codexPids
    }

    /// Find active Codex sessions by matching running processes to session files
    private nonisolated static func findActiveCodexSessions() -> [DiscoveredSession] {
        let codexPids = findCodexPids()
        guard !codexPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.codex/sessions"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in codexPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty else {
                // getCwd failed
                continue
            }
            // pid found
            let processStart = getProcessStartTime(pid)

            // Codex stores sessions in date-based dirs: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
            // Scan recent directories for matching session files
            guard let bestFile = findRecentCodexSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
                // no session file found
                continue
            }

            // Extract session ID from filename: rollout-{date}-{uuid}.jsonl
            let fileName = (bestFile as NSString).lastPathComponent
            let sessionId = extractCodexSessionId(from: fileName)
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let modifiedAt = (try? fm.attributesOfItem(atPath: bestFile))?[.modificationDate] as? Date ?? Date()

            // Skip stale transcripts (same as Claude: 5 min freshness filter)
            if modifiedAt.timeIntervalSinceNow < -300 { continue }

            let (model, messages) = readRecentFromCodexTranscript(path: bestFile)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: modifiedAt,
                recentMessages: messages,
                source: "codex"
            ))
        }
        return results
    }

    /// Find the most recent Codex session file matching a CWD
    private nonisolated static func findRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        // Build today's path: ~/.codex/sessions/YYYY/MM/DD
        let cal = Calendar.current
        let now = Date()
        let y = String(format: "%04d", cal.component(.year, from: now))
        let m = String(format: "%02d", cal.component(.month, from: now))
        let d = String(format: "%02d", cal.component(.day, from: now))

        let dirs = [
            "\(base)/\(y)/\(m)/\(d)",  // today
        ]
        // Also check yesterday in case session started before midnight
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now) {
            let yd = String(format: "%02d", cal.component(.day, from: yesterday))
            let ym = String(format: "%02d", cal.component(.month, from: yesterday))
            let yy = String(format: "%04d", cal.component(.year, from: yesterday))
            let yesterdayDir = "\(base)/\(yy)/\(ym)/\(yd)"
            // dirs is let, so rebuild
            return scanCodexDir(dirs: [dirs[0], yesterdayDir], cwd: cwd, after: after, fm: fm)
        }
        return scanCodexDir(dirs: dirs, cwd: cwd, after: after, fm: fm)
    }

    private nonisolated static func scanCodexDir(dirs: [String], cwd: String, after: Date?, fm: FileManager) -> String? {
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // Sort descending to check newest first
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for file in jsonlFiles.prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let start = after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < start.addingTimeInterval(-10) {
                    continue
                }
                if codexSessionMatchesCwd(path: fullPath, cwd: cwd) {
                    return fullPath
                }
            }
        }
        return nil
    }

    /// Check if a Codex session file's CWD matches the target
    private nonisolated static func codexSessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 4096) // First line is enough
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\n").first,
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return false }
        return sessionCwd == cwd
    }

    /// Extract session ID from Codex filename: rollout-2026-04-04T20-54-48-{uuid}.jsonl
    private nonisolated static func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        // The UUID is the last 36 chars (8-4-4-4-12)
        // Pattern: after the datetime portion, everything from the 4th dash group onwards is the UUID
        let parts = name.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}
        // That's: [rollout, YYYY, MM, DDThh, mm, ss, uuid1, uuid2, uuid3, uuid4, uuid5]
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    /// Read model and recent messages from a Codex transcript file
    private nonisolated static func readRecentFromCodexTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            // Extract model from session_meta
            if type == "session_meta", model == nil,
               let payload = json["payload"] as? [String: Any] {
                model = payload["model"] as? String
                    ?? payload["model_provider"] as? String
            }

            // Extract messages from response_item
            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let role = payload["role"] as? String {

                var textContent: String?
                if let content = payload["content"] as? [[String: Any]] {
                    for item in content {
                        let itemType = item["type"] as? String ?? ""
                        if itemType == "input_text" || itemType == "output_text",
                           let t = item["text"] as? String, !t.isEmpty {
                            textContent = t
                            break
                        }
                    }
                }

                if let text = textContent {
                    if role == "user" {
                        userMessages.append((index, text))
                    } else if role == "assistant" {
                        assistantMessages.append((index, text))
                    }
                }
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }

    /// Read model and last 3 user/assistant messages from a transcript file's tail
    private nonisolated static func readRecentFromTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        // Read last 64KB
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { continue }

            if model == nil, let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            // Extract text content
            var textContent: String?
            if let content = message["content"] as? String, !content.isEmpty {
                textContent = content
            } else if let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if item["type"] as? String == "text",
                       let t = item["text"] as? String, !t.isEmpty {
                        textContent = t
                        break
                    }
                }
            }

            if let text = textContent {
                if role == "user" {
                    userMessages.append((index, text))
                } else if role == "assistant" {
                    assistantMessages.append((index, text))
                }
            }
            index += 1
        }

        // Build recent messages: take last few user+assistant, sorted by order, keep 3
        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }
}

/// Encode a path the same way Claude Code does for project directory names:
/// "/" → "-", non-ASCII → "-", spaces → "-"
extension String {
    func claudeProjectDirEncoded() -> String {
        var result = ""
        for c in self.unicodeScalars {
            if c == "/" || c == " " || c.value > 127 {
                result.append("-")
            } else {
                result.append(Character(c))
            }
        }
        return result
    }
}
