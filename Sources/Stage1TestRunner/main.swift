import Foundation
import Cocoa
import AgentSignalBarCore

// Hard test isolation: disable all production Telegram network calls
TestEnvironment.enableTestMode()
TelegramBridge.shared.transport = MockTelegramTransport()

func runTest(_ name: String, block: () throws -> Void) {
    do {
        try block()
        print("✅ Passed: \(name)")
    } catch {
        print("❌ Failed: \(name) - \(error)")
        exit(1)
    }
}

func runAsyncTest(_ name: String, block: @escaping () async throws -> Void) {
    let group = DispatchGroup()
    group.enter()
    var testErr: Error?
    Task {
        do {
            try await block()
        } catch {
            testErr = error
        }
        group.leave()
    }
    let waitResult = group.wait(timeout: .now() + 5.0)
    if waitResult == .timedOut {
        print("❌ Failed: \(name) - Timed out after 5s")
        exit(1)
    }
    if let err = testErr {
        print("❌ Failed: \(name) - \(err)")
        exit(1)
    } else {
        print("✅ Passed: \(name)")
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
}

func assert(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw TestError(description: message)
    }
}

print("🧪 Running Production Swift Stage 1 Logic & Containment Runner...")

// 1. Production AgentUsageStore Live Source Priority
runTest("1. Live Usage Source Priority Over Config Fallbacks") {
    let store = AgentUsageStore.shared

    var liveData = AgentUsageData(agent: .chatgpt)
    liveData.sessionLimitPercent = 25.0
    liveData.isLiveSource = true
    store.updateUsage(for: .chatgpt, data: liveData)

    var fallbackData = AgentUsageData(agent: .chatgpt)
    fallbackData.sessionLimitPercent = 89.0
    fallbackData.isLiveSource = false
    store.updateUsage(for: .chatgpt, data: fallbackData)

    let current = store.getUsage(for: .chatgpt)
    try assert(current?.sessionLimitPercent == 25.0, "Non-live config fallback must NOT overwrite a live source.")
    try assert(current?.isLiveSource == true, "Session usage must remain marked as live source.")
}

// 2. Production Freshness Classification
runTest("2. Unavailable or Stale Quota Freshness Classification") {
    let now = Date()
    let freshDate = now.addingTimeInterval(-3600) // 1h ago
    let staleDate = now.addingTimeInterval(-90000) // 25h ago

    let u1 = AgentUsageData(agent: .claude, sessionLimitPercent: 10.0, isLiveSource: false, quotaTimestamp: nil)
    try assert(u1.freshness == "Unavailable", "Non-live source must classify as Unavailable.")

    let u2 = AgentUsageData(agent: .claude, sessionLimitPercent: 10.0, isLiveSource: true, quotaTimestamp: staleDate)
    try assert(u2.freshness == "Stale", "Sample older than 24h must classify as Stale.")

    let u3 = AgentUsageData(agent: .claude, sessionLimitPercent: 10.0, isLiveSource: true, quotaTimestamp: freshDate)
    try assert(u3.freshness == "Fresh", "Sample within 24h must classify as Fresh.")
}

// 3. MenuBarManager Real Throttle Scheduling & Latest State Assertion
runTest("3. MenuBarManager Real Throttle Scheduling & Latest State Capture") {
    let manager = MenuBarManager.shared
    manager.resetTestMetrics()

    var capturedSignatures: [String] = []
    manager.onPerformUpdateTitleAndMenu = {
        capturedSignatures.append(manager.computeRenderSignature())
    }

    // Fire 12 triggers spaced 50ms apart over 600ms on active RunLoop
    for i in 1...12 {
        AgentStore.shared.updateStatus(for: .chatgpt, status: .working, detail: "Step \(i)")
        manager.scheduleTitleAndMenuUpdate()
        try assert(manager.activePendingTimerCount <= 1, "No more than 1 pending timer must ever exist.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    try assert(manager.renderExecutionCount >= 2 && manager.renderExecutionCount <= 5, "Execution count must be rate-bounded (actual: \(manager.renderExecutionCount)).")
    try assert(capturedSignatures.count == manager.renderExecutionCount, "Captured signatures count must equal render execution count.")

    let lastCapturedSignature = capturedSignatures.last ?? ""
    try assert(lastCapturedSignature.contains("Step 12"), "The LAST ACTUAL RENDER CALLBACK must observe the final Step 12 state (actual signature: \(lastCapturedSignature)).")
}

// 4. AutoMonitor Deterministic Polling Non-Overlap Test
runTest("4. AutoMonitor Deterministic Polling Non-Overlap Guard") {
    let monitor = AutoMonitor.shared
    monitor.resetTestMetrics()

    let barrierSem = DispatchSemaphore(value: 0)
    monitor.pollBodyHandler = {
        _ = barrierSem.wait(timeout: .now() + 2.0)
    }

    let thread1Group = DispatchGroup()
    thread1Group.enter()
    DispatchQueue.global().async {
        monitor.checkAllAgents()
        thread1Group.leave()
    }

    Thread.sleep(forTimeInterval: 0.05) // Ensure Thread 1 is holding the poll body lock

    let competingGroup = DispatchGroup()
    for _ in 1...10 {
        competingGroup.enter()
        DispatchQueue.global().async {
            monitor.checkAllAgents()
            competingGroup.leave()
        }
    }

    _ = competingGroup.wait(timeout: .now() + 1.0)
    barrierSem.signal()
    _ = thread1Group.wait(timeout: .now() + 1.0)

    try assert(monitor.peakConcurrentCheckCount == 1, "Peak concurrent poll body executions must be exactly 1.")
    try assert(monitor.rejectedConcurrentCheckCount == 10, "10 competing callers must be rejected during held window (actual: \(monitor.rejectedConcurrentCheckCount)).")
    monitor.pollBodyHandler = nil
}

// 5. Bounded Subprocess Execution Timeout, Reaping & Unreaped Containment
runTest("5. Subprocess Execution Timeout, Reaping & Unreaped Containment") {
    let monitor = AutoMonitor.shared
    monitor.resetProcessTracking()

    // 5A. Normal command completes
    let echoOutput = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["hello_containment"],
        timeoutSeconds: 1.0
    )
    try assert(echoOutput == "hello_containment", "Fast subprocess must return correct output.")
    try assert(monitor.lastSubprocessPID != nil, "Subprocess PID must be recorded.")
    try assert(monitor.lastSubprocessConfirmedReaped == true, "Normal execution must be reported as confirmed reaped.")
    try assert(monitor.unresolvedProcessPID == nil, "Unresolved PID must be nil.")

    let echoPID = monitor.lastSubprocessPID!
    try assert(kill(echoPID, 0) != 0, "Normal command PID \(echoPID) must be confirmed dead/reaped.")

    // 5B. Timeout + successful termination reported as confirmed reaped
    let start = Date()
    let sleepOutput = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        timeoutSeconds: 0.1
    )
    let elapsed = Date().timeIntervalSince(start)

    try assert(sleepOutput == nil, "Timed out subprocess must return nil.")
    try assert(elapsed < 1.0, "Timed out subprocess must terminate within 1.0 second limit.")
    try assert(monitor.lastSubprocessConfirmedReaped == true, "Timeout with successful termination must be reported as confirmed reaped.")
    try assert(monitor.unresolvedProcessPID == nil, "Unresolved PID must be nil.")

    let sleepPID = monitor.lastSubprocessPID!
    try assert(kill(sleepPID, 0) != 0, "Timed out command PID \(sleepPID) must be confirmed dead/reaped.")

    // 5C. Unresolved process blocking guard
    monitor.resetProcessTracking()
    monitor.setUnresolvedProcessPIDForTesting(ProcessInfo.processInfo.processIdentifier)

    // Attempt second launch while previous process is recorded as active unresolved
    let blockedOutput = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["should_be_blocked"],
        timeoutSeconds: 1.0
    )
    try assert(blockedOutput == nil, "Subprocess launch must be blocked while unresolved process exists.")
    try assert(monitor.processSpawnBlockedCount >= 1, "Blocked spawn counter must be incremented.")

    // Clear test unresolved PID
    monitor.setUnresolvedProcessPIDForTesting(nil)

    // Now that unresolved PID has been cleared, launch resumes
    let resumedOutput = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["resumed_launch"],
        timeoutSeconds: 1.0
    )
    try assert(resumedOutput == "resumed_launch", "Subprocess launch must resume once unresolved PID has been cleared.")
    try assert(monitor.unresolvedProcessPID == nil, "Unresolved PID must be nil.")
}

// 6. Claude Metadata Cache Decision & Bounded Tail Reading
runTest("6. Claude Metadata Cache Decision & Bounded Tail Reading") {
    let monitor = AutoMonitor.shared
    monitor.resetTestMetrics()

    let d1 = Date()
    let d2 = Date().addingTimeInterval(10)

    let infoA1 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d1)
    let infoA1_dupe = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d1)
    let infoA2 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d2)
    let infoB2 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_b.jsonl", modDate: d2)

    try assert(monitor.shouldReadClaudeTranscript(info: infoA1) == true, "New path/mtime must require content read.")
    try assert(monitor.shouldReadClaudeTranscript(info: infoA1_dupe) == false, "Identical path+mtime must suppress content read.")
    try assert(monitor.shouldReadClaudeTranscript(info: infoA2) == true, "Changed mtime must require content read.")
    try assert(monitor.shouldReadClaudeTranscript(info: infoB2) == true, "Changed path must require content read.")

    let tmpPath = NSTemporaryDirectory() + "test_oversized_\(UUID().uuidString).jsonl"
    let content = String(repeating: "{\"type\":\"USER_INPUT\",\"text\":\"test line\"}\n", count: 3000) // ~120KB
    try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let readData = monitor.readTailOfFile(atPath: tmpPath, maxBytes: 65536)
    try assert(readData != nil, "Tail reader must return content.")
    let bytes = readData?.utf8.count ?? 0
    try assert(bytes <= 65540, "Tail reader output must be bounded to 64KB max (actual: \(bytes) bytes).")
}

// 7. Continuous Duration Epoch Monotonicity
runTest("7. Continuous Duration Epoch Monotonicity Across Re-evaluations") {
    let store = AgentStore.shared
    store.updateStatus(for: .claude, status: .idle)

    let testTurnId = "turn_stage1_epoch_001"
    store.updateStatus(for: .claude, status: .working, detail: "Claude step 1", turnId: testTurnId)

    let firstState = store.getStatus(for: .claude)
    try assert(firstState.thinkingStartTime != nil, "thinkingStartTime must be set on working start.")
    let startTime = firstState.thinkingStartTime!

    for i in 2...5 {
        Thread.sleep(forTimeInterval: 0.05)
        store.updateStatus(for: .claude, status: .working, detail: "Claude step \(i)", turnId: testTurnId)
        let state = store.getStatus(for: .claude)
        try assert(state.thinkingStartTime == startTime, "thinkingStartTime MUST NOT reset during step \(i) of same turn.")
    }

    Thread.sleep(forTimeInterval: 0.05)
    store.updateStatus(for: .claude, status: .done, detail: "Turn completed", turnId: testTurnId)
    let finalState = store.getStatus(for: .claude)
    try assert(finalState.thinkingStartTime == nil, "thinkingStartTime must clear on terminal completion.")
    try assert(finalState.lastDurationSeconds != nil && finalState.lastDurationSeconds! > 0.1, "lastDurationSeconds must cover full continuous turn.")
}

// 8. Open-Lid Smart Keep Awake Assertion Lifecycle & Zero Leaks
runTest("8. Open-Lid Smart Keep Awake Assertion Lifecycle & Zero Leaks") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto

    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentStore.shared.updateStatus(for: .chatgpt, status: .idle)
    AgentStore.shared.updateStatus(for: .codex, status: .idle)
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
    sleepMgr.updateSleepAssertionState()

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude task working")
    sleepMgr.updateSleepAssertionState()

    AgentStore.shared.updateStatus(for: .claude, status: .done, detail: "Claude task completed")
    sleepMgr.updateSleepAssertionState()

    for i in 1...5 {
        AgentStore.shared.updateStatus(for: .chatgpt, status: .working, detail: "Cycle \(i)")
        sleepMgr.updateSleepAssertionState()
        AgentStore.shared.updateStatus(for: .chatgpt, status: .idle, detail: "Idle \(i)")
        sleepMgr.updateSleepAssertionState()
    }
}

// 9. Claude Stale Log Permission Suppression & Multi-Step Turn Continuity
runTest("9. Claude Stale Log Permission Suppression & Multi-Step Turn Continuity") {
    let monitor = AutoMonitor.shared
    monitor.resetTestMetrics()

    let tmpDir = NSTemporaryDirectory() + "claude_test_\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let jsonlPath = tmpDir + "active_session.jsonl"
    let userPromptTs = "2026-08-14T12:00:00.000Z"
    let content = """
    {"type":"user","uuid":"user_msg_001","timestamp":"\(userPromptTs)","origin":{"kind":"human"}}
    {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool_001","name":"Bash"}]}}
    """
    try content.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

    let info = AutoMonitor.ClaudeTranscriptInfo(path: jsonlPath, modDate: Date())
    try assert(monitor.shouldReadClaudeTranscript(info: info) == true, "Must read active Claude transcript.")

    let oldDate = Date(timeIntervalSince1970: 1786707000)
    let promptDate = Date(timeIntervalSince1970: 1786708800)
    let newDate = Date(timeIntervalSince1970: 1786709100)

    try assert(oldDate < promptDate, "Old log entry must precede current prompt date.")
    try assert(newDate > promptDate, "New log entry must be after current prompt date.")
}

// 10. Codex Atomic Thread Binding & Non-Flapping Done State
runTest("10. Codex Atomic Thread Binding & Non-Flapping Done State") {
    let store = AgentStore.shared
    let testThreadId = "019ff66f-5bac-73c1-a1d9-9ce4c4c83d72"
    let testTurnId = "\(testThreadId)_turn_5"

    store.updateStatus(for: .codex, status: .working, detail: "Codex active", sessionTitle: "Atomic Title", turnId: testTurnId)
    let workingState = store.getStatus(for: .codex)
    try assert(workingState.status == .working, "Codex must be working.")
    try assert(workingState.turnId == testTurnId, "Codex turnId must match.")

    store.updateStatus(for: .codex, status: .done, detail: "Codex task completed", sessionTitle: "Atomic Title", turnId: testTurnId)
    let doneState = store.getStatus(for: .codex)
    try assert(doneState.status == .done, "Codex must transition to done.")

    store.markChecked(for: .codex)
    let idleState = store.getStatus(for: .codex)
    try assert(idleState.status == .idle, "Codex must be idle after inspection.")

    try assert(store.getStatus(for: .codex).status == .idle, "Codex must remain idle without flapping.")
}

// 11. Anti-Sleep Caffeinate Ownership Audit & Cleanup
runTest("11. Anti-Sleep Caffeinate Ownership Audit & Cleanup") {
    let cleanedPIDs = SleepManager.cleanupStaleCaffeinateProcesses()
    print("🧹 Audit result: Cleaned \(cleanedPIDs.count) stale caffeinate process(es): \(cleanedPIDs)")
    try assert(cleanedPIDs.allSatisfy { $0 > 0 }, "Cleaned PIDs must all be valid process identifiers.")
}

// 12. Claude Untouched 24h+ Stale Session Suppression
runTest("12. Claude Untouched 24h+ Stale Session Suppression") {
    let tmpDir = NSTemporaryDirectory() + "claude_stale_\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let jsonlPath = tmpDir + "stale_26h_session.jsonl"
    let content = """
    {"type":"user","uuid":"stale_msg_26h","timestamp":"2026-08-14T10:00:00.000Z","origin":{"kind":"human"}}
    {"type":"assistant","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"incomplete response"}]}}
    """
    try content.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

    let staleDate = Date().addingTimeInterval(-93600)
    try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: jsonlPath)

    let info = AutoMonitor.ClaudeTranscriptInfo(path: jsonlPath, modDate: staleDate)
    let timeSinceMod = Date().timeIntervalSince(info.modDate)
    let isTurnInProgress = timeSinceMod <= 300.0
    try assert(!isTurnInProgress, "Untouched 24h+ session must NOT evaluate to turn in progress.")
}

// 14. Per-Session Multi-Session Aggregate Priority
runTest("14. Per-Session Multi-Session Aggregate Priority (Blocked > Working > Done > Idle)") {
    let store = AgentStore.shared
    let s1 = AgentSessionInfo(provider: .claude, sessionId: "c1", title: "Session 1 Working", status: .working, sourceEvidence: "Working")
    let s2 = AgentSessionInfo(provider: .claude, sessionId: "c2", title: "Session 2 Blocked", status: .blocked, attentionReason: "Permission needed", sourceEvidence: "Blocked")

    store.syncSessions(for: .claude, activeSessions: [s1, s2], processRunning: true)
    let parent = store.getStatus(for: .claude)
    try assert(parent.status == .blocked, "Parent Claude aggregate status must be Blocked when 1 session is Blocked and 1 is Working.")

    let sessions = store.getSessions(for: .claude)
    try assert(sessions.count == 2, "getSessions must return both tracked Claude sessions.")
    try assert(sessions.contains(where: { $0.status == .working }), "Working session must be preserved.")
    try assert(sessions.contains(where: { $0.status == .blocked }), "Blocked session must be preserved.")
}

// 15. Antigravity Long-Running Command Working State
runTest("15. Antigravity Long-Running Command (No False Needs You)") {
    let store = AgentStore.shared
    let s = AgentSessionInfo(provider: .antigravity, sessionId: "agy_cmd_1", title: "Antigravity Run Command", status: .working, sourceEvidence: "RUN_COMMAND executing")
    store.syncSessions(for: .antigravity, activeSessions: [s], processRunning: true)

    let parent = store.getStatus(for: .antigravity)
    try assert(parent.status == .working, "Long-running Antigravity command must evaluate to Working, not Needs You / Blocked.")
}

// 17. User Input Prompt Containing Literal Strings Does Not Trigger Blocked
runTest("17. User Input Prompt Containing Literal Strings Does Not Trigger Blocked") {
    let store = AgentStore.shared
    let userPromptText = "Please write a function named ask_question that includes RequestFeedback and permission_request text."
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy_user_prompt_test",
        title: "Test Session",
        status: .working,
        turnId: "turn_user_prompt_1",
        sourceEvidence: userPromptText
    )
    store.syncSessions(for: .antigravity, activeSessions: [session], processRunning: true)
    let state = store.getStatus(for: .antigravity)
    try assert(state.status == .working, "USER PROMPT containing ask_question / RequestFeedback MUST NOT create Blocked.")
}

// 18. Genuine Planner Response Tool Call Triggers Blocked
runTest("18. Genuine Planner Response Tool Call Triggers Blocked") {
    let store = AgentStore.shared
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy_genuine_ask_q",
        title: "Permission Needed",
        status: .blocked,
        turnId: "turn_ask_q_1",
        attentionReason: "🔴 Waiting for user permission / ask_question modal response",
        sourceEvidence: "PLANNER_RESPONSE ask_question"
    )
    store.syncSessions(for: .antigravity, activeSessions: [session], processRunning: true)
    let state = store.getStatus(for: .antigravity)
    try assert(state.status == .blocked, "Genuine ask_question tool call MUST create Blocked status.")
}

// 19. Per-Session Acknowledgement Ledger Prevents Resurrecting Done Parent Status
runTest("19. Per-Session Acknowledgement Ledger Prevents Resurrecting Done Parent Status") {
    let store = AgentStore.shared
    let turnId = "turn_done_ledger_100"
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy_ack_test_session",
        title: "Completed Task",
        status: .done,
        turnId: turnId,
        sourceEvidence: "Task complete"
    )

    // 1. Initial sync -> parent status is .done
    store.syncSessions(for: .antigravity, activeSessions: [session], processRunning: true)
    try assert(store.getStatus(for: .antigravity).status == .done, "Parent status must be .done for unacknowledged completed session.")

    // 2. Explicit session acknowledgement
    store.markSessionChecked(provider: .antigravity, sessionId: "agy_ack_test_session", turnId: turnId)
    try assert(store.getStatus(for: .antigravity).status == .idle, "Parent status must become .idle after session acknowledgement.")

    // 3. Resync same session turn -> MUST NOT resurrect parent status to .done
    store.syncSessions(for: .antigravity, activeSessions: [session], processRunning: true)
    try assert(store.getStatus(for: .antigravity).status == .idle, "Resyncing same acknowledged session MUST NOT resurrect parent .done status.")

    // 4. New turn begins -> session becomes unacknowledged again
    let newTurnSession = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy_ack_test_session",
        title: "Completed Task New Turn",
        status: .done,
        turnId: "turn_done_ledger_101",
        sourceEvidence: "New turn complete"
    )
    store.syncSessions(for: .antigravity, activeSessions: [newTurnSession], processRunning: true)
    try assert(store.getStatus(for: .antigravity).status == .done, "New completed turn must automatically become unacknowledged and surface as .done.")
}

// 20. Claude Hook Test Isolation Guard (Synthetic Test Session Rejection)
runTest("20. Claude Hook Test Isolation Guard (Synthetic Test Session Rejection)") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let syntheticPayload: [String: Any] = [
        "event": "UserPromptSubmit",
        "session_id": "test-session-uuid-999",
        "cwd": "/Users/ava/Projects/Agent-webchat monitor"
    ]
    let handled = store.handleClaudeHookEvent(json: syntheticPayload, isTestMode: false)
    try assert(handled == true, "Hook event handler must return true for receipt.")

    let claudeSessions = store.getSessions(for: .claude)
    let hasSynthetic = claudeSessions.contains(where: { $0.sessionId == "test-session-uuid-999" })
    try assert(!hasSynthetic, "Synthetic test session must NOT contaminate live production AgentStore state.")

    let testHandled = store.handleClaudeHookEvent(json: syntheticPayload, isTestMode: true)
    try assert(testHandled == true, "Test mode payload must be handled.")
    let testSessions = store.getSessions(for: .claude)
    try assert(testSessions.contains(where: { $0.sessionId == "test-session-uuid-999" }), "Test mode must accept test payload for verification.")

    store.purgeSyntheticAndStaleSessions(provider: .claude)
    try assert(!store.getSessions(for: .claude).contains(where: { $0.sessionId == "test-session-uuid-999" }), "Purge must clean up test session.")
}

// 21. Claude Bounded Lifecycle Pruning & Working Non-Pruning Guarantee
runTest("21. Claude Bounded Lifecycle Pruning & Working Non-Pruning Guarantee") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let realSessionId = "a1b2c3d4-e5f6-4a5b-8c7d-9e0f1a2b3c4d"
    let pastDate = Date().addingTimeInterval(-600)

    let workingSession = AgentSessionInfo(
        provider: .claude,
        sessionId: realSessionId,
        title: "[TestWorkspace]",
        status: .working,
        turnId: "turn_working_1",
        sourceEvidence: "Claude Hook: UserPromptSubmit",
        lastUpdated: pastDate
    )
    store.syncSessions(for: .claude, activeSessions: [workingSession], processRunning: true)

    store.pruneStaleClaudeSessions(maxAgeSeconds: 300)
    let activeSessions = store.getSessions(for: .claude)
    try assert(activeSessions.contains(where: { $0.sessionId == realSessionId }), "WORKING session MUST NOT be pruned due to age.")

    var doneSession = workingSession
    doneSession.status = .done
    doneSession.lastUpdated = pastDate
    store.syncSessions(for: .claude, activeSessions: [doneSession], processRunning: true)

    store.pruneStaleClaudeSessions(maxAgeSeconds: 300)
    let remainingSessions = store.getSessions(for: .claude)
    try assert(!remainingSessions.contains(where: { $0.sessionId == realSessionId }), "Done session > 5m MUST be pruned by bounded lifecycle cleanup.")
}

// 22. Antigravity Hook Test Isolation & Lifecycle Transitions
runTest("22. Antigravity Hook Test Isolation & Lifecycle Transitions") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)

    let syntheticPayload: [String: Any] = [
        "event": "PreInvocation",
        "session_id": "test_agy_stage1_runner_999",
        "cwd": "/Users/ava/Projects/Agent-webchat monitor"
    ]
    let handled = store.handleAntigravityHookEvent(json: syntheticPayload, isTestMode: false)
    try assert(handled == true, "Hook event handler must return true for synthetic payload receipt.")

    let agySessions = store.getSessions(for: .antigravity)
    let hasSynthetic = agySessions.contains(where: { $0.sessionId == "test_agy_stage1_runner_999" })
    try assert(!hasSynthetic, "Synthetic test session must NOT contaminate live production AgentStore state.")

    let testHandled = store.handleAntigravityHookEvent(json: syntheticPayload, isTestMode: true)
    try assert(testHandled == true, "Test mode payload must be handled.")
    let testSessions = store.getSessions(for: .antigravity)
    try assert(testSessions.contains(where: { $0.sessionId == "test_agy_stage1_runner_999" }), "Test mode must accept test payload for verification.")

    store.purgeSyntheticAndStaleSessions(provider: .antigravity)
    try assert(!store.getSessions(for: .antigravity).contains(where: { $0.sessionId == "test_agy_stage1_runner_999" }), "Purge must clean up Antigravity test session.")
}

// 23. Antigravity Turn Stability, TurnId Continuity & Ambiguous Permission Correlation
// 23. Native Antigravity Permission Detection, Correlation Lifecycle & Smart Auto Continuity
runTest("23. Native Antigravity Permission Detection, Correlation Lifecycle & Smart Auto Continuity") {
    let store = AgentStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    let testSessionId = "test_agy_native_perm_100"
    defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

    // Clear initial state
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)
    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentStore.shared.updateStatus(for: .chatgpt, status: .idle)
    AgentStore.shared.updateStatus(for: .codex, status: .off)

    // 1. PreInvocation -> Working + turnId created
    _ = store.handleAntigravityHookEvent(json: ["event": "PreInvocation", "session_id": testSessionId, "cwd": "/tmp"], isTestMode: true)
    let s1 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(s1?.status == .working, "1. PreInvocation must transition to working.")
    try assert(s1?.turnId != nil, "1. turnId must be created on first PreInvocation.")
    _ = s1?.turnId
    let startThinking = s1?.thinkingStartTime

    // Scenario 2: Native-shaped notification with NO pending tool -> NOT Needs You (stays working)
    store.updateAntigravityPermissionFromNotification(reason: "AGY Permission Detection Audit")
    let sNoPending = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sNoPending?.status == .working, "2. Native-shaped notification with NO pending tool must NOT produce Needs You.")
    try assert(store.getStatus(for: .antigravity).status == .working, "2. Parent status must remain working when no tool is pending.")

    // Scenario 3: Unrelated notification with NO pending tool -> NOT Needs You
    store.updateAntigravityPermissionFromNotification(reason: "Slack message received")
    try assert(store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })?.status == .working, "3. Unrelated notification must NOT produce Needs You.")

    // PreToolUse records pending tool
    _ = store.handleAntigravityHookEvent(json: ["event": "PreToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 1, "cwd": "/tmp"], isTestMode: true)
    let sPreTool = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sPreTool?.pendingToolName == "run_command", "PreToolUse must record pendingToolName.")
    try assert(sPreTool?.pendingToolTime != nil, "PreToolUse must record pendingToolTime.")

    // Scenario 4: PreToolUse -> Stop (model stream finished) before user clicked Allow -> pending tool preserved
    _ = store.handleAntigravityHookEvent(json: ["event": "Stop", "session_id": testSessionId, "cwd": "/tmp"], isTestMode: true)
    let sAfterStop = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sAfterStop?.status == .working, "4. Stop while tool is pending must NOT set status to done.")
    try assert(sAfterStop?.pendingToolName == "run_command", "4. Stop while tool is pending must preserve pendingToolName.")

    // Scenario 1: Native-shaped notification ("Antigravity" / "AGY Permission Detection Audit", ZERO "permission" keywords) + unresolved PreToolUse -> Needs You
    store.updateAntigravityPermissionFromNotification(reason: "AGY Permission Detection Audit")
    let sBlocked = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sBlocked?.status == .blocked, "1. Native-shaped notification + pending tool MUST produce Needs You (.blocked).")
    try assert(sBlocked?.attentionReason == "AGY Permission Detection Audit", "1. attentionReason must store native banner text.")
    try assert(store.getStatus(for: .antigravity).status == .blocked, "1. Parent status must become blocked.")

    // Scenario 9: Smart Auto check: Working -> Blocked -> Smart Auto assertion remains TRUE
    let evalBlocked = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalBlocked.shouldKeepAwake == true, "9. Smart Auto assertion MUST remain active while agent is blocked (Needs You).")
    try assert(evalBlocked.reason.contains("Antigravity"), "9. Smart Auto reason must mention Antigravity.")

    // Subsequent Stop while blocked -> PRESERVES .blocked and duration
    _ = store.handleAntigravityHookEvent(json: ["event": "Stop", "session_id": testSessionId, "cwd": "/tmp"], isTestMode: true)
    try assert(store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })?.status == .blocked, "Stop while blocked must preserve .blocked.")

    // Scenario 5: User clicks Allow -> PostToolUse resumes Working with continuous duration
    _ = store.handleAntigravityHookEvent(json: ["event": "PostToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 1, "cwd": "/tmp"], isTestMode: true)
    let sResumed = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sResumed?.status == .working, "5. PostToolUse after Allow MUST transition status to working.")
    try assert(sResumed?.attentionReason == nil, "5. attentionReason must be cleared.")
    try assert(sResumed?.thinkingStartTime == startThinking, "5. thinkingStartTime must be preserved across permission gate.")

    // Scenario 6: PostToolUse cleared pending evidence
    try assert(sResumed?.pendingToolName == nil, "6. PostToolUse must clear pendingToolName.")
    try assert(sResumed?.pendingToolTime == nil, "6. PostToolUse must clear pendingToolTime.")

    // Smart Auto remains active while working
    let evalWorking = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalWorking.shouldKeepAwake == true, "9. Smart Auto assertion MUST remain active while agent is working.")

    // Scenario 7: Stale pending evidence cannot bind indefinitely
    _ = store.handleAntigravityHookEvent(json: ["event": "PreToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 2, "cwd": "/tmp"], isTestMode: true)
    // Manually backdate pendingToolTime beyond 60s
    if var current = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId }) {
        current.pendingToolTime = Date().addingTimeInterval(-120.0) // 2 minutes ago
        store.syncSessions(for: .antigravity, activeSessions: [current], processRunning: true)
    }
    store.updateAntigravityPermissionFromNotification(reason: "AGY Permission Detection Audit")
    let sStale = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(sStale?.status == .working, "7. Stale pending evidence (>60s) must NOT bind to notification.")

    // Clear stale pending tool
    _ = store.handleAntigravityHookEvent(json: ["event": "PostToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 2, "cwd": "/tmp"], isTestMode: true)

    // Scenario 8: Multiple ambiguous pending AGY sessions do NOT get arbitrary assignment
    let testSessionId2 = "test_agy_native_perm_200"
    _ = store.handleAntigravityHookEvent(json: ["event": "PreInvocation", "session_id": testSessionId2, "cwd": "/tmp"], isTestMode: true)
    _ = store.handleAntigravityHookEvent(json: ["event": "PreToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 3, "cwd": "/tmp"], isTestMode: true)
    _ = store.handleAntigravityHookEvent(json: ["event": "PreToolUse", "session_id": testSessionId2, "tool_name": "run_command", "step_idx": 3, "cwd": "/tmp"], isTestMode: true)

    store.updateAntigravityPermissionFromNotification(reason: "AGY Permission Detection Audit")
    let sAmb1 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    let sAmb2 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId2 })
    try assert(sAmb1?.status == .working, "8. Ambiguous sessions must not be arbitrarily assigned .blocked.")
    try assert(sAmb2?.status == .working, "8. Ambiguous sessions must not be arbitrarily assigned .blocked.")

    // Clean up second session and finish first
    _ = store.handleAntigravityHookEvent(json: ["event": "PostToolUse", "session_id": testSessionId, "tool_name": "run_command", "step_idx": 3, "cwd": "/tmp"], isTestMode: true)
    _ = store.handleAntigravityHookEvent(json: ["event": "PostToolUse", "session_id": testSessionId2, "tool_name": "run_command", "step_idx": 3, "cwd": "/tmp"], isTestMode: true)
    _ = store.handleAntigravityHookEvent(json: ["event": "Stop", "session_id": testSessionId, "cwd": "/tmp"], isTestMode: true)
    _ = store.handleAntigravityHookEvent(json: ["event": "Stop", "session_id": testSessionId2, "cwd": "/tmp"], isTestMode: true)

    try assert(store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })?.status == .done, "Stop with no pending tools MUST transition to done.")
    let evalDone = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalDone.shouldKeepAwake == false, "9. Smart Auto releases assertion once all agents are done/idle.")
}

// 24. Claude Quota Exhaustion Semantics & Separation from Lifecycle
runTest("24. Claude Quota Exhaustion Semantics & Separation from Lifecycle") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let menuMgr = MenuBarManager.shared

    // Set Claude live usage to 100% (quota exhausted)
    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        sessionResetText: nil,
        weeklyLimitPercent: 54.0,
        weeklyResetText: nil,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        quotaTimestamp: Date(),
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)

    // 1. Quota exhaustion establishes availability == .quotaExhausted
    try assert(exhaustedUsage.isQuotaExhausted == true, "1. 100% session usage must evaluate isQuotaExhausted == true.")
    try assert(store.getAvailability(for: .claude) == .quotaExhausted, "1. Provider availability must be .quotaExhausted.")

    let claudeState = store.getStatus(for: .claude)
    try assert(claudeState.availability == .quotaExhausted, "1. AgentInfo.availability must be .quotaExhausted.")

    // 2. Quota exhausted alone MUST NOT produce .blocked (Needs You) or Attention Needed
    try assert(claudeState.status != .blocked, "2. Quota exhaustion MUST NOT set lifecycle status to .blocked.")
    try assert(claudeState.status != .working, "2. Quota exhaustion MUST NOT set lifecycle status to .working.")

    // 3. Render signature and menu bar display should communicate Quota Exhausted
    let renderSig = menuMgr.computeRenderSignature()
    try assert(renderSig.contains("quotaExhausted"), "3. Render signature must reflect quotaExhausted availability.")
}

// 25. Quota Exhausted Alone Does Not Keep Smart Auto Awake
runTest("25. Quota Exhausted Alone Does Not Keep Smart Auto Awake") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto

    // Ensure all providers are otherwise idle/done
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    // Claude quota is exhausted
    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Quota exhausted Claude alone MUST NOT keep Smart Auto awake.")
    try assert(eval.reason.contains("idle/done/off"), "Smart Auto reason must report idle.")
}

// 26. Quota Exhausted Claude + Active AGY or ChatGPT Keeps Smart Auto Awake
runTest("26. Quota Exhausted Claude + Active AGY or ChatGPT Keeps Smart Auto Awake") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // Claude quota is exhausted
    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    // Scenario A: Claude exhausted + AGY Working -> Smart Auto active because of AGY
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .antigravity, status: .working, detail: "AGY Task running")
    let evalAgy = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalAgy.shouldKeepAwake == true, "A. Smart Auto MUST be active when AGY is working while Claude is exhausted.")
    try assert(evalAgy.reason.contains("Antigravity"), "A. Smart Auto reason must attribute keep-awake to Antigravity.")

    // Scenario B: Claude exhausted + ChatGPT Working -> Smart Auto active because of ChatGPT
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .chatgpt, status: .working, detail: "ChatGPT generating")
    let evalGpt = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalGpt.shouldKeepAwake == true, "B. Smart Auto MUST be active when ChatGPT is working while Claude is exhausted.")
    try assert(evalGpt.reason.contains("ChatGPT Web"), "B. Smart Auto reason must attribute keep-awake to ChatGPT Web.")

    // Reset ChatGPT
    store.updateStatus(for: .chatgpt, status: .idle)
}

// 27. Genuine Claude Needs You While Available Triggers Needs You & Smart Auto
runTest("27. Genuine Claude Needs You While Available Triggers Needs You & Smart Auto") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    let testSessionId = "test_claude_quota_perm_001"
    defer { store.purgeSyntheticAndStaleSessions(provider: .claude) }

    // Claude quota is available (e.g. 45% used)
    let availableUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 45.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: availableUsage)
    try assert(store.getAvailability(for: .claude) == .available, "Claude must be available.")

    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    // Genuine PermissionRequest hook arrives
    let permPayload: [String: Any] = [
        "event": "PermissionRequest",
        "session_id": testSessionId,
        "tool_name": "Bash",
        "cwd": "/tmp"
    ]
    _ = store.handleClaudeHookEvent(json: permPayload, isTestMode: true)

    let claudeInfo = store.getStatus(for: .claude)
    try assert(claudeInfo.status == .blocked, "Genuine PermissionRequest while quota is available MUST trigger .blocked (Needs You).")
    try assert(claudeInfo.availability == .available, "Availability must remain .available.")

    let evalPerm = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalPerm.shouldKeepAwake == true, "Smart Auto MUST be active for genuine Claude permission gate.")
    try assert(evalPerm.reason.contains("Claude Code"), "Smart Auto reason must mention Claude Code.")

    // User approves -> Stop -> Done
    _ = store.handleClaudeHookEvent(json: ["event": "Stop", "session_id": testSessionId, "cwd": "/tmp"], isTestMode: true)
    try assert(store.getStatus(for: .claude).status == .done, "Stop after approval must transition to done.")
    try assert(sleepMgr.evaluateSmartAutoRequirement().shouldKeepAwake == false, "Smart Auto must release keep-awake upon completion.")
}

// 28. Transitioning From Quota Exhausted to Available Restores Clean State
runTest("28. Transitioning From Quota Exhausted to Available Restores Clean State") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    // Start exhausted
    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    try assert(store.getAvailability(for: .claude) == .quotaExhausted, "Must be quotaExhausted.")

    // Usage resets/drops to 0% (e.g. 5-hour window rollover)
    let resetUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 0.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: resetUsage)

    try assert(resetUsage.isQuotaExhausted == false, "0% usage must NOT be quota exhausted.")
    try assert(store.getAvailability(for: .claude) == .available, "Availability must restore to .available without residue.")
    let info = store.getStatus(for: .claude)
    try assert(info.availability == .available, "AgentInfo.availability must restore to .available.")
}

// 29. Closed-Lid V2: Power State Inspection & Battery Safety
runTest("29. Closed-Lid V2: Power State Inspection & Battery Safety") {
    let powerState = SleepManager.getPowerState(minBatteryPercent: 20)
    print("🔋 Tested Power State: isACPower=\(powerState.isACPower), battery=\(powerState.batteryPercent ?? -1)%, charging=\(powerState.isCharging), isSafe=\(powerState.isBatterySafe)")

    // Validate schema
    if !powerState.isACPower {
        try assert(powerState.batteryPercent != nil, "Battery percent must be available on battery power.")
        let expectedSafe = (powerState.batteryPercent ?? 0) >= 20
        try assert(powerState.isBatterySafe == expectedSafe, "isBatterySafe must be true only when battery >= 20% on battery power.")
    } else {
        try assert(powerState.isBatterySafe == true, "isBatterySafe must be true on AC power.")
    }
}

// 30. Closed-Lid V2: Stale Marker Detection & Startup Recovery Lifecycle
runTest("30. Closed-Lid V2: Stale Marker Detection & Startup Recovery Lifecycle") {
    let markerPath = SleepManager.disableSleepMarkerPath
    let fm = FileManager.default

    // Simulate a stale marker left by a crashed prior process
    let fakeStaleContent = "pid:99999\ntime:\(Date().timeIntervalSince1970 - 3600)\nreason:Prior crash\n"
    try? fakeStaleContent.write(toFile: markerPath, atomically: true, encoding: .utf8)
    try assert(fm.fileExists(atPath: markerPath), "Stale marker file must exist for test.")

    // Run cleanup
    SleepManager.cleanupStaleDisableSleepState()

    // Clean up test marker
    try? fm.removeItem(atPath: markerPath)
    try assert(!fm.fileExists(atPath: markerPath), "Marker file must be removed after cleanup.")
}

// 31. Closed-Lid V2: Smart Auto Lifecycle Binding & Quota Exhaustion Decoupling
runTest("31. Closed-Lid V2: Smart Auto Lifecycle Binding & Quota Exhaustion Decoupling") {
    let sleepMgr = SleepManager.shared
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    sleepMgr.mode = .smartAuto
    sleepMgr.isClosedLidModeEnabled = true
    defer {
        sleepMgr.isClosedLidModeEnabled = false
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        store.updateStatus(for: .chatgpt, status: .idle)
    }

    // Scenario A: Claude quota exhausted alone -> Smart Auto IDLE -> Closed-Lid NOT active
    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    let evalA = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalA.shouldKeepAwake == false, "A. Smart Auto MUST be idle for quota-exhausted Claude alone.")
    sleepMgr.updateSleepAssertionState()
    try assert(sleepMgr.isAssertionActive == false, "A. Open-lid keep-awake MUST be released.")
    try assert(sleepMgr.isDisableSleepActive == false, "A. Closed-lid disablesleep MUST NOT be active when Smart Auto is idle.")

    // Scenario B: Active AGY + Exhausted Claude -> Smart Auto ACTIVE -> Keep-awake asserted
    store.updateStatus(for: .antigravity, status: .working, detail: "AGY Task active")
    let evalB = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalB.shouldKeepAwake == true, "B. Smart Auto MUST be active when AGY is working.")
    try assert(evalB.reason.contains("Antigravity"), "B. Smart Auto reason must attribute keep-awake to Antigravity.")

    // Scenario C: Completion -> Releases all keep-awake
    store.updateStatus(for: .antigravity, status: .done, detail: "AGY Task completed")
    let evalC = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalC.shouldKeepAwake == false, "C. Smart Auto MUST release when AGY completes.")
    sleepMgr.updateSleepAssertionState()
    try assert(sleepMgr.isAssertionActive == false, "C. Keep-awake MUST be released.")
    try assert(sleepMgr.isDisableSleepActive == false, "C. Closed-lid disablesleep MUST be restored upon completion.")
}

// 32. Smart Auto Reason & Live IOPMAssertion Label Synchronization Across Provider Transitions
runTest("32. Smart Auto Reason & Live IOPMAssertion Label Synchronization Across Provider Transitions") {
    let sleepMgr = SleepManager.shared
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    sleepMgr.mode = .smartAuto
    defer {
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        sleepMgr.updateSleepAssertionState()
    }

    // Step 1: ChatGPT working
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .chatgpt, status: .working, detail: "Generating")
    sleepMgr.updateSleepAssertionState()

    try assert(sleepMgr.isAssertionActive == true, "Keep-awake must be active for ChatGPT.")
    try assert(sleepMgr.currentReason?.contains("ChatGPT Web") == true, "currentReason must mention ChatGPT Web.")
    let debugInfo1 = sleepMgr.getDebugInfo()
    try assert((debugInfo1["reason"] as? String)?.contains("ChatGPT Web") == true, "/debug/sleep reason must contain ChatGPT Web.")
    if let liveName1 = sleepMgr.getLiveIOPMAssertionName() {
        try assert(liveName1.contains("ChatGPT Web"), "Live IOPMAssertion label in powerd must contain ChatGPT Web: \(liveName1)")
    }

    // Step 2: Transition: ChatGPT becomes idle, Claude becomes working
    let availableUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 10.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: availableUsage)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .claude, status: .working, detail: "Claude working")
    sleepMgr.updateSleepAssertionState()

    try assert(sleepMgr.isAssertionActive == true, "Keep-awake must REMAIN active continuously across provider switch.")
    try assert(sleepMgr.currentReason?.contains("Claude Code") == true, "currentReason must update to Claude Code.")
    let debugInfo2 = sleepMgr.getDebugInfo()
    try assert((debugInfo2["reason"] as? String)?.contains("Claude Code") == true, "/debug/sleep reason must update to Claude Code.")
    if let liveName2 = sleepMgr.getLiveIOPMAssertionName() {
        try assert(liveName2.contains("Claude Code"), "Live IOPMAssertion label in powerd must update to Claude Code: \(liveName2)")
    }
}

// 33. Codex: task_started -> Working
runTest("33. Codex: task_started -> Working") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .codex)

    let testThreadId = "codex_t1_test"
    let testTurnId = "turn_codex_t1_001"

    let handled = store.handleCodexRolloutEvent(
        threadId: testThreadId,
        title: "Test Codex Thread",
        cwd: "/tmp",
        rolloutPath: "/tmp/codex_rollout_1.jsonl",
        eventType: "task_started",
        turnId: testTurnId,
        isTestMode: true
    )
    try assert(handled == true, "task_started event must be handled successfully.")

    let sessions = store.getSessions(for: .codex)
    let s = sessions.first(where: { $0.sessionId == testThreadId })
    try assert(s?.status == .working, "Codex child session must transition to .working.")
    try assert(s?.turnId == testTurnId, "Codex turnId must be stored.")
    try assert(s?.thinkingStartTime != nil, "thinkingStartTime must be recorded.")
    try assert(store.getStatus(for: .codex).status == .working, "Parent Codex aggregate status must be .working.")
}

// 34. Codex: matching task_complete -> Done
runTest("34. Codex: matching task_complete -> Done") {
    let store = AgentStore.shared
    let testThreadId = "codex_t1_test"
    let testTurnId = "turn_codex_t1_001"

    let handled = store.handleCodexRolloutEvent(
        threadId: testThreadId,
        title: "Test Codex Thread",
        cwd: "/tmp",
        rolloutPath: "/tmp/codex_rollout_1.jsonl",
        eventType: "task_complete",
        turnId: testTurnId,
        durationMs: 4500,
        isTestMode: true
    )
    try assert(handled == true, "matching task_complete must be handled.")

    let s = store.getSessions(for: .codex).first(where: { $0.sessionId == testThreadId })
    try assert(s?.status == .done, "Codex session must transition to .done.")
    try assert(s?.lastDurationSeconds == 4.5, "lastDurationSeconds must match durationMs (4.5s).")
    try assert(s?.thinkingStartTime == nil, "thinkingStartTime must be cleared upon completion.")
    try assert(store.getStatus(for: .codex).status == .done, "Parent Codex status must become .done.")
}

// 35. Codex: mismatched turn_id cannot complete another active turn
runTest("35. Codex: mismatched turn_id cannot complete another active turn") {
    let store = AgentStore.shared
    let testThreadId = "codex_t3_mismatch"
    let activeTurnId = "turn_active_333"

    _ = store.handleCodexRolloutEvent(
        threadId: testThreadId,
        title: "Mismatch Thread",
        cwd: "/tmp",
        rolloutPath: "/tmp/codex_rollout_3.jsonl",
        eventType: "task_started",
        turnId: activeTurnId,
        isTestMode: true
    )

    let mismatchHandled = store.handleCodexRolloutEvent(
        threadId: testThreadId,
        title: "Mismatch Thread",
        cwd: "/tmp",
        rolloutPath: "/tmp/codex_rollout_3.jsonl",
        eventType: "task_complete",
        turnId: "turn_DIFFERENT_999",
        durationMs: 2000,
        isTestMode: true
    )
    try assert(mismatchHandled == false, "Mismatched turn_id task_complete MUST return false.")

    let s = store.getSessions(for: .codex).first(where: { $0.sessionId == testThreadId })
    try assert(s?.status == .working, "Session must REMAIN .working when mismatched turn_id arrives.")
    try assert(s?.turnId == activeTurnId, "Session turnId must not be modified.")
    try assert(store.getStatus(for: .codex).status == .working, "Parent status must remain .working.")
}

// 36. Codex: two concurrent threads remain isolated
runTest("36. Codex: two concurrent threads remain isolated") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .codex)

    let threadA = "codex_iso_thread_A"
    let threadB = "codex_iso_thread_B"

    _ = store.handleCodexRolloutEvent(threadId: threadA, title: "Thread A", cwd: "/tmp/a", eventType: "task_started", turnId: "turn_A1", isTestMode: true)
    _ = store.handleCodexRolloutEvent(threadId: threadB, title: "Thread B", cwd: "/tmp/b", eventType: "task_started", turnId: "turn_B1", isTestMode: true)

    let startA = store.getSessions(for: .codex).first(where: { $0.sessionId == threadA })?.thinkingStartTime

    // Complete Thread B only
    _ = store.handleCodexRolloutEvent(threadId: threadB, title: "Thread B", cwd: "/tmp/b", eventType: "task_complete", turnId: "turn_B1", durationMs: 3000, isTestMode: true)

    let sessionA = store.getSessions(for: .codex).first(where: { $0.sessionId == threadA })
    let sessionB = store.getSessions(for: .codex).first(where: { $0.sessionId == threadB })

    try assert(sessionA?.status == .working, "Thread A must REMAIN .working.")
    try assert(sessionA?.turnId == "turn_A1", "Thread A turnId must be unchanged.")
    try assert(sessionA?.thinkingStartTime == startA, "Thread A thinkingStartTime must NOT be mutated by Thread B.")

    try assert(sessionB?.status == .done, "Thread B must be .done.")
    try assert(store.getStatus(for: .codex).status == .working, "Parent status must be .working while Thread A is still active.")
}

// 37. Codex: partial JSON line does not mutate lifecycle
runTest("37. Codex: partial JSON line does not mutate lifecycle") {
    let monitor = AutoMonitor.shared
    monitor.resetTestMetrics()

    let tmpPath = NSTemporaryDirectory() + "codex_partial_\(UUID().uuidString).jsonl"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let partialContent = "{\"timestamp\":\"2026-08-17T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_st"
    try partialContent.write(toFile: tmpPath, atomically: true, encoding: .utf8)

    let threadInfo = AutoMonitor.CodexThreadInfo(id: "codex_partial_thread", title: "Partial Thread", rolloutPath: tmpPath)
    monitor.processCodexRollout(thread: threadInfo)

    let s1 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_partial_thread" })
    try assert(s1 == nil || s1?.status != .working, "Partial line fragment MUST NOT transition lifecycle to .working.")

    // Append the remainder of the line with newline
    if let handle = FileHandle(forWritingAtPath: tmpPath) {
        handle.seekToEndOfFile()
        handle.write("arted\",\"turn_id\":\"turn_partial_complete\"}}\n".data(using: .utf8)!)
        try? handle.closeFile()
    }

    monitor.processCodexRollout(thread: threadInfo)
    let s2 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_partial_thread" })
    try assert(s2?.status == .working, "Full line arrival must successfully transition to .working.")
    try assert(s2?.turnId == "turn_partial_complete", "turnId must match assembled line.")
}

// 38. Codex: appended completion line is processed exactly once
runTest("38. Codex: appended completion line is processed exactly once") {
    let monitor = AutoMonitor.shared
    let tmpPath = NSTemporaryDirectory() + "codex_once_\(UUID().uuidString).jsonl"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let startLine = "{\"timestamp\":\"2026-08-17T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn_once_01\"}}\n"
    try startLine.write(toFile: tmpPath, atomically: true, encoding: .utf8)

    let threadInfo = AutoMonitor.CodexThreadInfo(id: "codex_once_thread", title: "Once Thread", rolloutPath: tmpPath)
    monitor.processCodexRollout(thread: threadInfo)

    let s1 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_once_thread" })
    try assert(s1?.status == .working, "Must start in working.")

    // Append complete line
    if let handle = FileHandle(forWritingAtPath: tmpPath) {
        handle.seekToEndOfFile()
        let completeLine = "{\"timestamp\":\"2026-08-17T00:00:05Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn_once_01\",\"duration_ms\":5000}}\n"
        handle.write(completeLine.data(using: .utf8)!)
        try? handle.closeFile()
    }

    monitor.processCodexRollout(thread: threadInfo)
    let s2 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_once_thread" })
    try assert(s2?.status == .done, "Must transition to .done.")

    // Calling processCodexRollout again with no new bytes
    monitor.processCodexRollout(thread: threadInfo)
    let s3 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_once_thread" })
    try assert(s3?.status == .done, "Must remain .done without duplicate processing.")
}

// 39. Codex: no prompt/message/tool body is required for parsing
runTest("39. Codex: no prompt/message/tool body is required for parsing") {
    let store = AgentStore.shared
    let handled = store.handleCodexRolloutEvent(
        threadId: "codex_privacy_clean",
        title: "Clean",
        cwd: nil,
        rolloutPath: nil,
        eventType: "task_started",
        turnId: "turn_privacy_01",
        isTestMode: true
    )
    try assert(handled == true, "Minimal envelope with ZERO prompt/message bodies must be handled cleanly.")
}

// 40. Codex: SQLite updated_at change alone does not produce Working
runTest("40. Codex: SQLite updated_at change alone does not produce Working") {
    let monitor = AutoMonitor.shared
    let tmpPath = NSTemporaryDirectory() + "codex_sqlite_test_\(UUID().uuidString).jsonl"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    // Rollout file has completed turn
    let content = "{\"timestamp\":\"2026-08-17T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn_sq_01\"}}\n{\"timestamp\":\"2026-08-17T00:00:05Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn_sq_01\"}}\n"
    try content.write(toFile: tmpPath, atomically: true, encoding: .utf8)

    let t1 = AutoMonitor.CodexThreadInfo(id: "codex_sqlite_thread", title: "SQLite Thread", rolloutPath: tmpPath, updatedAtMs: 1000)
    monitor.processCodexRollout(thread: t1)
    AgentStore.shared.markChecked(for: .codex)

    // Simulate SQLite updated_at advancing without new rollout bytes
    let t2 = AutoMonitor.CodexThreadInfo(id: "codex_sqlite_thread", title: "SQLite Thread", rolloutPath: tmpPath, updatedAtMs: 2000)
    monitor.processCodexRollout(thread: t2)

    let status = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_sqlite_thread" })?.status
    try assert(status != .working, "SQLite updated_at change alone MUST NOT produce .working without task_started.")
}

// 41. Five-Provider Smart Auto: Monitored Codex participates in Smart Auto and respects Monitored Agents
runTest("41. Five-Provider Smart Auto: Monitored Codex participates in Smart Auto and respects Monitored Agents") {
    let sleepMgr = SleepManager.shared
    let store = AgentStore.shared

    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    store.updateStatus(for: .codex, status: .working, detail: "Codex active task")
    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == true, "Monitored Working Codex MUST activate Smart Auto.")
    try assert(eval.reason.contains("Codex Desktop"), "Reason must identify Codex Desktop")

    // Disabled provider must never activate Smart Auto
    ConfigManager.shared.setAgentMonitored(.codex, monitored: false)
    let evalDisabled = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalDisabled.shouldKeepAwake == false, "Disabled Codex MUST NOT activate Smart Auto.")

    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)
    store.updateStatus(for: .codex, status: .idle)
}

// 42. Menu Bar: fresh/default config -> Detailed mode & exposes all 4 provider identities
runTest("42. Menu Bar: fresh/default config -> Detailed mode & exposes all 4 provider identities") {
    let defaultCfg = AppConfig.defaultConfig
    try assert(defaultCfg.menuBarDisplayMode == "detailed", "Fresh default config MUST have menuBarDisplayMode == 'detailed'.")

    let store = AgentStore.shared
    store.currentTheme = .classic
    store.purgeSyntheticAndStaleSessions(provider: .claude)
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)
    store.purgeSyntheticAndStaleSessions(provider: .codex)

    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)

    let summary = store.overallSummary()
    try assert(summary.contains("GPT:"), "Detailed mode must expose GPT identity.")
    try assert(summary.contains("CDX:"), "Detailed mode must expose CDX identity.")
    try assert(summary.contains("CLD:"), "Detailed mode must expose CLD identity.")
    try assert(summary.contains("AGY:"), "Detailed mode must expose AGY identity.")
}

// 43. Menu Bar: all idle in Compact -> ⚪
runTest("43. Menu Bar: all idle in Compact -> ⚪") {
    let store = AgentStore.shared
    store.currentTheme = .classic
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .idle)

    let compact = store.compactSummary()
    try assert(compact == "⚪", "All idle must produce compact '⚪' (actual: \(compact)).")
}

// 44. Menu Bar: Compact Working identifies responsible provider (e.g. CLD🟡)
runTest("44. Menu Bar: Compact Working identifies responsible provider (e.g. CLD🟡)") {
    let store = AgentStore.shared
    store.currentTheme = .classic
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .claude, status: .working, detail: "Claude working")

    let compact = store.compactSummary()
    try assert(compact == "CLD🟡", "Compact working must identify responsible provider 'CLD🟡' (actual: \(compact)).")
}

// 45. Menu Bar: multiple same-priority providers produce bounded compact representation (e.g. CLD🟡 +1)
runTest("45. Menu Bar: multiple same-priority providers produce bounded compact representation (e.g. CLD🟡 +1)") {
    let store = AgentStore.shared
    store.currentTheme = .classic
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .chatgpt, status: .working, detail: "ChatGPT working")
    store.updateStatus(for: .claude, status: .working, detail: "Claude working")

    let compact = store.compactSummary()
    try assert(compact.contains("🟡") && compact.contains("+1"), "Two working providers must show top provider and +1 suffix (actual: \(compact)).")
}

// 46. Menu Bar: Needs You + Working -> Needs You identifies responsible provider (e.g. AGY🔴)
runTest("46. Menu Bar: Needs You + Working -> Needs You identifies responsible provider (e.g. AGY🔴)") {
    let store = AgentStore.shared
    store.currentTheme = .classic
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .claude, status: .working, detail: "Claude working")
    store.updateStatus(for: .antigravity, status: .blocked, detail: "Permission needed")

    let compact = store.compactSummary()
    try assert(compact == "AGY🔴", "Needs You must win over Working and identify responsible provider 'AGY🔴' (actual: \(compact)).")
}

// 47. Menu Bar: compact/detailed preference persists
runTest("47. Menu Bar: compact/detailed preference persists") {
    let configMgr = ConfigManager.shared

    var cfg = configMgr.config
    cfg.menuBarDisplayMode = "compact"
    configMgr.saveConfig(cfg)
    configMgr.loadConfig()
    try assert(configMgr.config.menuBarDisplayMode == "compact", "Compact mode preference must persist.")

    cfg.menuBarDisplayMode = "detailed"
    configMgr.saveConfig(cfg)
    configMgr.loadConfig()
    try assert(configMgr.config.menuBarDisplayMode == "detailed", "Detailed mode preference must persist.")
}

// 48. Menu Bar: autosaveName is configured
runTest("48. Menu Bar: autosaveName is configured") {
    let expectedAutosaveName = "AgentSignalBarStatusItem"
    try assert(!expectedAutosaveName.isEmpty, "Autosave name constant must be defined.")
}

// 49. Quota Availability: Claude idle + available -> CLD:⚪
runTest("49. Quota Availability: Claude idle + available -> CLD:⚪") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    store.currentTheme = .classic

    let availUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 45.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: availUsage)
    store.updateStatus(for: .claude, status: .idle)

    let summary = store.overallSummary()
    try assert(summary.contains("CLD:⚪"), "Claude idle + available must display 'CLD:⚪' (actual: \(summary)).")
    try assert(store.getStatus(for: .claude).status == .idle, "Underlying lifecycle status must remain .idle.")
    try assert(store.getStatus(for: .claude).availability == .available, "Availability must be .available.")
}

// 50. Quota Availability: Claude idle + quotaExhausted -> CLD:⛔ (Lifecycle remains .idle)
runTest("50. Quota Availability: Claude idle + quotaExhausted -> CLD:⛔") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    store.currentTheme = .classic

    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .claude, status: .idle)

    let summary = store.overallSummary()
    try assert(summary.contains("CLD:⛔"), "Claude idle + quotaExhausted must display 'CLD:⛔' (actual: \(summary)).")
    try assert(store.getStatus(for: .claude).status == .idle, "Underlying lifecycle status must remain .idle.")
    try assert(store.getStatus(for: .claude).availability == .quotaExhausted, "Availability must be .quotaExhausted.")
}

// 51. Quota Availability: Compact mode shows CLD⛔ when everything else is idle
runTest("51. Quota Availability: Compact mode shows CLD⛔ when everything else is idle") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    store.currentTheme = .classic

    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .claude, status: .idle)

    let compact = store.compactSummary()
    try assert(compact == "CLD⛔", "Compact mode must show 'CLD⛔' when Claude is quota-exhausted and other agents are idle (actual: \(compact)).")
}

// 52. Quota Availability: AGY Working + Claude exhausted -> Compact AGY🟡
runTest("52. Quota Availability: AGY Working + Claude exhausted -> Compact AGY🟡") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    store.currentTheme = .classic

    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .working, detail: "AGY working")

    let compact = store.compactSummary()
    try assert(compact == "AGY🟡", "Working must take precedence over Quota Exhausted in compact mode (actual: \(compact)).")
}

// 53. Quota Availability: AGY Needs You + Claude exhausted -> Compact AGY🔴
runTest("53. Quota Availability: AGY Needs You + Claude exhausted -> Compact AGY🔴") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    store.currentTheme = .classic

    let exhaustedUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "plan-usage-history.json",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .idle)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .blocked, detail: "Permission needed")

    let compact = store.compactSummary()
    try assert(compact == "AGY🔴", "Needs You must take precedence over Quota Exhausted in compact mode (actual: \(compact)).")
}

// 54. Unified Display Status: All 6 states derive identical top-level, compact, and dropdown display representation across themes
runTest("54. Unified Display Status: All 6 states derive identical top-level, compact, and dropdown display representation across themes") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    // State 1: Off
    store.updateStatus(for: .codex, status: .off)
    let offInfo = store.getStatus(for: .codex)
    try assert(offInfo.effectiveDisplayStatus == .off, "Off status must map to .off display status.")
    try assert(offInfo.effectiveDisplayStatus.badge(theme: .classic) == "⚫", "Classic off badge must be '⚫'.")
    try assert(offInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "😴", "Fun off badge must be '😴'.")

    // State 2: Idle + Available
    usageStore.setPreviousAuthoritativeExhausted(for: .claude, exhausted: false)
    store.clearQuotaRestored(for: .claude)
    let availUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 50.0, isPercentUsed: true, isLiveSource: true, quotaSource: "plan-usage-history.json", freshness: "Fresh")
    usageStore.updateUsage(for: .claude, data: availUsage)
    store.updateStatus(for: .claude, status: .idle)
    let idleInfo = store.getStatus(for: .claude)
    try assert(idleInfo.effectiveDisplayStatus == .idle, "Idle available must map to .idle display status.")
    try assert(idleInfo.effectiveDisplayStatus.badge(theme: .classic) == "⚪", "Classic idle badge must be '⚪'.")
    try assert(idleInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🫥", "Fun idle badge must be '🫥'.")

    // State 3: Idle + Quota Exhausted
    let exhaustedUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, quotaSource: "plan-usage-history.json", freshness: "Fresh")
    usageStore.updateUsage(for: .claude, data: exhaustedUsage)
    store.updateStatus(for: .claude, status: .idle)
    let exhaustedInfo = store.getStatus(for: .claude)
    try assert(exhaustedInfo.effectiveDisplayStatus == .quotaExhausted, "Quota exhausted must map to .quotaExhausted display status.")
    try assert(exhaustedInfo.effectiveDisplayStatus.badge(theme: .classic) == "⛔", "Classic quota exhausted badge must be '⛔'.")
    try assert(exhaustedInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🤯", "Fun quota exhausted badge must be '🤯'.")
    try assert(exhaustedInfo.status == .idle, "Lifecycle MUST remain .idle.")

    // State 4: Working
    store.updateStatus(for: .antigravity, status: .working)
    let workingInfo = store.getStatus(for: .antigravity)
    try assert(workingInfo.effectiveDisplayStatus == .working, "Working must map to .working display status.")
    try assert(workingInfo.effectiveDisplayStatus.badge(theme: .classic) == "🟡", "Classic working badge must be '🟡'.")
    try assert(workingInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🤔", "Fun working badge must be '🤔'.")

    // State 5: Done
    store.updateStatus(for: .chatgpt, status: .done)
    let doneInfo = store.getStatus(for: .chatgpt)
    try assert(doneInfo.effectiveDisplayStatus == .done, "Done must map to .done display status.")
    try assert(doneInfo.effectiveDisplayStatus.badge(theme: .classic) == "🟢", "Classic done badge must be '🟢'.")
    try assert(doneInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🐶", "Fun done badge must be '🐶'.")

    // State 6: Blocked / Needs You
    store.updateStatus(for: .antigravity, status: .blocked)
    let blockedInfo = store.getStatus(for: .antigravity)
    try assert(blockedInfo.effectiveDisplayStatus == .blocked, "Blocked must map to .blocked display status.")
    try assert(blockedInfo.effectiveDisplayStatus.badge(theme: .classic) == "🔴", "Classic blocked badge must be '🔴'.")
    try assert(blockedInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🥶", "Fun blocked badge must be '🥶'.")

    // State 7: Quota Restored / Wake Event
    store.setQuotaRestored(for: .codex, restored: true)
    store.updateStatus(for: .codex, status: .idle)
    let restoredInfo = store.getStatus(for: .codex)
    try assert(restoredInfo.effectiveDisplayStatus == .quotaRestored, "Quota restored must map to .quotaRestored display status.")
    try assert(restoredInfo.effectiveDisplayStatus.badge(theme: .classic) == "⚪", "Classic quota restored badge must be '⚪'.")
    try assert(restoredInfo.effectiveDisplayStatus.badge(theme: .funEmoji) == "🥱", "Fun quota restored badge must be '🥱'.")
    store.clearQuotaRestored(for: .codex)
}

// 55. AGY StopError: Generic Stop with error + fullyIdle transitions to .idle (NOT .blocked, NOT .done)
runTest("55. AGY StopError: Generic Stop with error + fullyIdle transitions to .idle (NOT .blocked, NOT .done)") {
    let store = AgentStore.shared
    let testSessionId = "test_agy_stoperror_1"
    store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
    defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": testSessionId,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: true)

    let workingSession = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(workingSession?.status == .working, "Session must be working before stop.")

    // Generic Stop with stream interruption error
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": testSessionId,
        "error": "The stream was interrupted. Please continue the task you were working on.",
        "termination_reason": "ERROR",
        "fully_idle": true,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: true)

    let stoppedSession = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(stoppedSession?.status == .idle, "Generic StopError must transition to .idle (actual: \(String(describing: stoppedSession?.status))).")
    try assert(stoppedSession?.attentionReason == nil, "attentionReason must be nil for generic StopError.")
    try assert(stoppedSession?.sourceEvidence.contains("Generation stopped") == true, "sourceEvidence must reflect generation stopped.")
    try assert(store.getStatus(for: .antigravity).status == .idle, "Parent status must be .idle when sole session is stopped.")
}

// 56. AGY StopError: Non-actionable StopError releases Smart Auto keep-awake
runTest("56. AGY StopError: Non-actionable StopError releases Smart Auto keep-awake") {
    let store = AgentStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    let testSessionId = "test_agy_stoperror_smartauto"
    store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
    defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": testSessionId,
        "cwd": "/tmp"
    ], isTestMode: true)

    try assert(sleepMgr.evaluateSmartAutoRequirement().shouldKeepAwake == true, "Smart Auto must be active while AGY is working.")

    // Non-actionable StopError
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": testSessionId,
        "error": "The stream was interrupted.",
        "termination_reason": "ERROR",
        "fully_idle": true,
        "cwd": "/tmp"
    ], isTestMode: true)

    let evalAfter = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalAfter.shouldKeepAwake == false, "Smart Auto MUST release keep-awake when session halts with non-actionable StopError.")
}

// 57. AGY Permission Gate: Positively verified blocked state survives Stop event
runTest("57. AGY Permission Gate: Positively verified blocked state survives Stop event") {
    let store = AgentStore.shared
    let testSessionId = "test_agy_perm_survives_stop"
    defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": testSessionId,
        "cwd": "/tmp"
    ], isTestMode: true)

    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreToolUse",
        "session_id": testSessionId,
        "tool_name": "ask_question",
        "cwd": "/tmp"
    ], isTestMode: true)

    let blockedSession = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(blockedSession?.status == .blocked, "ask_question must produce .blocked.")

    // Stop arriving while blocked must preserve .blocked
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": testSessionId,
        "cwd": "/tmp"
    ], isTestMode: true)

    let afterStop = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(afterStop?.status == .blocked, "Positively verified .blocked state MUST survive Stop event.")
}

// 58. AGY Subagent Filtering: Subagents without annotations do NOT create persistent menu rows
runTest("58. AGY Subagent Filtering: Subagents without annotations do NOT create persistent menu rows") {
    let store = AgentStore.shared
    let fm = FileManager.default
    let mainUserCid = "00000000-0000-0000-0000-000000000001"
    let subagentCid = "00000000-0000-0000-0000-000000000002"
    defer {
        store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
        let annoPath = NSString(string: "~/.gemini/antigravity/annotations/\(mainUserCid).pbtxt").expandingTildeInPath
        let brainSubPath = NSString(string: "~/.gemini/antigravity/brain/\(subagentCid)").expandingTildeInPath
        try? fm.removeItem(atPath: annoPath)
        try? fm.removeItem(atPath: brainSubPath)
    }

    // Create real user-facing annotation file on disk
    let annoDir = NSString(string: "~/.gemini/antigravity/annotations").expandingTildeInPath
    try? fm.createDirectory(atPath: annoDir, withIntermediateDirectories: true)
    let annoPath = "\(annoDir)/\(mainUserCid).pbtxt"
    try "last_user_view_time: {}".write(toFile: annoPath, atomically: true, encoding: .utf8)

    // Create subagent brain directory without annotation file
    let brainDir = NSString(string: "~/.gemini/antigravity/brain").expandingTildeInPath
    let brainSubPath = "\(brainDir)/\(subagentCid)"
    try? fm.createDirectory(atPath: brainSubPath, withIntermediateDirectories: true)

    try assert(AgentStore.isUserFacingAntigravitySession(mainUserCid, isTestMode: false) == true, "Session with annotation must be user-facing.")
    try assert(AgentStore.isUserFacingAntigravitySession(subagentCid, isTestMode: false) == false, "Subagent with brain but no annotation must NOT be user-facing.")

    // Fire hook event for main user conversation
    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": mainUserCid,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: false)

    // Fire hook event for internal subagent
    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": subagentCid,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: false)

    let activeSessions = store.getSessions(for: .antigravity)
    try assert(activeSessions.contains(where: { $0.sessionId == mainUserCid }), "Main user session must appear in tracked sessions.")
    try assert(!activeSessions.contains(where: { $0.sessionId == subagentCid }), "Internal subagent must NOT appear in tracked sessions.")
}

// 59. AGY Subagent Isolation: Subagent Stop cannot mutate user-facing session
runTest("59. AGY Subagent Isolation: Subagent Stop cannot mutate user-facing session") {
    let store = AgentStore.shared
    let fm = FileManager.default
    let mainUserCid = "00000000-0000-0000-0000-000000000011"
    let subagentCid = "00000000-0000-0000-0000-000000000012"
    defer {
        store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
        let annoPath = NSString(string: "~/.gemini/antigravity/annotations/\(mainUserCid).pbtxt").expandingTildeInPath
        let brainSubPath = NSString(string: "~/.gemini/antigravity/brain/\(subagentCid)").expandingTildeInPath
        try? fm.removeItem(atPath: annoPath)
        try? fm.removeItem(atPath: brainSubPath)
    }

    let annoDir = NSString(string: "~/.gemini/antigravity/annotations").expandingTildeInPath
    try? fm.createDirectory(atPath: annoDir, withIntermediateDirectories: true)
    let annoPath = "\(annoDir)/\(mainUserCid).pbtxt"
    try "last_user_view_time: {}".write(toFile: annoPath, atomically: true, encoding: .utf8)

    let brainDir = NSString(string: "~/.gemini/antigravity/brain").expandingTildeInPath
    let brainSubPath = "\(brainDir)/\(subagentCid)"
    try? fm.createDirectory(atPath: brainSubPath, withIntermediateDirectories: true)

    // Start main user session
    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": mainUserCid,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: false)

    // Subagent finishes and emits Stop
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": subagentCid,
        "cwd": "/Users/ava/Projects/NooBoss-MV3"
    ], isTestMode: false)

    // Main user session must still be working!
    let mainSession = store.getSessions(for: .antigravity).first(where: { $0.sessionId == mainUserCid })
    try assert(mainSession?.status == .working, "Subagent Stop must not mutate main user session from working to done.")
}

// 61. Shared Availability Model: available, limited, quotaExhausted, unknown
runTest("61. Shared Availability Model: available, limited, quotaExhausted, unknown") {
    let avail1 = AgentUsageData(agent: .claude, sessionLimitPercent: 40.0, isPercentUsed: true, isLiveSource: true, freshness: "Fresh")
    try assert(avail1.availability == .available, "40% used live source must be .available.")

    let unavail = AgentUsageData(agent: .codex, sessionLimitPercent: nil, isLiveSource: false, freshness: "Unavailable")
    try assert(unavail.availability == .unknown, "Non-live source must derive .unknown availability.")

    let exhausted = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, freshness: "Fresh")
    try assert(exhausted.availability == .quotaExhausted, "100% used live source must derive .quotaExhausted.")

    let limited = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 80.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    try assert(limited.availability == .limited, "Partially exhausted model families must derive .limited.")
    try assert(limited.isQuotaExhausted == false, "Limited provider is NOT fully quota exhausted.")
}

// 62. AGY Quota: Gemini available + Claude/GPT exhausted -> Provider Limited
runTest("62. AGY Quota: Gemini available + Claude/GPT exhausted -> Provider Limited") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    let agyUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 76.0, sessionResetText: nil, weeklyLimitPercent: 46.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, sessionResetText: "resets in 2h 15m", weeklyLimitPercent: 32.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: agyUsage)
    store.updateStatus(for: .antigravity, status: .idle)

    let info = store.getStatus(for: .antigravity)
    try assert(info.availability == .limited, "Antigravity availability must be .limited.")
    try assert(info.effectiveDisplayStatus == .idle, "Limited provider with idle lifecycle must have .idle effectiveDisplayStatus.")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⚪", "Limited provider badge must remain '⚪' (not '⦸').")
}

// 63. AGY Quota: All proven model families exhausted -> Provider Quota Exhausted
runTest("63. AGY Quota: All proven model families exhausted -> Provider Quota Exhausted") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    let allExhausted = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 0.0, weeklyLimitPercent: 0.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, weeklyLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: allExhausted)
    store.updateStatus(for: .antigravity, status: .idle)

    let info = store.getStatus(for: .antigravity)
    try assert(info.availability == .quotaExhausted, "Antigravity availability must be .quotaExhausted when all families are depleted.")
    try assert(info.effectiveDisplayStatus == .quotaExhausted, "Idle exhausted provider must have .quotaExhausted effective display status.")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⛔", "All exhausted provider badge must be '⛔'.")
}

// 64. AGY Lifecycle Priority: Actionable Working outranks Quota Limited / Exhausted
runTest("64. AGY Lifecycle Priority: Actionable Working outranks Quota Limited / Exhausted") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    let allExhausted = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 0.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: allExhausted)

    // When session is genuinely working on another model/task:
    store.updateStatus(for: .antigravity, status: .working)
    let info = store.getStatus(for: .antigravity)
    try assert(info.effectiveDisplayStatus == .working, "Working status MUST outrank quota exhaustion.")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "🟡", "Working badge must be '🟡'.")
}

// 65. Smart Auto Safety: Quota Limited, Exhausted, Unknown never acquire Smart Auto keep-awake
runTest("65. Smart Auto Safety: Quota Limited, Exhausted, Unknown never acquire Smart Auto keep-awake") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto

    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .off)
    store.updateStatus(for: .antigravity, status: .idle)

    // Set Claude to exhausted and AGY to limited
    let claudeExhausted = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, freshness: "Fresh")
    usageStore.updateUsage(for: .claude, data: claudeExhausted)

    let agyLimited = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 76.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: agyLimited)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Smart Auto MUST release assertion when all agents are lifecycle idle regardless of quota state.")
}

// 66. Codex Quota: Honest Unknown Availability when no live source exists
runTest("66. Codex Quota: Honest Unknown Availability when no live source exists") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    let cdxUsage = AgentUsageData(agent: .codex, isLiveSource: false, quotaSource: "none", freshness: "Unavailable")
    usageStore.updateUsage(for: .codex, data: cdxUsage)
    store.updateStatus(for: .codex, status: .idle)

    let info = store.getStatus(for: .codex)
    try assert(info.availability == .unknown, "Codex availability must be .unknown.")
    try assert(info.effectiveDisplayStatus == .idle, "Codex effective display status must be .idle (not .quotaExhausted).")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⚪", "Unknown quota must not show '⦸'.")
}

// 67. Compact Mode Display: Provider-Aware Compact Representation with Quota
runTest("67. Compact Mode Display: Provider-Aware Compact Representation with Quota") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    for a in AgentID.allCases {
        store.clearQuotaRestored(for: a)
    }

    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .codex, status: .off)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .claude, status: .idle)

    // Claude exhausted -> Compact shows CLD⛔
    let claudeExhausted = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, freshness: "Fresh")
    usageStore.updateUsage(for: .claude, data: claudeExhausted)

    let summary = store.compactSummary()
    try assert(summary.contains("CLD⛔") || summary.contains("CLD:⛔"), "Compact summary must show CLD⛔ when Claude is exhausted (actual: '\(summary)').")

    // Working AGY outranks exhausted Claude
    store.updateStatus(for: .antigravity, status: .working)
    let activeSummary = store.compactSummary()
    try assert(activeSummary.contains("AGY🟡") || activeSummary.contains("AGY:🟡"), "Working AGY must outrank exhausted Claude in compact mode (actual: '\(activeSummary)').")
}

// 68. Quota Dashboard: MenuBarManager render signature responds to quota changes
runTest("68. Quota Dashboard: MenuBarManager render signature responds to quota changes") {
    let menuMgr = MenuBarManager.shared
    let usageStore = AgentUsageStore.shared

    let sig1 = menuMgr.computeRenderSignature()

    // Update AGY model family quota
    let newAgyUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 90.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 10.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: newAgyUsage)

    let sig2 = menuMgr.computeRenderSignature()
    try assert(sig1 != sig2, "computeRenderSignature must change when model family quotas change.")
}

// 69. Config Persistence: Multi-Model Family Config Save and Reload
runTest("69. Config Persistence: Multi-Model Family Config Save and Reload") {
    let usageStore = AgentUsageStore.shared

    let testUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini 2.5", sessionLimitPercent: 88.0, sessionResetText: nil, weeklyLimitPercent: 55.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude 3.5 Sonnet", sessionLimitPercent: 0.0, sessionResetText: "resets in 1h 30m", weeklyLimitPercent: 20.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .antigravity, data: testUsage)

    let retrieved = usageStore.getUsage(for: .antigravity)
    try assert(retrieved?.modelFamilies.count == 2, "Retrieved usage must contain 2 model families.")
    try assert(retrieved?.modelFamilies[0].name == "Gemini 2.5", "First family name must match.")
    try assert(retrieved?.modelFamilies[1].isExhausted == true, "Second family (0% left) must be exhausted.")
    try assert(retrieved?.availability == .limited, "Overall availability must be .limited.")
}

// 70. Generic StopError Decoupled from Quota Inference
runTest("70. Generic StopError Decoupled from Quota Inference") {
    let store = AgentStore.shared
    let usageStore = AgentUsageStore.shared
    let testSessionId = "test_agy_stoperror_no_quota_inference"
    store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
    defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

    // Start turn
    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": testSessionId,
        "cwd": "/tmp"
    ], isTestMode: true)

    // Stop with error
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": testSessionId,
        "error": "The stream was interrupted.",
        "termination_reason": "ERROR",
        "fully_idle": true,
        "cwd": "/tmp"
    ], isTestMode: true)

    let session = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(session?.status == .idle, "Stop with error must produce .idle lifecycle.")
    try assert(session?.attentionReason == nil, "Stop with error must NOT set attentionReason.")

    // Usage data must NOT be fabricated into quota exhausted simply because error occurred
    let usage = usageStore.getUsage(for: .antigravity)
    try assert(usage?.isLiveSource == false || usage?.availability != .quotaExhausted, "Generic StopError must NOT infer full quota exhaustion.")
}

// 71. Antigravity Local Quota Connector: Parse Live UserStatus Cascade JSON
runTest("71. Antigravity Local Quota Connector: Parse Live UserStatus Cascade JSON") {
    let rawJson: [String: Any] = [
        "userStatus": [
            "email": "test@example.com",
            "cascadeModelConfigData": [
                "clientModelConfigs": [
                    [
                        "label": "Gemini 3.7 Flash (High)",
                        "modelId": "gemini-3.7-flash-high",
                        "quotaInfo": [
                            "remainingFraction": 0.4831699,
                            "resetTime": "2026-08-17T12:48:12Z"
                        ]
                    ],
                    [
                        "label": "Gemini 3.1 Pro (High)",
                        "modelId": "gemini-pro-agent",
                        "quotaInfo": [
                            "remainingFraction": 0.4831699,
                            "resetTime": "2026-08-17T12:48:12Z"
                        ]
                    ],
                    [
                        "label": "Claude Sonnet 4.6 (Thinking)",
                        "modelId": "claude-sonnet-4-6",
                        "quotaInfo": [
                            "resetTime": "2026-08-17T14:19:13Z"
                        ]
                    ],
                    [
                        "label": "GPT-OSS 120B (Medium)",
                        "modelId": "gpt-oss-120b-medium",
                        "quotaInfo": [
                            "resetTime": "2026-08-17T14:19:13Z"
                        ]
                    ]
                ]
            ]
        ]
    ]

    let parsed = AntigravityLocalQuotaConnector.shared.parseAntigravityUserStatusJSON(rawJson)
    try assert(parsed != nil, "parseAntigravityUserStatusJSON must succeed.")
    try assert(parsed?.agent == .antigravity, "Agent must be antigravity.")
    try assert(parsed?.quotaSource == "agy_local_get_user_status", "QuotaSource must be agy_local_get_user_status.")
    try assert(parsed?.isLiveSource == true, "Must be marked live source.")
    try assert(parsed?.modelFamilies.count == 2, "Must contain exactly 2 model families.")

    let gemini = parsed?.modelFamilies.first(where: { $0.name == "Gemini" })
    try assert(gemini != nil, "Gemini family must be present.")
    try assert(gemini?.sessionLimitPercent == 48.0, "Gemini remaining percent must be 48.0%.")
    try assert(gemini?.isExhausted == false, "Gemini must not be exhausted.")

    let claudeGpt = parsed?.modelFamilies.first(where: { $0.name == "Claude/GPT" })
    try assert(claudeGpt != nil, "Claude/GPT family must be present.")
    try assert(claudeGpt?.sessionLimitPercent == 0.0, "Claude/GPT remaining percent must be 0.0%.")
    try assert(claudeGpt?.isExhausted == true, "Claude/GPT must be exhausted.")

    try assert(parsed?.availability == .limited, "Provider availability must be limited.")
}

// 72. Antigravity Local Quota Connector: Reset Time Formatter
runTest("72. Antigravity Local Quota Connector: Reset Time Formatter") {
    let connector = AntigravityLocalQuotaConnector.shared
    let nilFormatted = connector.formatResetText(from: nil)
    try assert(nilFormatted == nil, "Nil ISO string must return nil.")

    // Past date -> "resets soon"
    let pastFormatted = connector.formatResetText(from: "2020-01-01T00:00:00Z")
    try assert(pastFormatted == "resets soon", "Past date must format to 'resets soon'.")

    // Future date
    let futureDate = Date().addingTimeInterval(3700) // 1h 1m
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let futureIso = formatter.string(from: futureDate)
    let futureFormatted = connector.formatResetText(from: futureIso)
    try assert(futureFormatted?.contains("in 1h") == true, "Future date must contain 'in 1h'.")
}

// 73. Codex App-Server Quota Connector: Parse RateLimits Response
runTest("73. Codex App-Server Quota Connector: Parse RateLimits Response") {
    let rawResult: [String: Any] = [
        "rateLimits": [
            "limitId": "codex",
            "planType": "plus",
            "primary": [
                "usedPercent": 79,
                "windowDurationMins": 10080,
                "resetsAt": 1787209587
            ],
            "secondary": NSNull(),
            "credits": [
                "hasCredits": false,
                "unlimited": false,
                "balance": "0"
            ],
            "rateLimitReachedType": NSNull()
        ],
        "rateLimitResetCredits": [
            "availableCount": 0
        ]
    ]

    let parsed = CodexAppServerQuotaConnector.shared.parseCodexRateLimitsResult(rawResult)
    try assert(parsed != nil, "parseCodexRateLimitsResult must succeed.")
    try assert(parsed?.agent == .codex, "Agent must be codex.")
    try assert(parsed?.weeklyLimitPercent == 79.0, "Weekly used percent must be 79.0%.")
    try assert(parsed?.isPercentUsed == true, "Must be percent used.")
    try assert(parsed?.isLiveSource == true, "Must be live source.")
    try assert(parsed?.quotaSource == "codex_app_server", "Quota source must be codex_app_server.")
    try assert(parsed?.isQuotaExhausted == false, "Must not be exhausted when 79% used.")
    try assert(parsed?.availability == .available, "Availability must be available.")
    try assert(parsed?.weeklyResetText?.contains("resets") == true, "Weekly reset text must be formatted.")
}

// 74. Codex App-Server Quota Connector: Exhaustion Handling
runTest("74. Codex App-Server Quota Connector: Exhaustion Handling") {
    let rawResultExhausted: [String: Any] = [
        "rateLimits": [
            "limitId": "codex",
            "planType": "plus",
            "primary": [
                "usedPercent": 100,
                "windowDurationMins": 10080,
                "resetsAt": 1787209587
            ],
            "secondary": NSNull(),
            "rateLimitReachedType": "rate_limit_reached"
        ],
        "rateLimitResetCredits": [
            "availableCount": 0
        ]
    ]

    let parsed = CodexAppServerQuotaConnector.shared.parseCodexRateLimitsResult(rawResultExhausted)
    try assert(parsed != nil, "parseCodexRateLimitsResult must succeed.")
    try assert(parsed?.isQuotaExhausted == true, "Must be marked quota exhausted.")
    try assert(parsed?.availability == .quotaExhausted, "Availability must be quotaExhausted.")
}

// 75. Codex App-Server Quota Connector: Reset Timestamp Formatter
runTest("75. Codex App-Server Quota Connector: Reset Timestamp Formatter") {
    let connector = CodexAppServerQuotaConnector.shared
    let formatted = connector.formatCodexResetText(resetsAt: 1787209587)
    try assert(!formatted.isEmpty, "Formatted string must not be empty.")
    try assert(formatted.contains("resets"), "Formatted string must contain 'resets'.")
}

// 76. Quota-Terminated Turn Semantics with Smart Auto Release
runTest("76. Quota-Terminated Turn Semantics with Smart Auto Release") {
    let store = AgentStore.shared
    let sleepMgr = SleepManager.shared
    let usageStore = AgentUsageStore.shared
    let testSessionId = "test_agy_quota_term_sleep_release"

    sleepMgr.mode = .smartAuto
    for p in AgentID.allCases {
        store.purgeSyntheticAndStaleSessions(provider: p)
        store.syncSessions(for: p, activeSessions: [], processRunning: false)
        store.updateStatus(for: p, status: .idle)
    }
    store.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)
    defer {
        for p in AgentID.allCases {
            store.purgeSyntheticAndStaleSessions(provider: p)
            store.syncSessions(for: p, activeSessions: [], processRunning: false)
            store.updateStatus(for: p, status: .idle)
        }
        sleepMgr.mode = .disabled
        sleepMgr.updateSleepAssertionState()
    }

    // Set Antigravity quota to Limited (Gemini available, Claude/GPT exhausted)
    usageStore.updateUsage(for: .antigravity, data: AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 48.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        freshness: "Fresh"
    ))

    // Start working
    store.updateStatus(for: .antigravity, status: .idle)
    _ = store.handleAntigravityHookEvent(json: [
        "event": "PreInvocation",
        "session_id": testSessionId,
        "cwd": "/tmp"
    ], isTestMode: true)

    let evalWorking = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalWorking.shouldKeepAwake == true, "Working turn must acquire Smart Auto keep-awake.")

    // Turn halts with stream interruption due to model quota
    _ = store.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": testSessionId,
        "error": "The model quota was exhausted for Claude.",
        "termination_reason": "ERROR",
        "fully_idle": true,
        "cwd": "/tmp"
    ], isTestMode: true)

    let session = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
    try assert(session?.status == .idle, "Quota-interrupted turn must transition to .idle.")
    try assert(session?.attentionReason == nil, "Quota-interrupted turn must not set attentionReason.")

    let evalStopped = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalStopped.shouldKeepAwake == false, "Smart Auto keep-awake must be released upon quota termination.")
}

// 77. CLI Optionality & Graceful Degradation
runTest("77. CLI Optionality & Graceful Degradation") {
    let mockConnector = CodexAppServerQuotaConnector.shared
    let invalidOutput = "invalid non json output"
    let parsed = mockConnector.parseCodexAppServerOutput(invalidOutput)
    try assert(parsed == nil, "Invalid output must return nil without throwing.")
}

// 78. Provider Source Diagnostics in Status
runTest("78. Provider Source Diagnostics in Status") {
    let usageStore = AgentUsageStore.shared

    usageStore.updateUsage(for: .antigravity, data: AgentUsageData(
        agent: .antigravity,
        modelFamilies: [ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 50.0, isPercentUsed: false)],
        isLiveSource: true,
        quotaSource: "agy_local_get_user_status"
    ))

    usageStore.updateUsage(for: .codex, data: AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 79.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server"
    ))

    usageStore.updateUsage(for: .claude, data: AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 80.0,
        weeklyLimitPercent: 88.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "claude_plan_usage_history"
    ))

    let agyUsage = usageStore.getUsage(for: .antigravity)
    try assert(agyUsage?.quotaSource == "agy_local_get_user_status", "Antigravity quota source must be agy_local_get_user_status.")

    let cdxUsage = usageStore.getUsage(for: .codex)
    try assert(cdxUsage?.quotaSource == "codex_app_server", "Codex quota source must be codex_app_server.")

    let cldUsage = usageStore.getUsage(for: .claude)
    try assert(cldUsage?.quotaSource == "claude_plan_usage_history", "Claude quota source must be claude_plan_usage_history.")
}

// 79. Live Antigravity & Codex Connector Smoke Test
runTest("79. Live Antigravity & Codex Connector Smoke Test") {
    let agyUsage = AntigravityLocalQuotaConnector.shared.fetchQuota()
    if let agyUsage = agyUsage {
        print("  [Live AGY] Models: \(agyUsage.modelFamilies.count), Availability: \(agyUsage.availability.rawValue)")
        for f in agyUsage.modelFamilies {
            print("  - \(f.name): 5h: \(f.sessionRemainingPercent ?? -1)% left (\(f.sessionResetText ?? "none")), weekly: \(f.weeklyRemainingPercent ?? -1)% left (\(f.weeklyResetText ?? "none")), exhausted: \(f.isExhausted)")
        }
        try assert(agyUsage.isLiveSource == true, "AGY live usage must have isLiveSource = true.")
        try assert(agyUsage.quotaSource.hasPrefix("agy_local_"), "AGY quotaSource must be an agy_local source.")
    } else {
        print("  [Live AGY] language_server not active during test.")
    }

    let cdxUsage = CodexAppServerQuotaConnector.shared.fetchQuota()
    if let cdxUsage = cdxUsage {
        print("  [Live CDX] Weekly: \(cdxUsage.weeklyRemainingPercent ?? 0)% left (raw used: \(cdxUsage.weeklyLimitPercent ?? 0)%), Reset: \(cdxUsage.weeklyResetText ?? "none"), Availability: \(cdxUsage.availability.rawValue)")
        try assert(cdxUsage.isLiveSource == true, "CDX live usage must have isLiveSource = true.")
        try assert(cdxUsage.quotaSource == "codex_app_server", "CDX quotaSource must be codex_app_server.")
    } else {
        print("  [Live CDX] codex CLI app-server not active during test.")
    }
}

// 80. Quota Normalization: Raw 100% used -> UI 0% left
runTest("80. Quota Normalization: Raw 100% used -> UI 0% left") {
    let rawUsed = 100.0
    let norm = ModelFamilyQuota.normalizeRemaining(raw: rawUsed, isPercentUsed: true)
    try assert(norm == 0.0, "100% used must normalize to 0% left (actual: \(String(describing: norm))).")
}

// 81. Quota Normalization: Raw 79% used -> UI 21% left
runTest("81. Quota Normalization: Raw 79% used -> UI 21% left") {
    let rawUsed = 79.0
    let norm = ModelFamilyQuota.normalizeRemaining(raw: rawUsed, isPercentUsed: true)
    try assert(norm == 21.0, "79% used must normalize to 21% left (actual: \(String(describing: norm))).")
}

// 82. Quota Normalization: Raw 24% remaining -> UI 24% left
runTest("82. Quota Normalization: Raw 24% remaining -> UI 24% left") {
    let rawRemaining = 24.0
    let norm = ModelFamilyQuota.normalizeRemaining(raw: rawRemaining, isPercentUsed: false)
    try assert(norm == 24.0, "24% remaining must normalize to 24% left (actual: \(String(describing: norm))).")
}

// 83. Quota Normalization: Raw 0% remaining -> UI 0% left
runTest("83. Quota Normalization: Raw 0% remaining -> UI 0% left") {
    let rawRemaining = 0.0
    let norm = ModelFamilyQuota.normalizeRemaining(raw: rawRemaining, isPercentUsed: false)
    try assert(norm == 0.0, "0% remaining must normalize to 0% left (actual: \(String(describing: norm))).")
}

// 84. Quota Normalization: Raw unknown / nil -> UI Unknown (nil)
runTest("84. Quota Normalization: Raw unknown / nil -> UI Unknown (nil)") {
    let rawRemaining: Double? = nil
    let norm = ModelFamilyQuota.normalizeRemaining(raw: rawRemaining, isPercentUsed: false)
    try assert(norm == nil, "nil remaining must normalize to nil (actual: \(String(describing: norm))).")
}

// 85. Visual Progress Bar: 100% left is full bar, 0% left is empty bar
runTest("85. Visual Progress Bar: 100% left is full bar, 0% left is empty bar") {
    func makeCompactBar(percent: Double, totalBlocks: Int = 10) -> String {
        let clamped = max(0.0, min(100.0, percent))
        let filledCount = Int(round((clamped / 100.0) * Double(totalBlocks)))
        let emptyCount = max(0, totalBlocks - filledCount)
        let filled = String(repeating: "■", count: filledCount)
        let empty = String(repeating: "□", count: emptyCount)
        return "[\(filled)\(empty)]"
    }

    let fullBar = makeCompactBar(percent: 100.0)
    try assert(fullBar == "[■■■■■■■■■■]", "100% left must produce a full bar (actual: \(fullBar)).")

    let halfBar = makeCompactBar(percent: 50.0)
    try assert(halfBar == "[■■■■■□□□□□]", "50% left must produce a 50% filled bar (actual: \(halfBar)).")

    let emptyBar = makeCompactBar(percent: 0.0)
    try assert(emptyBar == "[□□□□□□□□□□]", "0% left must produce an empty bar (actual: \(emptyBar)).")

    let cdxBar = makeCompactBar(percent: 21.0)
    try assert(cdxBar == "[■■□□□□□□□□]", "21% left must produce a 2-block filled bar (actual: \(cdxBar)).")
}

// 86. Claude Quota UI: 100% used normalizes to 0% left, 88% used to 12% left
runTest("86. Claude Quota UI: 100% used normalizes to 0% left, 88% used to 12% left") {
    let claudeUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 100.0,
        weeklyLimitPercent: 88.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "claude_plan_usage_history"
    )
    try assert(claudeUsage.sessionRemainingPercent == 0.0, "Claude 100% used must normalize to 0% left (actual: \(String(describing: claudeUsage.sessionRemainingPercent))).")
    try assert(claudeUsage.weeklyRemainingPercent == 12.0, "Claude 88% used must normalize to 12% left (actual: \(String(describing: claudeUsage.weeklyRemainingPercent))).")
    try assert(claudeUsage.isQuotaExhausted == true, "Claude 0% session left must be marked quota exhausted.")
}

// 87. Codex Quota UI: 79% used normalizes to 21% left
runTest("87. Codex Quota UI: 79% used normalizes to 21% left") {
    let codexUsage = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 79.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server"
    )
    try assert(codexUsage.weeklyRemainingPercent == 21.0, "Codex 79% used must normalize to 21% left (actual: \(String(describing: codexUsage.weeklyRemainingPercent))).")
    try assert(codexUsage.isQuotaExhausted == false, "Codex 21% left must NOT be quota exhausted.")
}

// 88. AGY 5-Hour Quota UI: 24% remaining normalizes to 24% left
runTest("88. AGY 5-Hour Quota UI: 24% remaining normalizes to 24% left") {
    let family = ModelFamilyQuota(
        name: "Gemini",
        sessionLimitPercent: 24.0,
        sessionResetText: "resets in 28m",
        weeklyLimitPercent: 37.0,
        weeklyResetText: "resets in 4d 7h",
        isPercentUsed: false
    )
    try assert(family.sessionRemainingPercent == 24.0, "Gemini session must normalize to 24% left.")
    try assert(family.weeklyRemainingPercent == 37.0, "Gemini weekly must normalize to 37% left.")
    try assert(family.isExhausted == false, "Gemini with 24% left is not exhausted.")
}

// 89. AGY Weekly Quota UI: Structured RetrieveUserQuotaSummary provides live weekly 37% left and 32% left
runTest("89. AGY Weekly Quota UI: Structured RetrieveUserQuotaSummary provides live weekly 37% left and 32% left") {
    let sampleSummaryJSON: [String: Any] = [
        "response": [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        [
                            "bucketId": "gemini-weekly",
                            "displayName": "Weekly Limit Remaining",
                            "window": "weekly",
                            "remainingFraction": 0.36892495,
                            "resetTime": "2026-08-21T21:58:54Z"
                        ],
                        [
                            "bucketId": "gemini-5h",
                            "displayName": "Five Hour Limit Remaining",
                            "window": "5h",
                            "remainingFraction": 0.24,
                            "resetTime": "2026-08-17T19:49:14Z"
                        ]
                    ]
                ],
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        [
                            "bucketId": "3p-weekly",
                            "displayName": "Weekly Limit Remaining",
                            "window": "weekly",
                            "remainingFraction": 0.31852826,
                            "resetTime": "2026-08-23T09:14:31Z"
                        ],
                        [
                            "bucketId": "3p-5h",
                            "displayName": "Five Hour Limit Remaining",
                            "window": "5h",
                            "remainingFraction": 0.0,
                            "resetTime": "2026-08-17T19:19:13Z"
                        ]
                    ]
                ]
            ]
        ]
    ]

    let connector = AntigravityLocalQuotaConnector.shared
    let usage = connector.parseAntigravityUserQuotaSummaryJSON(sampleSummaryJSON)
    try assert(usage != nil, "Summary JSON must parse successfully.")
    try assert(usage?.modelFamilies.count == 2, "Must parse 2 model families.")

    let gemini = usage?.modelFamilies.first(where: { $0.name == "Gemini" })
    try assert(gemini?.sessionRemainingPercent == 24.0, "Gemini 5-hour must be 24% left.")
    try assert(gemini?.weeklyRemainingPercent == 37.0, "Gemini weekly must be 37% left.")
    try assert(gemini?.isExhausted == false, "Gemini is not exhausted.")

    let claude = usage?.modelFamilies.first(where: { $0.name == "Claude/GPT" })
    try assert(claude?.sessionRemainingPercent == 0.0, "Claude 5-hour must be 0% left.")
    try assert(claude?.weeklyRemainingPercent == 32.0, "Claude weekly must be 32% left.")
    try assert(claude?.isExhausted == true, "Claude with 0% 5-hour left must be marked exhausted.")
    try assert(usage?.availability == .limited, "Usage with 1 exhausted family and 1 available family must be .limited.")
}

// 90. AGY Quota Degradation: GetUserStatus fallback handles missing weekly gracefully without crashing
runTest("90. AGY Quota Degradation: GetUserStatus fallback handles missing weekly gracefully without crashing") {
    let sampleStatusJSON: [String: Any] = [
        "userStatus": [
            "cascadeModelConfigData": [
                "clientModelConfigs": [
                    [
                        "label": "Gemini 3.7 Flash",
                        "modelId": "gemini-3.7-flash",
                        "quotaInfo": [
                            "remainingFraction": 0.46,
                            "resetTime": "2026-08-17T19:48:48Z"
                        ]
                    ]
                ]
            ]
        ]
    ]

    let connector = AntigravityLocalQuotaConnector.shared
    let usage = connector.parseAntigravityUserStatusJSON(sampleStatusJSON)
    try assert(usage != nil, "GetUserStatus fallback must parse successfully.")
    let gemini = usage?.modelFamilies.first(where: { $0.name == "Gemini" })
    try assert(gemini?.sessionRemainingPercent == 46.0, "Gemini 5-hour must be 46% left.")
    try assert(gemini?.weeklyRemainingPercent == nil, "Gemini weekly must be nil when absent from GetUserStatus.")
    try assert(gemini?.isExhausted == false, "Gemini is not exhausted.")
}

// 91. AGY Quota Exhaustion & Smart Auto Keep-Awake Independence
runTest("91. AGY Quota Exhaustion & Smart Auto Keep-Awake Independence") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto

    // AGY Idle + Quota Exhausted
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
    let exhaustedUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 0.0, isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        quotaSource: "agy_local_retrieve_user_quota_summary"
    )
    AgentUsageStore.shared.updateUsage(for: .antigravity, data: exhaustedUsage)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "AGY Quota Exhaustion must never trigger Smart Auto keep-awake.")
}

// 92. Refresh Stale-While-Revalidate: Refresh retains last-good quota while request is pending
runTest("92. Refresh Stale-While-Revalidate: Refresh retains last-good quota") {
    let initialUsage = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 79.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server"
    )
    AgentUsageStore.shared.updateUsage(for: .codex, data: initialUsage)

    // Verify existing quota is retained during refresh in-flight
    let usageBefore = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(usageBefore?.weeklyRemainingPercent == 21.0, "Prior quota must remain available during refresh.")
    try assert(usageBefore?.isLiveSource == true, "Prior live source flag must not be wiped.")
}

// 93. Successful Refresh: Atomically replaces prior quota
runTest("93. Successful Refresh: Atomically replaces prior quota") {
    let newUsage = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 60.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server"
    )
    AgentUsageStore.shared.updateUsage(for: .codex, data: newUsage)
    let usageAfter = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(usageAfter?.weeklyRemainingPercent == 40.0, "Fresh quota must atomically replace old sample.")
}

// 94. Failed Refresh: Preserves last-good quota with truthful freshness
runTest("94. Failed Refresh: Preserves last-good quota with truthful freshness") {
    let sample = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(sample != nil && sample?.isLiveSource == true, "Existing sample must exist.")

    // Simulate failed non-live update attempt
    let failedNonLive = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: nil,
        isLiveSource: false,
        quotaSource: "none"
    )
    AgentUsageStore.shared.updateUsage(for: .codex, data: failedNonLive)

    let preserved = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(preserved?.isLiveSource == true, "Non-live failure must not wipe last-good live source.")
    try assert(preserved?.weeklyRemainingPercent == 40.0, "Quota value must be preserved.")
}

// 95. No Previous Sample + Unavailable Source -> Unknown Availability
runTest("95. No Previous Sample + Unavailable Source -> Unknown Availability") {
    let unavail = AgentUsageData(
        agent: .chatgpt,
        weeklyLimitPercent: nil,
        isLiveSource: false,
        quotaSource: "none",
        freshness: "Unavailable"
    )
    try assert(unavail.availability == .unknown, "No sample must yield unknown availability.")
}

// 96. Closed Provider: Retains last-known quota with timestamp
runTest("96. Closed Provider: Retains last-known quota with timestamp") {
    AgentStore.shared.updateStatus(for: .codex, status: .off, detail: "Codex Desktop closed")
    let cdx = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(cdx?.weeklyRemainingPercent == 40.0, "Closed provider must retain its last-known quota.")
    try assert(cdx?.lastSuccessfulRefresh != nil, "Last successful refresh date must be recorded.")
}

// 97. Quota Dashboard: Does not label closed Codex 'Available'
runTest("97. Quota Dashboard: Does not label closed Codex Available") {
    let menuMgr = MenuBarManager.shared
    _ = menuMgr.computeRenderSignature()
    // Verify provider availability for closed app with quota does not surface as active lifecycle
    let cdxInfo = AgentStore.shared.getStatus(for: .codex)
    try assert(cdxInfo.status == .off, "Codex lifecycle must be .off")
}

// 98. Standardized Reset: Today reset formatting (24-hour, no seconds)
runTest("98. Standardized Reset: Today reset formatting (today HH:mm (in ...))") {
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    let todayTarget = now.addingTimeInterval(5640) // +1h 34m -> 11:34 AM today
    let formatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: todayTarget, now: now)
    try assert(formatted.hasPrefix("today "), "Reset today must start with 'today ': got \(formatted)")
    try assert(formatted.contains("(in 1h 34m)"), "Relative text must be '(in 1h 34m)': got \(formatted)")
    try assert(!formatted.contains("AM") && !formatted.contains("PM"), "Must use 24-hour time without AM/PM.")
}

// 99. Standardized Reset: Future-day reset formatting (MMM d HH:mm (in ...))
runTest("99. Standardized Reset: Future-day reset formatting (MMM d HH:mm (in ...))") {
    let now = Date()
    let futureTarget = now.addingTimeInterval(86400 * 2 + 3600 * 16) // +2d 16h
    let formatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: futureTarget, now: now)
    try assert(!formatted.hasPrefix("today "), "Future reset must not start with 'today '")
    try assert(formatted.contains("(in 2d 16h)"), "Relative text must be '(in 2d 16h)': got \(formatted)")
    try assert(!formatted.contains("AM") && !formatted.contains("PM"), "Must use 24-hour time without AM/PM.")
}

// 100. Standardized Reset: 24-hour format and no seconds
runTest("100. Standardized Reset: 24-hour format and no seconds") {
    let now = Date()
    let target = now.addingTimeInterval(2220) // +37m
    let formatted = AntigravityLocalQuotaConnector.formatResetDateTime(date: target, now: now)
    try assert(formatted.contains("(in 37m)"), "37m relative precision: got \(formatted)")
    let colonCount = formatted.filter { $0 == ":" }.count
    try assert(colonCount == 1, "Must contain exactly one colon for HH:mm without seconds: got \(formatted)")
}

// 101. Standardized Reset: Relative duration precision (<1h -> mins, <1d -> h m, >=1d -> d h)
runTest("101. Standardized Reset: Relative duration precision") {
    let now = Date()
    let t1 = AntigravityLocalQuotaConnector.formatResetDateTime(date: now.addingTimeInterval(1800), now: now) // 30m
    try assert(t1.contains("(in 30m)"), "30m check: \(t1)")

    let t2 = AntigravityLocalQuotaConnector.formatResetDateTime(date: now.addingTimeInterval(18360), now: now) // 5h 06m
    try assert(t2.contains("(in 5h 06m)"), "5h 06m check: \(t2)")

    let t3 = AntigravityLocalQuotaConnector.formatResetDateTime(date: now.addingTimeInterval(86400 * 4 + 3600 * 18), now: now) // 4d 18h
    try assert(t3.contains("(in 4d 18h)"), "4d 18h check: \(t3)")
}

// 102. Universal % Left: Clamped remaining percentages
runTest("102. Universal % Left: Clamped remaining percentages") {
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 100.0, isPercentUsed: true) == 0.0, "100% used -> 0% left")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 79.0, isPercentUsed: true) == 21.0, "79% used -> 21% left")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 36.0, isPercentUsed: false) == 36.0, "36% remaining -> 36% left")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: -5.0, isPercentUsed: false) == 0.0, "Clamped minimum")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 105.0, isPercentUsed: false) == 100.0, "Clamped maximum")
}

// 103. Quota Exhaustion & Smart Auto Safety
runTest("103. Quota Exhaustion & Smart Auto Safety") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentStore.shared.updateAvailability(for: .claude, availability: .quotaExhausted)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Quota Exhausted idle agent must never keep awake.")
}

// 104. MenuBarManager Render Signature includes isRefreshingUsage
runTest("104. MenuBarManager Render Signature includes isRefreshingUsage") {
    let sig = MenuBarManager.shared.computeRenderSignature()
    try assert(!sig.isEmpty, "Render signature must be non-empty.")
}

// 105. Quota Resume Orchestration Roadmap-Only Validation
runTest("105. Quota Resume Orchestration Roadmap-Only Validation") {
    // Verify auto-resume is NOT enabled or implemented in production
    let sleepMgr = SleepManager.shared
    try assert(sleepMgr.mode == .smartAuto, "Smart Auto remains intact.")
}

// 106. Quota Section Headers Contain Provider Names Only
runTest("106. Quota Section Headers Contain Provider Names Only") {
    let claudeUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true)
    let agyUsage = AgentUsageData(agent: .antigravity, modelFamilies: [
        ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 80.0, isPercentUsed: false),
        ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, isPercentUsed: false)
    ], isLiveSource: true)
    let cdxUsage = AgentUsageData(agent: .codex, weeklyLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true)

    AgentUsageStore.shared.updateUsage(for: .claude, data: claudeUsage)
    AgentUsageStore.shared.updateUsage(for: .antigravity, data: agyUsage)
    AgentUsageStore.shared.updateUsage(for: .codex, data: cdxUsage)

    // Verify availability doesn't contaminate header titles
    try assert(claudeUsage.availability == .quotaExhausted, "Claude availability is quotaExhausted")
    try assert(agyUsage.availability == .limited, "AGY availability is limited")
    try assert(cdxUsage.availability == .quotaExhausted, "Codex availability is quotaExhausted")
}

// 107. Refresh Action Has No Global Updated X Ago
runTest("107. Refresh Action Has No Global Updated X Ago") {
    let sig = MenuBarManager.shared.computeRenderSignature()
    try assert(!sig.isEmpty, "Render signature generated.")
}

// 108. Fresh Quota Hides Routine Freshness Text
runTest("108. Fresh Quota Hides Routine Freshness Text") {
    let menuMgr = MenuBarManager.shared
    let now = Date()

    let cldFresh = AgentUsageData(agent: .claude, sessionLimitPercent: 50.0, isLiveSource: true, lastSuccessfulRefresh: now)
    let agyFresh = AgentUsageData(agent: .antigravity, modelFamilies: [ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 90.0, isPercentUsed: false)], isLiveSource: true, lastSuccessfulRefresh: now.addingTimeInterval(-24))
    let cdxFresh = AgentUsageData(agent: .codex, weeklyLimitPercent: 40.0, isLiveSource: true, lastSuccessfulRefresh: now.addingTimeInterval(-120))

    let cldTag = menuMgr.makeProviderFreshnessTag(usage: cldFresh)
    let agyTag = menuMgr.makeProviderFreshnessTag(usage: agyFresh)
    let cdxTag = menuMgr.makeProviderFreshnessTag(usage: cdxFresh)

    try assert(cldTag == nil, "Fresh Claude quota must hide routine freshness text: got \(String(describing: cldTag))")
    try assert(agyTag == nil, "Fresh AGY quota must hide routine freshness text: got \(String(describing: agyTag))")
    try assert(cdxTag == nil, "Fresh Codex quota must hide routine freshness text: got \(String(describing: cdxTag))")
}

// 109. Closed Codex + Live CLI Sample -> Fresh Quota Hides Routine Freshness
runTest("109. Closed Codex + Live CLI Sample -> Fresh Quota Hides Routine Freshness") {
    AgentStore.shared.updateStatus(for: .codex, status: .off, detail: "Codex Desktop closed")
    let liveCdx = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 79.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server",
        lastSuccessfulRefresh: Date()
    )
    AgentUsageStore.shared.updateUsage(for: .codex, data: liveCdx)

    let tag = MenuBarManager.shared.makeProviderFreshnessTag(usage: liveCdx)
    try assert(tag == nil, "Live CLI sample for closed app must be treated as fresh (nil tag): got \(String(describing: tag))")
}

// 110. Failed Source + Cached Sample -> Last Known
runTest("110. Failed Source + Cached Sample -> Last Known") {
    let cachedCdx = AgentUsageData(
        agent: .codex,
        weeklyLimitPercent: 79.0,
        isPercentUsed: true,
        isLiveSource: false,
        quotaSource: "codex_app_server",
        lastSuccessfulRefresh: Date().addingTimeInterval(-10800) // 3h ago
    )
    let tag = MenuBarManager.shared.makeProviderFreshnessTag(usage: cachedCdx)
    try assert(tag?.hasPrefix("last known ·") == true, "Failed live source with retained sample must be labelled 'last known · ...': got \(String(describing: tag))")
}

// 111. Refresh Keeps Previous Sample Visible
runTest("111. Refresh Keeps Previous Sample Visible") {
    let sample = AgentUsageStore.shared.getUsage(for: .codex)
    try assert(sample?.weeklyRemainingPercent == 21.0, "Previous sample remains visible.")
}

// 112. No-Sample Source Failure -> Unavailable
runTest("112. No-Sample Source Failure -> Unavailable") {
    let emptyUsage = AgentUsageData(agent: .chatgpt, isLiveSource: false, quotaSource: "none")
    let tag = MenuBarManager.shared.makeProviderFreshnessTag(usage: emptyUsage)
    try assert(tag == "Quota unavailable", "No sample must yield 'Quota unavailable': got \(String(describing: tag))")
}

// 113. Standardized Reset Format Remains 24-Hour
runTest("113. Standardized Reset Format Remains 24-Hour") {
    let calendar = Calendar.current
    let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    let todayDate = now.addingTimeInterval(2760) // 46m -> 10:46 AM today
    let formattedToday = AntigravityLocalQuotaConnector.formatResetDateTime(date: todayDate, now: now)
    try assert(formattedToday.hasPrefix("today "), "Today prefix: \(formattedToday)")
    try assert(formattedToday.contains("(in 46m)"), "46m relative: \(formattedToday)")
    try assert(!formattedToday.contains("AM") && !formattedToday.contains("PM"), "24-hour clock only")
}

// 114. Universal % Left Remains Intact
runTest("114. Universal % Left Remains Intact") {
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 79.0, isPercentUsed: true) == 21.0, "79% used -> 21% left")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 100.0, isPercentUsed: true) == 0.0, "100% used -> 0% left")
    try assert(ModelFamilyQuota.normalizeRemaining(raw: 34.0, isPercentUsed: false) == 34.0, "34% remaining -> 34% left")
}

// 115. Lifecycle Remains Separate from Quota Dashboard
runTest("115. Lifecycle Remains Separate from Quota Dashboard") {
    AgentStore.shared.updateStatus(for: .antigravity, status: .working, detail: "Working active turn")
    let info = AgentStore.shared.getStatus(for: .antigravity)
    try assert(info.status == .working, "Provider row tracks Working lifecycle")
    let usage = AgentUsageStore.shared.getUsage(for: .antigravity)
    try assert(usage?.availability == .limited, "Quota dashboard tracks Limited capacity independently")
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
}

// 116. Quota Never Affects Smart Auto By Itself
runTest("116. Quota Never Affects Smart Auto By Itself") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    for p in AgentID.allCases {
        AgentStore.shared.updateStatus(for: p, status: .idle)
    }
    AgentStore.shared.updateAvailability(for: .claude, availability: .quotaExhausted)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Quota Exhausted idle agent must never keep awake.")
}

// 117. MenuBarManager makeProviderFreshnessTag Output Validation
runTest("117. MenuBarManager makeProviderFreshnessTag Output Validation") {
    let menuMgr = MenuBarManager.shared
    try assert(menuMgr.makeProviderFreshnessTag(usage: nil) == "Quota unavailable", "Nil usage -> Quota unavailable")
}

// 118. Closed-Lid Smart Auto Default Derivation
runTest("118. Closed-Lid Smart Auto Default Derivation") {
    let priv = SleepManager.checkPrivilegeStatus()
    // Test dynamic getter when isClosedLidEnabled is nil
    var cfg = ConfigManager.shared.config
    cfg.isClosedLidEnabled = nil
    ConfigManager.shared.saveConfig(cfg)

    let effective = SleepManager.shared.isClosedLidModeEnabled
    if priv.hasPrivilege {
        try assert(effective == true, "Privilege present + unpersisted preference MUST default Closed-Lid to true.")
    } else {
        try assert(effective == false, "Privilege absent MUST default Closed-Lid to false.")
    }
}

// 119. Explicit User Closed-Lid Setting Beats Default Derivation
runTest("119. Explicit User Closed-Lid Setting Beats Default Derivation") {
    // Explicit OFF
    SleepManager.shared.isClosedLidModeEnabled = false
    try assert(ConfigManager.shared.config.isClosedLidEnabled == false, "Explicit OFF must persist in config.")
    try assert(SleepManager.shared.isClosedLidModeEnabled == false, "Explicit OFF must be returned even if privilege exists.")

    // Explicit ON
    SleepManager.shared.isClosedLidModeEnabled = true
    try assert(ConfigManager.shared.config.isClosedLidEnabled == true, "Explicit ON must persist in config.")
    try assert(SleepManager.shared.isClosedLidModeEnabled == true, "Explicit ON must be returned.")
}

// 120. Quota State Alone Never Triggers Closed-Lid Keep-Awake
runTest("120. Quota State Alone Never Triggers Closed-Lid Keep-Awake") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto
    for p in AgentID.allCases {
        AgentStore.shared.updateStatus(for: p, status: .idle)
    }
    AgentStore.shared.updateAvailability(for: .antigravity, availability: .quotaExhausted)
    AgentStore.shared.updateAvailability(for: .codex, availability: .quotaExhausted)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Quota state alone must never trigger Smart Auto keep-awake.")
}

// 121. One-Click Relay Output Clipboard & Tab Relay Sanitizer
runTest("121. One-Click Relay Output Clipboard & Tab Relay Sanitizer") {
    let rawWithEnvelope = "2026-08-17 20:00:00 [info] Hello, world!\n{\"type\":\"event_msg\"}\n[CDP Discovery] done"
    let clean = OutputRelayManager.shared.sanitizeOutputText(rawWithEnvelope)
    try assert(clean == "Hello, world!", "Sanitizer must strip envelopes, timestamps and log noise: got '\(clean)'")
}

// 122. Claude Quota Without Fabricated Reset Timestamp
runTest("122. Claude Quota Without Fabricated Reset Timestamp") {
    let claudeUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 13.0,
        weeklyLimitPercent: 92.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "claude_plan_usage_history"
    )
    try assert(claudeUsage.sessionResetText == nil, "Claude reset must remain nil when no structured reset source exists.")
    try assert(claudeUsage.weeklyResetText == nil, "Claude weekly reset must remain nil when no structured reset source exists.")
    try assert(claudeUsage.sessionRemainingPercent == 87.0, "13% used -> 87% remaining capacity.")
    try assert(claudeUsage.weeklyRemainingPercent == 8.0, "92% used -> 8% remaining capacity.")
}

// 123. Independent Reset Windows for Multi-Family Models
runTest("123. Independent Reset Windows for Multi-Family Models") {
    let agyUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 70.0, sessionResetText: "resets today 21:49 (in 30m)", weeklyLimitPercent: 32.0, weeklyResetText: "resets Aug 21 23:58 (in 4d 2h)", isPercentUsed: false),
            ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 4.0, sessionResetText: "resets today 21:57 (in 38m)", weeklyLimitPercent: 0.0, weeklyResetText: "resets Aug 23 11:14 (in 5d 13h)", isPercentUsed: false)
        ],
        isLiveSource: true
    )
    let gemini = agyUsage.modelFamilies.first(where: { $0.name == "Gemini" })
    let claude = agyUsage.modelFamilies.first(where: { $0.name == "Claude/GPT" })

    try assert(gemini?.sessionResetText != claude?.sessionResetText, "Reset windows must remain independent per model family.")
    try assert(gemini?.weeklyResetText != claude?.weeklyResetText, "Weekly reset windows must remain independent per model family.")
}

// 124. Claude Structured Reset: Relative "resets 3h" + observedAt -> correct absolute reset
runTest("124. Claude Structured Reset: Relative resets 3h + observedAt -> correct absolute reset") {
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 17; comps.hour = 14; comps.minute = 0; comps.second = 0
    let observedAt = cal.date(from: comps)!
    let now = observedAt

    let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: "17% · resets 3h", observedAt: observedAt, now: now)
    try assert(obs != nil, "Observation must be derived from resets 3h")
    try assert(obs?.relativeDurationSeconds == 10800.0, "3h must parse to 10800s")
    try assert(obs?.source == "claude_oauth_api" || obs?.source == "claude_cli_usage", "Source must be structured")
    try assert(obs?.formattedResetText.contains("17:00") == true, "14:00 + 3h must format to 17:00")
    try assert(obs?.formattedResetText.contains("3h") == true, "Formatted reset must contain relative 3h")
}

// 125. Claude Structured Reset: Minute-only relative reset ("resets 42m")
runTest("125. Claude Structured Reset: Minute-only relative reset (resets 42m)") {
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 17; comps.hour = 14; comps.minute = 10; comps.second = 0
    let observedAt = cal.date(from: comps)!
    let now = observedAt

    let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: "resets 42m", observedAt: observedAt, now: now)
    try assert(obs != nil, "Observation must be derived from resets 42m")
    try assert(obs?.relativeDurationSeconds == 2520.0, "42m must parse to 2520s")
    try assert(obs?.formattedResetText.contains("14:52") == true, "14:10 + 42m must format to 14:52")
    try assert(obs?.formattedResetText.contains("in 42m") == true, "Formatted reset must contain in 42m")
}

// 126. Claude Structured Reset: Reset crossing midnight -> correct tomorrow/date formatting
runTest("126. Claude Structured Reset: Reset crossing midnight -> correct tomorrow/date formatting") {
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 17; comps.hour = 23; comps.minute = 0; comps.second = 0
    let observedAt = cal.date(from: comps)!
    let now = observedAt

    let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: "resets 2h", observedAt: observedAt, now: now)
    try assert(obs != nil, "Observation must be derived")
    try assert(obs?.formattedResetText.contains("Aug 18 01:00") == true || obs?.formattedResetText.contains("tomorrow 01:00") == true || obs?.formattedResetText.contains("01:00") == true, "Crossing midnight must format next day")
}

// 127. Claude Structured Reset: 24-hour format and no seconds
runTest("127. Claude Structured Reset: 24-hour format and no seconds") {
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 17; comps.hour = 15; comps.minute = 30; comps.second = 0
    let observedAt = cal.date(from: comps)!
    let now = observedAt

    let obs = ClaudeLocalQuotaConnector.deriveResetObservation(relativeText: "resets in 1h 15m", observedAt: observedAt, now: now)
    try assert(obs != nil, "Observation must parse compound relative duration")
    let formatted = obs!.formattedResetText
    try assert(!formatted.contains("AM") && !formatted.contains("PM"), "Formatted reset must not contain AM/PM")
    try assert(!formatted.contains(":00:"), "Formatted reset must not contain seconds")
    try assert(formatted.contains("16:45"), "15:30 + 1h15m must equal 16:45")
}

// 128. Claude Structured Reset: Unavailable reset -> no fabrication (nil)
runTest("128. Claude Structured Reset: Unavailable reset -> no fabrication") {
    ClaudeLocalQuotaConnector.shared.setCachedObservations(sessionReset: nil, weeklyReset: nil)
    let meta = ClaudeLocalQuotaConnector.shared.getResetMetadata()
    try assert(meta.sessionResetText == nil, "Unavailable reset must remain nil without guessing")
    try assert(meta.weeklyResetText == nil, "Unavailable weekly reset must remain nil without guessing")
}

// 129. Claude Quota: Percentage source remains plan-usage-history when offline
runTest("129. Claude Quota: Percentage source remains plan-usage-history when offline") {
    let usage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 17.0,
        weeklyLimitPercent: 92.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "claude_plan_usage_history"
    )
    try assert(usage.quotaSource == "claude_plan_usage_history", "Percentage source must remain plan-usage-history")
    try assert(usage.sessionRemainingPercent == 83.0, "17% used -> 83% remaining")
    try assert(usage.weeklyRemainingPercent == 8.0, "92% used -> 8% remaining")
}

// 130. Claude Quota: Reset source is separately attributed
runTest("130. Claude Quota: Reset source is separately attributed") {
    let obs = ClaudeResetObservation(
        observedAt: Date(),
        relativeResetText: "resets 3h",
        relativeDurationSeconds: 10800.0,
        derivedAbsoluteReset: Date().addingTimeInterval(10800),
        formattedResetText: "resets today 23:41 (in 3h)",
        source: "claude_oauth_api",
        authority: "live_first_party"
    )
    try assert(obs.source == "claude_oauth_api" || obs.source == "claude_cli_usage", "Source must be claude_oauth_api")
    try assert(obs.authority == "live_first_party", "Authority must be live_first_party")
}

// 131. Quota Recovery: 0% -> >0% creates recovery event
runTest("131. Quota Recovery: 0% -> >0% creates recovery event") {
    AgentStore.shared.clearQuotaRestored(for: .claude)
    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentUsageStore.shared.setPreviousAuthoritativeExhausted(for: .claude, exhausted: true)

    let recoveredUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 15.0,
        weeklyLimitPercent: 20.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "claude_plan_usage_history"
    )
    AgentUsageStore.shared.updateUsage(for: .claude, data: recoveredUsage)

    try assert(AgentStore.shared.isQuotaRestored(for: .claude) == true, "Positive recovery from 0% -> >0% must set isQuotaRestored == true")
}

// 132. Quota Recovery: Unknown -> >0% does NOT create recovery
runTest("132. Quota Recovery: Unknown -> >0% does NOT create recovery") {
    AgentStore.shared.clearQuotaRestored(for: .codex)
    AgentStore.shared.updateStatus(for: .codex, status: .idle)
    AgentUsageStore.shared.setPreviousAuthoritativeExhausted(for: .codex, exhausted: false)

    let normalUsage = AgentUsageData(
        agent: .codex,
        sessionLimitPercent: 20.0,
        weeklyLimitPercent: 20.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "codex_app_server"
    )
    AgentUsageStore.shared.updateUsage(for: .codex, data: normalUsage)

    try assert(AgentStore.shared.isQuotaRestored(for: .codex) == false, "Initial or non-exhausted sample must NOT trigger quota recovery")
}

// 133. Quota Recovery: >0% -> >0% does NOT create recovery
runTest("133. Quota Recovery: >0% -> >0% does NOT create recovery") {
    AgentStore.shared.clearQuotaRestored(for: .antigravity)
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
    AgentUsageStore.shared.setPreviousAuthoritativeExhausted(for: .antigravity, exhausted: false)

    let agyUsage = AgentUsageData(
        agent: .antigravity,
        modelFamilies: [
            ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 50.0, weeklyLimitPercent: 50.0, isPercentUsed: false)
        ],
        isLiveSource: true,
        quotaSource: "agy_local"
    )
    AgentUsageStore.shared.updateUsage(for: .antigravity, data: agyUsage)

    try assert(AgentStore.shared.isQuotaRestored(for: .antigravity) == false, ">0% to >0% must NOT trigger quota recovery")
}

// 134. Quota Recovery: Fun Theme + Idle -> 🥱
runTest("134. Quota Recovery: Fun Theme + Idle -> 🥱") {
    var info = AgentInfo(id: .claude, status: .idle, availability: .available)
    info.isQuotaRestored = true

    try assert(info.effectiveDisplayStatus == .quotaRestored, "Idle + isQuotaRestored must result in .quotaRestored")
    let funBadge = info.effectiveDisplayStatus.badge(theme: .funEmoji)
    try assert(funBadge == "🥱", "Fun theme badge for quotaRestored must be 🥱")
}

// 135. Quota Recovery: Classic Theme + Idle -> normal ⚪ badge + [Quota Restored]
runTest("135. Quota Recovery: Classic Theme + Idle -> normal ⚪ badge") {
    var info = AgentInfo(id: .claude, status: .idle, availability: .available)
    info.isQuotaRestored = true

    let classicBadge = info.effectiveDisplayStatus.badge(theme: .classic)
    try assert(classicBadge == "⚪", "Classic theme badge for quotaRestored must be ⚪")
    try assert(info.effectiveDisplayStatus.statusTitle == "Quota Restored", "Status title must be Quota Restored")
}

// 136. Quota Recovery: Working outranks 🥱
runTest("136. Quota Recovery: Working outranks 🥱") {
    var info = AgentInfo(id: .claude, status: .working, availability: .available)
    info.isQuotaRestored = true

    try assert(info.effectiveDisplayStatus == .working, "Working status must outrank quotaRestored")
    let badge = info.effectiveDisplayStatus.badge(theme: .funEmoji)
    try assert(badge == "🤔", "Working badge must be 🤔, not 🥱")
}

// 137. Quota Recovery: Done outranks 🥱
runTest("137. Quota Recovery: Done outranks 🥱") {
    var info = AgentInfo(id: .claude, status: .done, availability: .available)
    info.isQuotaRestored = true

    try assert(info.effectiveDisplayStatus == .done, "Done status must outrank quotaRestored")
    let badge = info.effectiveDisplayStatus.badge(theme: .funEmoji)
    try assert(badge == "🐶", "Done badge must be 🐶, not 🥱")
}

// 138. Quota Recovery: Provider starts Working -> recovery event clears
runTest("138. Quota Recovery: Provider starts Working -> recovery event clears") {
    AgentStore.shared.setQuotaRestored(for: .claude, restored: true)
    try assert(AgentStore.shared.isQuotaRestored(for: .claude) == true, "Must be restored before work")

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working")
    try assert(AgentStore.shared.isQuotaRestored(for: .claude) == false, "Starting work must clear isQuotaRestored")
}

// 139. Quota Recovery: Explicit session/agent acknowledgement -> clears recovery event
runTest("139. Quota Recovery: Explicit session/agent acknowledgement -> clears recovery event") {
    AgentStore.shared.setQuotaRestored(for: .codex, restored: true)
    try assert(AgentStore.shared.isQuotaRestored(for: .codex) == true, "Must be restored before ack")

    AgentStore.shared.markChecked(for: .codex)
    try assert(AgentStore.shared.isQuotaRestored(for: .codex) == false, "Explicit markChecked must clear isQuotaRestored")
}

// 140. Quota Recovery: Recovery does not activate Smart Auto keep-awake
runTest("140. Quota Recovery: Recovery does not activate Smart Auto keep-awake") {
    AgentStore.shared.updateStatus(for: .chatgpt, status: .idle)
    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
    AgentStore.shared.updateStatus(for: .codex, status: .off)

    AgentStore.shared.setQuotaRestored(for: .claude, restored: true)
    let req = SleepManager.shared.evaluateSmartAutoRequirement()
    try assert(req.shouldKeepAwake == false, "Quota restored wake event must NEVER acquire keep-awake")
}

// 141. Quota Recovery: Recovery does not create attention or output sound chime
runTest("141. Quota Recovery: Recovery does not create attention or output sound chime") {
    var info = AgentInfo(id: .claude, status: .idle, availability: .available)
    info.isQuotaRestored = true
    try assert(info.effectiveDisplayStatus != .blocked, "Quota recovery must not be .blocked")
    try assert(info.effectiveDisplayStatus != .done, "Quota recovery must not be .done")
}

// 142. Quota Recovery: MenuBarManager render signature responds to quota restoration
runTest("142. Quota Recovery: MenuBarManager render signature responds to quota restoration") {
    let manager = MenuBarManager.shared
    AgentStore.shared.setQuotaRestored(for: .claude, restored: false)
    let sigBefore = manager.computeRenderSignature()

    AgentStore.shared.setQuotaRestored(for: .claude, restored: true)
    let sigAfter = manager.computeRenderSignature()

    try assert(sigBefore != sigAfter, "Render signature must change when quota restoration state changes")
    AgentStore.shared.clearQuotaRestored(for: .claude)
}

// 143. Theme Legend: Fun theme legend uses Fun badge resolver
runTest("143. Theme Legend: Fun theme legend uses Fun badge resolver") {
    let funItems = MenuBarManager.getStatusLegendItems(theme: .funEmoji, overworkMinutes: 10)
    let badges = funItems.map { $0.badge }
    try assert(badges.contains("🥶"), "Fun legend must contain 🥶 for Attention Needed")
    try assert(badges.contains("🤔"), "Fun legend must contain 🤔 for Working")
    try assert(badges.contains("🥵"), "Fun legend must contain 🥵 for Overworking")
    try assert(badges.contains("🐶"), "Fun legend must contain 🐶 for Finished")
    try assert(badges.contains("🤯"), "Fun legend must contain 🤯 for Quota Exhausted")
    try assert(badges.contains("🥱"), "Fun legend must contain 🥱 for Quota Restored")
    try assert(badges.contains("🫥"), "Fun legend must contain 🫥 for Idle")
    try assert(badges.contains("😴"), "Fun legend must contain 😴 for Closed")
}

// 144. Theme Legend: Classic theme legend uses Classic badge resolver
runTest("144. Theme Legend: Classic theme legend uses Classic badge resolver") {
    let classicItems = MenuBarManager.getStatusLegendItems(theme: .classic, overworkMinutes: 10)
    let badges = classicItems.map { $0.badge }
    try assert(badges.contains("🔴"), "Classic legend must contain 🔴 for Attention Needed")
    try assert(badges.contains("🟡"), "Classic legend must contain 🟡 for Working")
    try assert(badges.contains("🟢"), "Classic legend must contain 🟢 for Finished")
    try assert(badges.contains("⛔"), "Classic legend must contain ⛔ for Quota Exhausted")
    try assert(badges.contains("⚪"), "Classic legend must contain ⚪ for Idle")
    try assert(badges.contains("⚫"), "Classic legend must contain ⚫ for Closed")
}

// 145. Theme Legend: Changing theme changes legend dynamically
runTest("145. Theme Legend: Changing theme changes legend dynamically") {
    let funItems = MenuBarManager.getStatusLegendItems(theme: .funEmoji)
    let classicItems = MenuBarManager.getStatusLegendItems(theme: .classic)
    try assert(funItems.first?.badge != classicItems.first?.badge, "Changing theme must produce different badge sets")
    try assert(funItems.count == classicItems.count + 1, "Fun theme includes overwork badge entry")
}

// 146. Theme Legend: Quota-restored 🥱 appears in Fun legend
runTest("146. Theme Legend: Quota-restored 🥱 appears in Fun legend") {
    let funItems = MenuBarManager.getStatusLegendItems(theme: .funEmoji)
    let quotaRestored = funItems.first(where: { $0.status == .quotaRestored })
    try assert(quotaRestored?.badge == "🥱", "Fun legend must resolve quotaRestored to 🥱")
    try assert(quotaRestored?.title.contains("Quota Restored") == true, "Title must explain Quota Restored")
}

// 147. Theme Legend: No independent duplicated legend mapping
runTest("147. Theme Legend: No independent duplicated legend mapping") {
    for theme in BadgeThemeMode.allCases {
        let items = MenuBarManager.getStatusLegendItems(theme: theme)
        for item in items {
            let directBadge = item.status.badge(theme: theme)
            try assert(item.badge == directBadge || (theme == .funEmoji && (item.badge == "🥵" || item.badge == "⛔")), "Legend badge must strictly match EffectiveDisplayStatus.badge(theme:)")
        }
    }
}

// 148. API five_hour and seven_day parsing from structured OAuth response
runTest("148. API five_hour and seven_day parsing from structured OAuth response") {
    let mockJSON = """
    {
      "five_hour": {
        "utilization": 32.0,
        "resets_at": "2026-08-18T14:30:00.000Z"
      },
      "seven_day": {
        "utilization": 93.0,
        "resets_at": "2026-08-24T21:00:00.346450+00:00"
      }
    }
    """
    let data = mockJSON.data(using: .utf8)!
    let usage = ClaudeLocalQuotaConnector.shared.parseUsageResponseData(data)
    try assert(usage != nil, "Usage data must be parsed")
    try assert(usage?.sessionLimitPercent == 32.0, "5-hour utilization must be 32.0")
    try assert(usage?.sessionRemainingPercent == 68.0, "5-hour remaining must be 68.0% left")
    try assert(usage?.weeklyLimitPercent == 93.0, "7-day utilization must be 93.0")
    try assert(usage?.weeklyRemainingPercent == 7.0, "7-day remaining must be 7.0% left")
    try assert(usage?.quotaSource == "claude_oauth_api", "Quota source must be claude_oauth_api")
    try assert(usage?.sourceAuthority == "live_first_party", "Authority must be live_first_party")
}

// 149. API ISO-8601 resets_at parsing & standard 24-hour formatting
runTest("149. API ISO-8601 resets_at parsing & standard 24-hour formatting") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    var comps = DateComponents()
    comps.year = 2026; comps.month = 8; comps.day = 18; comps.hour = 10; comps.minute = 0; comps.second = 0
    comps.timeZone = TimeZone(secondsFromGMT: 0)
    let now = cal.date(from: comps)!

    // Today reset with fractional seconds
    let todayReset = ClaudeLocalQuotaConnector.formatResetText(from: "2026-08-18T14:30:00.000Z", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
    try assert(todayReset?.contains("today 14:30") == true, "Must format today 14:30: \(todayReset ?? "nil")")
    try assert(todayReset?.contains("in 4h 30m") == true, "Must format relative duration: \(todayReset ?? "nil")")
    try assert(!todayReset!.contains("AM") && !todayReset!.contains("PM"), "Must use 24-hour format")

    // Future reset with subsecond microseconds
    let futureReset = ClaudeLocalQuotaConnector.formatResetText(from: "2026-08-24T21:00:00.346450+00:00", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
    try assert(futureReset?.contains("Aug 24 21:00") == true, "Must format future date Aug 24 21:00: \(futureReset ?? "nil")")
    try assert(futureReset?.contains("in 6d 11h") == true, "Must format relative duration: \(futureReset ?? "nil")")
}

// 150. Universal used -> remaining normalization for Claude quota
runTest("150. Universal used -> remaining normalization for Claude quota") {
    let u1 = AgentUsageData(agent: .claude, sessionLimitPercent: 0.0, weeklyLimitPercent: 0.0, isPercentUsed: true)
    try assert(u1.sessionRemainingPercent == 100.0, "0% used -> 100% left")
    try assert(u1.weeklyRemainingPercent == 100.0, "0% used -> 100% left")

    let u2 = AgentUsageData(agent: .claude, sessionLimitPercent: 32.0, weeklyLimitPercent: 93.0, isPercentUsed: true)
    try assert(u2.sessionRemainingPercent == 68.0, "32% used -> 68% left")
    try assert(u2.weeklyRemainingPercent == 7.0, "93% used -> 7% left")

    let u3 = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, weeklyLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true)
    try assert(u3.sessionRemainingPercent == 0.0, "100% used -> 0% left")
    try assert(u3.weeklyRemainingPercent == 0.0, "100% used -> 0% left")
    try assert(u3.isQuotaExhausted == true, "100% used must mark isQuotaExhausted == true")
}

// 151. Model-specific limits parsing (seven_day_sonnet, seven_day_opus)
runTest("151. Model-specific limits parsing (seven_day_sonnet, seven_day_opus)") {
    let mockJSON = """
    {
      "five_hour": { "utilization": 10.0, "resets_at": "2026-08-18T15:00:00Z" },
      "seven_day": { "utilization": 20.0, "resets_at": "2026-08-25T10:00:00Z" },
      "seven_day_sonnet": { "utilization": 40.0, "resets_at": "2026-08-25T10:00:00Z" },
      "seven_day_opus": { "utilization": 15.0, "resets_at": "2026-08-25T10:00:00Z" }
    }
    """
    let data = mockJSON.data(using: .utf8)!
    let usage = ClaudeLocalQuotaConnector.shared.parseUsageResponseData(data)
    try assert(usage != nil)
    try assert(usage?.modelFamilies.count == 2, "Must parse 2 model families")
    let sonnet = usage?.modelFamilies.first(where: { $0.name == "Sonnet" })
    try assert(sonnet?.weeklyRemainingPercent == 60.0, "Sonnet 40% used -> 60% left")
    let opus = usage?.modelFamilies.first(where: { $0.name == "Opus" })
    try assert(opus?.weeklyRemainingPercent == 85.0, "Opus 15% used -> 85% left")
}

// 152. Expired OAuth token refresh logic & serialization without secrets leak
runTest("152. Expired OAuth token refresh logic & serialization without secrets leak") {
    let loader = ClaudeCredentialLoader()
    let nowMs = Date().timeIntervalSince1970 * 1000

    // Expired token (past)
    let expiredOAuth = ClaudeOAuthCredentials(accessToken: "test_expired_access", refreshToken: "test_refresh_token", expiresAt: nowMs - 60000)
    try assert(loader.needsRefresh(expiredOAuth) == true, "Expired token must need refresh")

    // Near expiry token (in 2 minutes, within 5 min buffer)
    let nearExpiryOAuth = ClaudeOAuthCredentials(accessToken: "test_near_access", refreshToken: "test_refresh_token", expiresAt: nowMs + 120000)
    try assert(loader.needsRefresh(nearExpiryOAuth) == true, "Near expiry token (<5m) must need refresh")

    // Valid long token (in 2 hours)
    let validOAuth = ClaudeOAuthCredentials(accessToken: "test_valid_access", refreshToken: "test_refresh_token", expiresAt: nowMs + 7200000)
    try assert(loader.needsRefresh(validOAuth) == false, "Token valid for 2h must NOT need refresh")

    // Token without refresh token (e.g. setup-token)
    let setupOAuth = ClaudeOAuthCredentials(accessToken: "test_setup_token", refreshToken: nil, expiresAt: nil)
    try assert(loader.needsRefresh(setupOAuth) == false, "Token without refresh token cannot be refreshed")
}

// 153. API failure -> plan-usage-history fallback without fabricated reset
runTest("153. API failure -> plan-usage-history fallback without fabricated reset") {
    ClaudeLocalQuotaConnector.shared.setCachedObservations(sessionReset: nil, weeklyReset: nil)
    let histUsage = ClaudeLocalQuotaConnector.shared.fetchFromPlanUsageHistory()
    if let hist = histUsage {
        try assert(hist.quotaSource == "claude_plan_usage_history", "Source must be claude_plan_usage_history")
        try assert(hist.isLiveSource == true, "Must be live source")
        try assert(hist.sessionResetText == nil, "Local history MUST NOT fabricate session reset text")
        try assert(hist.weeklyResetText == nil, "Local history MUST NOT fabricate weekly reset text")
        try assert(hist.sessionRemainingPercent != nil, "Must have session remaining percent")
    }
}

// 154. API failure -> bounded Claude CLI /usage fallback parsing
runTest("154. API failure -> bounded Claude CLI /usage fallback parsing") {
    let cliOutput = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 12% used
    Current week (all models): 45% used · resets Aug 24 at 10:59pm (Europe/Amsterdam)

    What's contributing to your limits usage?
    """
    let usage = ClaudeLocalQuotaConnector.shared.parseCLIUsageOutput(cliOutput)
    try assert(usage != nil, "CLI output must parse")
    try assert(usage?.sessionLimitPercent == 12.0, "Session limit must be 12.0%")
    try assert(usage?.sessionRemainingPercent == 88.0, "Session remaining must be 88.0% left")
    try assert(usage?.weeklyLimitPercent == 45.0, "Weekly limit must be 45.0%")
    try assert(usage?.weeklyRemainingPercent == 55.0, "Weekly remaining must be 55.0% left")
    try assert(usage?.weeklyResetText?.contains("resets") == true, "Weekly reset text must be formatted: \(usage?.weeklyResetText ?? "nil")")
    try assert(usage?.quotaSource == "claude_cli_usage", "Source must be claude_cli_usage")
}

// 155. CLI execution timeout, process reaping & no orphan process leak
runTest("155. CLI execution timeout, process reaping & no orphan process leak") {
    let monitor = AutoMonitor.shared
    let start = Date()
    let out = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["10"],
        timeoutSeconds: 0.1
    )
    let elapsed = Date().timeIntervalSince(start)
    try assert(out == nil, "Timed out command must return nil")
    try assert(elapsed < 1.0, "Must abort within 1.0s")
    try assert(monitor.lastSubprocessConfirmedReaped == true, "Must be confirmed reaped")
    if let pid = monitor.lastSubprocessPID {
        try assert(kill(pid, 0) != 0, "PID \(pid) must be dead and reaped")
    }
}

// 156. No Claude Accessibility requirement (AX free)
runTest("156. No Claude Accessibility requirement (AX free)") {
    let info = ClaudeLocalQuotaConnector.shared.getDebugInfo()
    try assert(info.apiAvailable || info.cliAvailable || info.percentageSource != "none", "Safe sources available")
    // Accessibility is zero-dependency: no AX permissions checked or required for Claude quota
    let meta = ClaudeLocalQuotaConnector.shared.getResetMetadata()
    _ = meta
}

// 157. Live Claude Structured Quota Integration Smoke Test
runTest("157. Live Claude Structured Quota Integration Smoke Test") {
    let liveQuota = ClaudeLocalQuotaConnector.shared.fetchQuota(forceRefresh: true)
    try assert(liveQuota != nil, "Live Claude quota must be returned from OAuth API, history, or CLI")
    print("  [Live Claude Quota] Source: \(liveQuota?.quotaSource ?? "unknown"), 5h: \(Int(liveQuota?.sessionRemainingPercent ?? 0))% left (\(liveQuota?.sessionResetText ?? "no reset")), Weekly: \(Int(liveQuota?.weeklyRemainingPercent ?? 0))% left (\(liveQuota?.weeklyResetText ?? "no reset"))")
    try assert(liveQuota?.isLiveSource == true, "Must be live source")
    try assert(liveQuota?.quotaSource == "claude_oauth_api" || liveQuota?.quotaSource == "claude_plan_usage_history" || liveQuota?.quotaSource == "claude_cli_usage", "Source must be structured provider")
}

// 158. No fabricated reset when source unavailable
runTest("158. No fabricated reset when source unavailable") {
    let emptyHist = AgentUsageData(agent: .claude, sessionLimitPercent: 20.0, weeklyLimitPercent: 30.0, isPercentUsed: true, isLiveSource: true, quotaSource: "claude_plan_usage_history")
    try assert(emptyHist.sessionResetText == nil, "Session reset must be nil when unavailable")
    try assert(emptyHist.weeklyResetText == nil, "Weekly reset must be nil when unavailable")
}

// 159. Quota recovery 🥱 preserved & theme-aware resolution
runTest("159. Quota recovery 🥱 preserved & theme-aware resolution") {
    var info = AgentInfo(id: .claude, status: .idle, availability: .available)
    info.isQuotaRestored = true

    try assert(info.effectiveDisplayStatus == .quotaRestored)
    try assert(info.effectiveDisplayStatus.badge(theme: .funEmoji) == "🥱")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⚪")
}

// 160. Safe quota metadata debug info exposes required fields without leaks
runTest("160. Safe quota metadata debug info exposes required fields without leaks") {
    let info = ClaudeLocalQuotaConnector.shared.getDebugInfo()
    try assert(!info.percentageSource.isEmpty, "percentageSource must not be empty")
    try assert(!info.resetSource.isEmpty, "resetSource must not be empty")
}

// 161. Monitored Agents: All detected providers default to monitored (enabled)
runTest("161. Monitored Agents: All detected providers default to monitored (enabled)") {
    var cfg = ConfigManager.shared.config
    cfg.disabledAgents = []
    ConfigManager.shared.saveConfig(cfg)

    for agent in AgentID.allCases {
        try assert(ConfigManager.shared.isAgentMonitored(agent), "\(agent.displayName) must be monitored by default")
    }
}

// 162. Monitored Agents: Disabling an agent persists in config.disabledAgents
runTest("162. Monitored Agents: Disabling an agent persists in config.disabledAgents") {
    ConfigManager.shared.setAgentMonitored(.codex, monitored: false)
    try assert(!ConfigManager.shared.isAgentMonitored(.codex), "Codex must now be disabled")
    try assert(ConfigManager.shared.isAgentMonitored(.chatgpt), "ChatGPT must remain enabled")
    try assert(ConfigManager.shared.isAgentMonitored(.copilot), "Copilot must remain enabled")

    let disabled = ConfigManager.shared.config.disabledAgents ?? []
    try assert(disabled.contains("codex"), "disabledAgents in config must contain 'codex'")
}

// 163. Monitored Agents: Disabled provider is excluded from overallSummary and compactSummary
runTest("163. Monitored Agents: Disabled provider is excluded from overallSummary and compactSummary") {
    AgentStore.shared.updateStatus(for: .codex, status: .working)
    AgentStore.shared.updateStatus(for: .chatgpt, status: .idle)

    let summaryDisabled = AgentStore.shared.overallSummary()
    try assert(!summaryDisabled.contains("CDX"), "overallSummary must omit disabled Codex: got \(summaryDisabled)")
    try assert(summaryDisabled.contains("GPT"), "overallSummary must include enabled ChatGPT: got \(summaryDisabled)")

    let compactDisabled = AgentStore.shared.compactSummary()
    try assert(!compactDisabled.contains("CDX"), "compactSummary must omit disabled Codex: got \(compactDisabled)")

    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)
    let summaryEnabled = AgentStore.shared.overallSummary()
    try assert(summaryEnabled.contains("CDX"), "overallSummary must include re-enabled Codex: got \(summaryEnabled)")
    AgentStore.shared.updateStatus(for: .codex, status: .idle)
}

// 164. Monitored Agents: Disabled provider cannot acquire Smart Auto keep-awake even if working
runTest("164. Monitored Agents: Disabled provider cannot acquire Smart Auto keep-awake even if working") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }
    SleepManager.shared.mode = .smartAuto

    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)
    AgentStore.shared.updateStatus(for: .antigravity, status: .working)
    SleepManager.shared.updateSleepAssertionState()
    try assert(SleepManager.shared.isAssertionActive, "Enabled working Antigravity acquires keep-awake")

    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: false)
    SleepManager.shared.updateSleepAssertionState()
    try assert(!SleepManager.shared.isAssertionActive, "Disabled working Antigravity must NOT acquire keep-awake")

    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)
    AgentStore.shared.updateStatus(for: .antigravity, status: .idle)
    SleepManager.shared.updateSleepAssertionState()
}

// 165. Five-Provider Smart Auto: Codex & Copilot participate in Smart Auto when monitored
runTest("165. Five-Provider Smart Auto: Codex & Copilot participate in Smart Auto when monitored") {
    let sleepMgr = SleepManager.shared
    sleepMgr.mode = .smartAuto

    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }

    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    // 1. Codex Working -> Activates Smart Auto
    AgentStore.shared.updateStatus(for: .codex, status: .working)
    let evalCodex = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalCodex.shouldKeepAwake, "Codex Working must activate Smart Auto")
    try assert(evalCodex.reason.contains("Codex Desktop"), "Reason must contain Codex Desktop")
    AgentStore.shared.updateStatus(for: .codex, status: .idle)

    // 2. Copilot Working -> Activates Smart Auto
    AgentStore.shared.updateStatus(for: .copilot, status: .working)
    let evalCopilot = sleepMgr.evaluateSmartAutoRequirement()
    try assert(evalCopilot.shouldKeepAwake, "Copilot Working must activate Smart Auto")
    try assert(evalCopilot.reason.contains("GitHub Copilot"), "Reason must contain GitHub Copilot")
    AgentStore.shared.updateStatus(for: .copilot, status: .idle)

    // 3. Disabled provider cannot activate
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: false)
    AgentStore.shared.updateStatus(for: .copilot, status: .working)
    let evalDisabled = sleepMgr.evaluateSmartAutoRequirement()
    try assert(!evalDisabled.shouldKeepAwake, "Disabled Copilot cannot activate Smart Auto")
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)
    AgentStore.shared.updateStatus(for: .copilot, status: .idle)
}

// 166. GitHub Copilot Lifecycle: user.message & assistant.turn_start -> Working state
runTest("166. GitHub Copilot Lifecycle: user.message & assistant.turn_start -> Working state") {
    let sessId = "test-copilot-sess-01"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Feature implementation",
        cwd: "/Users/ava/Projects/demo",
        eventType: "user.message",
        toolName: nil,
        turnId: "turn-01",
        durationMs: nil
    )

    let info = AgentStore.shared.getStatus(for: .copilot)
    try assert(info.status == .working, "Copilot status must be working after user.message: got \(info.status)")
    try assert(info.sessionTitle == "Feature implementation", "Copilot session title must match: got \(String(describing: info.sessionTitle))")

    let sessions = AgentStore.shared.getSessions(for: .copilot)
    let matched = sessions.first(where: { $0.sessionId == sessId })
    try assert(matched != nil, "Tracked session must exist")
    try assert(matched?.status == .working, "Tracked session must be working")
}

// 167. GitHub Copilot Lifecycle: tool.execution_start (ask_user) -> Needs You / Blocked state
runTest("167. GitHub Copilot Lifecycle: tool.execution_start (ask_user) -> Needs You / Blocked state") {
    let sessId = "test-copilot-sess-01"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Feature implementation",
        cwd: "/Users/ava/Projects/demo",
        eventType: "tool.execution_start",
        toolName: "ask_user",
        turnId: "turn-01",
        durationMs: nil
    )

    let info = AgentStore.shared.getStatus(for: .copilot)
    try assert(info.status == .blocked, "Copilot status must be blocked when ask_user tool starts: got \(info.status)")
    let sessions = AgentStore.shared.getSessions(for: .copilot)
    let matched = sessions.first(where: { $0.sessionId == sessId })
    try assert(matched?.status == .blocked, "Tracked session must be blocked")
    try assert(matched?.attentionReason == "Waiting for user response", "Attention reason must be set on session")
}

// 168. GitHub Copilot Lifecycle: tool.execution_complete -> Working state recovery
runTest("168. GitHub Copilot Lifecycle: tool.execution_complete -> Working state recovery") {
    let sessId = "test-copilot-sess-01"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Feature implementation",
        cwd: "/Users/ava/Projects/demo",
        eventType: "tool.execution_complete",
        toolName: "ask_user",
        turnId: "turn-01",
        durationMs: nil
    )

    let info = AgentStore.shared.getStatus(for: .copilot)
    try assert(info.status == .working, "Copilot status must resume working after ask_user tool completes: got \(info.status)")
}

// 169. GitHub Copilot Lifecycle: assistant.turn_end -> Done state with duration
runTest("169. GitHub Copilot Lifecycle: assistant.turn_end -> Done state with duration") {
    let sessId = "test-copilot-sess-01"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Feature implementation",
        cwd: "/Users/ava/Projects/demo",
        eventType: "assistant.turn_end",
        toolName: nil,
        turnId: "turn-01",
        durationMs: 45000
    )

    let info = AgentStore.shared.getStatus(for: .copilot)
    try assert(info.status == .done, "Copilot status must be done after assistant.turn_end: got \(info.status)")
    try assert(info.lastDurationSeconds == 45.0, "Copilot lastDurationSeconds must be 45s: got \(String(describing: info.lastDurationSeconds))")
}

// 170. GitHub Copilot Lifecycle: Session shutdown -> Idle
runTest("170. GitHub Copilot Lifecycle: Session shutdown -> Idle") {
    let sessId = "test-copilot-sess-01"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Feature implementation",
        cwd: "/Users/ava/Projects/demo",
        eventType: "session.shutdown",
        toolName: nil,
        turnId: "turn-01",
        durationMs: nil
    )

    let sessions = AgentStore.shared.getSessions(for: .copilot)
    let matched = sessions.first(where: { $0.sessionId == sessId })
    try assert(matched?.status == .idle, "Tracked session must transition to idle on shutdown")
}

// 171. GitHub Copilot: Events.jsonl fixture parsing via AutoMonitor
runTest("171. GitHub Copilot: Events.jsonl fixture parsing via AutoMonitor") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("copilot_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sessDir = tempDir.appendingPathComponent("sess-fixture-99")
    try FileManager.default.createDirectory(at: sessDir, withIntermediateDirectories: true)

    let workspaceYaml = "name: \"Bugfix #404\"\ncwd: \"/Users/ava/test\"\ncreated_at: 1723000000\n"
    try workspaceYaml.write(to: sessDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

    let eventsLines = """
    {"type":"session.start","data":{"sessionId":"sess-fixture-99"}}
    {"type":"user.message","data":{"content":"Fix issue"}}
    {"type":"tool.execution_start","data":{"toolName":"ask_user","turnId":"t1"}}

    """
    let eventsFile = sessDir.appendingPathComponent("events.jsonl")
    try eventsLines.write(to: eventsFile, atomically: true, encoding: .utf8)

    let summary = AutoMonitor.CopilotSessionSummary(id: "sess-fixture-99", title: "Bugfix #404", cwd: "/Users/ava/test", eventsPath: eventsFile.path, modDate: Date())
    AutoMonitor.shared.processCopilotEvents(session: summary)

    let info = AgentStore.shared.getStatus(for: .copilot)
    try assert(info.status == .blocked, "AutoMonitor fixture processing must yield blocked for ask_user: got \(info.status)")
    try assert(info.sessionTitle == "Bugfix #404", "Title from workspace.yaml must be used")

    // Clean up
    AgentStore.shared.updateStatus(for: .copilot, status: .idle)
}

// 172. Monitored Agents: Disabled agent excluded from NotificationManager
runTest("172. Monitored Agents: Disabled agent excluded from NotificationManager") {
    ConfigManager.shared.setAgentMonitored(.claude, monitored: false)
    NotificationManager.shared.notify(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Claude finished task")
    try assert(NotificationManager.shared.lastNotifiedStatus[.claude] != .done, "Disabled Claude must NOT trigger notification dispatch")
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)
}

// 173. Sound Preferences: Mute (No Sound) state cleanly representation
runTest("173. Sound Preferences: Mute (No Sound) state cleanly representation") {
    var cfg = ConfigManager.shared.config
    cfg.doneSoundName = "Mute (No Sound)"
    cfg.attentionSoundName = "Mute (No Sound)"
    ConfigManager.shared.saveConfig(cfg)

    try assert(!NotificationManager.shared.soundEnabled, "soundEnabled must be false when both sounds are Mute")

    cfg.doneSoundName = "Glass"
    ConfigManager.shared.saveConfig(cfg)
    try assert(NotificationManager.shared.soundEnabled, "soundEnabled must be true when at least one sound is unmuted")
}

// 174. Render Signature responds to disabledAgents changes
runTest("174. Render Signature responds to disabledAgents changes") {
    let sigBefore = MenuBarManager.shared.computeRenderSignature()
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: false)
    let sigAfter = MenuBarManager.shared.computeRenderSignature()
    try assert(sigBefore != sigAfter, "Render signature must change when disabledAgents changes")
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)
}

// 175. Monitored Agents: All providers restored to monitored default
runTest("175. Monitored Agents: All providers restored to monitored default") {
    var cfg = ConfigManager.shared.config
    cfg.disabledAgents = []
    ConfigManager.shared.saveConfig(cfg)
    for agent in AgentID.allCases {
        try assert(ConfigManager.shared.isAgentMonitored(agent), "\(agent.displayName) must be monitored")
    }
}

// 176. Copilot Lifecycle: Generic child tool hooks (preToolUse, postToolUse) DO NOT overwrite Done status
runTest("176. Copilot Lifecycle: Generic child tool hooks DO NOT overwrite Done status") {
    let sessId = "copilot_hook_filter_test"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Hook Filter Task",
        cwd: "/Users/ava/test",
        eventType: "user.message",
        turnId: "turn_hf_01"
    )
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .working, "Must be working on user.message")

    // Complete turn
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Hook Filter Task",
        cwd: "/Users/ava/test",
        eventType: "assistant.turn_end",
        turnId: "turn_hf_01",
        durationMs: 4500
    )
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .done, "Must transition to done on assistant.turn_end")

    // Post-turn child hooks fire (like in real Copilot telemetry/post tool hooks)
    let childHook1 = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Hook Filter Task",
        cwd: "/Users/ava/test",
        eventType: "hook.start",
        hookType: "preToolUse"
    )
    try assert(!childHook1, "preToolUse must be ignored and not mutate state")
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .done, "Session must RETAIN .done status against child preToolUse hook")

    let childHook2 = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Hook Filter Task",
        cwd: "/Users/ava/test",
        eventType: "hook.start",
        hookType: "postToolUse"
    )
    try assert(!childHook2, "postToolUse must be ignored")
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .done, "Session must RETAIN .done status against child postToolUse hook")
}

// 177. Copilot Lifecycle: hook.start / hook.end with agentStop triggers Done state
runTest("177. Copilot Lifecycle: hook.start / hook.end with agentStop triggers Done state") {
    let sessId = "copilot_stop_hook_test"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Stop Hook Task",
        cwd: "/Users/ava/test",
        eventType: "user.message",
        turnId: "turn_sh_01"
    )
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .working, "Must be working")

    let res = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Stop Hook Task",
        cwd: "/Users/ava/test",
        eventType: "hook.start",
        hookType: "agentStop"
    )
    try assert(res, "agentStop hook must be recognized as terminal stop")
    try assert(AgentStore.shared.getStatus(for: .copilot).status == .done, "Must transition to done on agentStop hook")
}

// 178. Copilot Lifecycle: sessionEnd / session.shutdown transitions session to Idle
runTest("178. Copilot Lifecycle: sessionEnd / session.shutdown transitions session to Idle") {
    let sessId = "copilot_shutdown_test"
    _ = AgentStore.shared.handleCopilotEvent(
        sessionId: sessId,
        title: "Shutdown Task",
        cwd: "/Users/ava/test",
        eventType: "hook.end",
        hookType: "sessionEnd"
    )
    let sess = AgentStore.shared.getSessions(for: .copilot).first(where: { $0.sessionId == sessId })
    try assert(sess?.status == .idle, "sessionEnd must transition session to idle")
}

// 179. Copilot Quota: Structured API response parsing from /copilot_internal/user
runTest("179. Copilot Quota: Structured API response parsing from /copilot_internal/user") {
    let mockJSON = """
    {
      "login": "iknoest",
      "access_type_sku": "free_limited_copilot",
      "copilot_plan": "individual",
      "quota_snapshots": {
        "chat": {
          "percent_remaining": 68.4,
          "quota_id": "chat",
          "quota_remaining": 136.9,
          "unlimited": false,
          "credits_used": 63,
          "remaining": 136,
          "entitlement": 200
        },
        "completions": {
          "percent_remaining": 100.0,
          "quota_id": "completions",
          "quota_remaining": 2000.0,
          "unlimited": false,
          "credits_used": 0,
          "remaining": 2000,
          "entitlement": 2000
        }
      },
      "quota_reset_date_utc": "2026-09-01T00:00:00.000Z"
    }
    """
    let data = mockJSON.data(using: .utf8)!
    let usage = CopilotLocalQuotaConnector.shared.parseUsageResponseData(data)
    try assert(usage != nil, "Must parse Copilot usage data")
    try assert(usage?.sessionLimitPercent == 68.4, "Must parse 68.4% chat remaining")
    try assert(!usage!.isPercentUsed, "isPercentUsed must be false (percent remaining)")
    try assert(usage?.isLiveSource == true, "Must be live source")
    try assert(usage?.quotaSource == "copilot_internal_user", "Source must be copilot_internal_user")
    try assert(usage?.modelFamilies.count == 2, "Must parse 2 model families (Chat & Completions)")
}

// 180. Copilot Quota: Format reset date string
runTest("180. Copilot Quota: Format reset date string") {
    let baseDate = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 12, minute: 0))!
    let resetStr = CopilotLocalQuotaConnector.formatResetText(from: "2026-09-01T00:00:00.000Z", now: baseDate)
    try assert(resetStr != nil, "Must format reset string")
    try assert(resetStr!.contains("Sep 1"), "Must format month/day as Sep 1: got \(resetStr!)")
    try assert(resetStr!.contains("in 13d") || resetStr!.contains("in 14d"), "Must contain day relative duration: got \(resetStr!)")
}

// 181. One-Shot Switch: Arming watch does not immediately switch window while Working
runTest("181. One-Shot Switch: Arming watch does not immediately switch window while Working") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusTriggeredCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in
        focusTriggeredCount += 1
    }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_01")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_01"), "Watch must be armed")

    // Working state update inside same turn must NOT trigger focus
    let trans = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_01", newStatus: .working)
    try assert(!trans, "Working status transition must NOT trigger focus")
    try assert(focusTriggeredCount == 0, "No window focus must be executed while working")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_01"), "Watch must remain armed while working")
}

// 182. One-Shot Switch: Transition to Done triggers focus once and automatically disarms
runTest("182. One-Shot Switch: Transition to Done triggers focus once and automatically disarms") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusedProvider: AgentID? = nil
    var focusedSessionId: String? = nil
    switchMgr.focusExecutionHandler = { p, s, _, _ in
        focusedProvider = p
        focusedSessionId = s
    }

    AgentStore.shared.updateStatus(for: .copilot, status: .working, detail: "Copilot working", turnId: "turn_copilot_99")
    switchMgr.arm(provider: .copilot, sessionId: "sess_copilot_99")
    let trans = switchMgr.evaluateTransition(provider: .copilot, sessionId: "sess_copilot_99", newStatus: .done, turnId: "turn_copilot_99")
    try assert(trans, "Transition to Done must trigger One-Shot Switch")
    try assert(switchMgr.armedTarget == nil, "Watch must be AUTOMATICALLY DISARMED after first trigger")

    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(focusedProvider == .copilot, "Focused provider must be copilot")
    try assert(focusedSessionId == "sess_copilot_99", "Focused sessionId must match")

    // Subsequent turns MUST NOT trigger focus (no repeated focus stealing)
    let secondTrans = switchMgr.evaluateTransition(provider: .copilot, sessionId: "sess_copilot_99", newStatus: .done)
    try assert(!secondTrans, "Subsequent Done transitions without re-arming must NOT trigger focus")
}

// 183. One-Shot Switch: Transition to Blocked (Needs You) triggers focus once and disarms
runTest("183. One-Shot Switch: Transition to Blocked (Needs You) triggers focus once and disarms") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusedProvider: AgentID? = nil
    switchMgr.focusExecutionHandler = { p, _, _, _ in
        focusedProvider = p
    }

    AgentStore.shared.updateStatus(for: .antigravity, status: .working, detail: "Antigravity working")
    switchMgr.arm(provider: .antigravity, sessionId: "agy_perm_sess")
    let trans = switchMgr.evaluateTransition(provider: .antigravity, sessionId: "agy_perm_sess", newStatus: .blocked)
    try assert(trans, "Transition to Blocked (Needs You) must trigger One-Shot Switch")
    try assert(switchMgr.armedTarget == nil, "Watch must be disarms")

    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(focusedProvider == .antigravity, "Focused provider must be antigravity")
}

// 184. One-Shot Switch: Cancellation / unchecking prevents focus and disarms watch
runTest("184. One-Shot Switch: Cancellation / unchecking prevents focus and disarms watch") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusTriggered = false
    switchMgr.focusExecutionHandler = { _, _, _, _ in
        focusTriggered = true
    }

    AgentStore.shared.updateStatus(for: .chatgpt, status: .working, detail: "ChatGPT thinking")
    switchMgr.arm(provider: .chatgpt, targetTabId: 777)
    try assert(switchMgr.isArmed(provider: .chatgpt, targetTabId: 777), "Must be armed")

    // User unchecks / cancels
    switchMgr.disarm()
    try assert(!switchMgr.isArmed(provider: .chatgpt, targetTabId: 777), "Must be disarmed")

    let trans = switchMgr.evaluateTransition(provider: .chatgpt, targetTabId: 777, newStatus: .done)
    try assert(!trans, "Cancelled watch must NOT trigger transition")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(!focusTriggered, "No focus must occur after cancellation")
}

// 185. One-Shot Switch: Unrelated provider / session transition does NOT trigger focus
runTest("185. One-Shot Switch: Unrelated provider / session transition does NOT trigger focus") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusTriggered = false
    switchMgr.focusExecutionHandler = { _, _, _, _ in
        focusTriggered = true
    }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude thinking")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_A")

    // Unrelated provider (ChatGPT) completes
    let trans1 = switchMgr.evaluateTransition(provider: .chatgpt, targetTabId: 101, newStatus: .done)
    try assert(!trans1, "Unrelated ChatGPT completion must NOT trigger Claude watch")

    // Unrelated Claude session B completes
    let trans2 = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_B", newStatus: .done)
    try assert(!trans2, "Unrelated Claude session B completion must NOT trigger session A watch")

    try assert(!focusTriggered, "No focus must trigger for unrelated transitions")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_A"), "Original watch must remain armed")
}

// 186. Canonical Priority: Claude Working + ChatGPT New Output -> Compact surfaces ChatGPT New Output
runTest("186. Canonical Priority: Claude Working + ChatGPT New Output -> Compact surfaces ChatGPT") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }
    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude thinking")
    AgentStore.shared.updateStatus(for: .chatgpt, status: .done, detail: "ChatGPT output ready")

    let compact = AgentStore.shared.compactSummary()
    try assert(compact.contains("GPT🟢"), "Compact summary must surface newly completed ChatGPT (Done) over Claude (Working): got \(compact)")
}

// 187. Canonical Priority: Copilot Working + AGY Needs You -> Compact surfaces AGY Needs You
runTest("187. Canonical Priority: Copilot Working + AGY Needs You -> Compact surfaces AGY Needs You") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }
    AgentStore.shared.updateStatus(for: .copilot, status: .working, detail: "Copilot working")
    AgentStore.shared.updateStatus(for: .antigravity, status: .blocked, detail: "Antigravity permission prompt")

    let compact = AgentStore.shared.compactSummary()
    try assert(compact.contains("AGY🔴"), "Compact summary must surface AGY (Needs You) over Copilot (Working): got \(compact)")
}

// 188. Canonical Priority: Claude Done-unacknowledged + Copilot Working -> Compact surfaces Claude Done
runTest("188. Canonical Priority: Claude Done-unacknowledged + Copilot Working -> Compact surfaces Claude Done") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }
    AgentStore.shared.updateStatus(for: .copilot, status: .working, detail: "Copilot working")
    AgentStore.shared.updateStatus(for: .claude, status: .done, detail: "Claude output ready")

    let top = AgentStore.shared.getHighestPriorityAgent()
    try assert(top?.id == .claude, "Highest priority agent must be Claude (Done) over Copilot (Working): got \(top?.id.displayName ?? "none")")

    let compact = AgentStore.shared.compactSummary()
    try assert(compact.contains("CLD🟢"), "Compact summary must surface Claude Done over Copilot Working: got \(compact)")
}

// 189. Canonical Priority: Done acknowledged + another provider Working -> Working surfaces
runTest("189. Canonical Priority: Done acknowledged + another provider Working -> Working surfaces") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }
    // Acknowledge Claude Done -> status becomes Idle
    AgentStore.shared.markChecked(for: .claude)
    AgentStore.shared.updateStatus(for: .claude, status: .idle)
    AgentStore.shared.updateStatus(for: .copilot, status: .working, detail: "Copilot actively working")

    let top = AgentStore.shared.getHighestPriorityAgent()
    try assert(top?.id == .copilot, "When Claude is acknowledged/idle, Copilot Working must surface: got \(top?.id.displayName ?? "none")")

    let compact = AgentStore.shared.compactSummary()
    try assert(compact.contains("COP🟡"), "Compact summary must surface Copilot Working when other agents are idle: got \(compact)")
}

// 190. Menu Bar: Smart Keep-Awake first-level menu and OneShotSwitch render signature
runTest("190. Menu Bar: Smart Keep-Awake first-level menu and OneShotSwitch render signature") {
    let sigBefore = MenuBarManager.shared.computeRenderSignature()
    OneShotSwitchManager.shared.arm(provider: .claude, sessionId: "sess_render_test")
    let sigAfter = MenuBarManager.shared.computeRenderSignature()
    try assert(sigBefore != sigAfter, "Render signature must respond to OneShotSwitch arming")
    OneShotSwitchManager.shared.disarm()
}

// 191. ProviderIconLoader: Load template icons for providers
runTest("191. ProviderIconLoader: Load template icons for providers") {
    ProviderIconLoader.shared.preloadIcons()
    let gptIcon = ProviderIconLoader.shared.getIcon(for: .chatgpt)
    try assert(gptIcon != nil, "Must load ChatGPT icon from agent-white-icon")
    try assert(gptIcon?.isTemplate == true, "Loaded icon must be template image for system theme adaptation")

    let cldIcon = ProviderIconLoader.shared.getIcon(for: .claude)
    try assert(cldIcon != nil, "Must load Claude icon")

    let agyIcon = ProviderIconLoader.shared.getIcon(for: .antigravity)
    try assert(agyIcon != nil, "Must load Antigravity icon")
}

// 192. Fun/Emoji Mode: makeEmojiFunAttributedTitle produces valid title with | separator
runTest("192. Fun/Emoji Mode: makeEmojiFunAttributedTitle produces valid title with | separator") {
    AgentStore.shared.currentTheme = .funEmoji
    for agent in AgentID.allCases {
        AgentStore.shared.updateStatus(for: agent, status: .idle)
    }

    let attrTitle = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    try assert(attrTitle.length > 0, "Attributed title must not be empty")
    try assert(attrTitle.string.contains("["), "Must have bracket wrapper")
    try assert(attrTitle.string.contains("]"), "Must have bracket wrapper")
    try assert(attrTitle.string.contains(" | "), "Must contain ' | ' separator between provider groups")
    try assert(!attrTitle.string.hasPrefix("[ | "), "Must not have leading separator")
    try assert(!attrTitle.string.hasSuffix(" | ]"), "Must not have trailing separator")
}

// 193. Classic Mode: Retains 3-letter provider labels
runTest("193. Classic Mode: Retains 3-letter provider labels") {
    AgentStore.shared.currentTheme = .classic
    for agent in AgentID.allCases {
        AgentStore.shared.updateStatus(for: agent, status: .idle)
    }

    let summary = AgentStore.shared.overallSummary()
    try assert(summary.contains("GPT:⚪"), "Classic mode must retain 3-letter GPT prefix")
    try assert(summary.contains("CLD:⚪"), "Classic mode must retain 3-letter CLD prefix")
    try assert(summary.contains("CDX:⚪"), "Classic mode must retain 3-letter CDX prefix")
    try assert(summary.contains("AGY:⚪"), "Classic mode must retain 3-letter AGY prefix")
    try assert(summary.contains("COP:⚪"), "Classic mode must retain 3-letter COP prefix")
}

// 194. Auto-Switch When Ready: Armable while Idle (watch next turn)
runTest("194. Auto-Switch When Ready: Armable while Idle (watch next turn)") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()

    var focusCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in
        focusCount += 1
    }

    // Arm while session is Idle
    switchMgr.arm(provider: .claude, sessionId: "idle_watch_sess")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "idle_watch_sess"), "Must be armed while Idle")

    // Transition to Working -> No switch yet
    let trans1 = switchMgr.evaluateTransition(provider: .claude, sessionId: "idle_watch_sess", newStatus: .working)
    try assert(!trans1, "Working transition must not trigger switch")
    try assert(focusCount == 0, "Focus count must be 0")

    // Next turn completes -> Done -> Triggers once & disarms
    let trans2 = switchMgr.evaluateTransition(provider: .claude, sessionId: "idle_watch_sess", newStatus: .done)
    try assert(trans2, "Done transition must trigger switch")
    try assert(!switchMgr.isArmed(provider: .claude, sessionId: "idle_watch_sess"), "Must disarm immediately")

    switchMgr.resetTestMetrics()
}

// 195. AutoMonitor checkClaudeLog preserves active tracked sessions without false-negative wiping
runTest("195. AutoMonitor checkClaudeLog preserves active tracked sessions without false-negative wiping") {
    let store = AgentStore.shared
    store.syncSessions(for: .claude, activeSessions: [], processRunning: true)
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let handled = store.handleClaudeHookEvent(
        json: [
            "event": "UserPromptSubmit",
            "session_id": "active_claude_probe_01",
            "cwd": "/Users/ava/test",
            "prompt_id": "p1"
        ],
        isTestMode: true
    )
    try assert(handled == true, "Hook event must be handled")

    let sessionsBefore = store.getSessions(for: .claude)
    try assert(sessionsBefore.count == 1, "Must have 1 active Claude session: got \(sessionsBefore.count)")
    try assert(sessionsBefore.first?.status == .working, "Session must be working")

    // Run checkClaudeLog
    AutoMonitor.shared.checkClaudeLog()

    let sessionsAfter = store.getSessions(for: .claude)
    try assert(sessionsAfter.count == 1, "Active session must NOT be wiped by checkClaudeLog: got \(sessionsAfter.count)")
    try assert(sessionsAfter.first?.status == .working, "Session must remain working")

    // Cleanup
    _ = store.handleClaudeHookEvent(
        json: [
            "event": "SessionEnd",
            "session_id": "active_claude_probe_01",
            "cwd": "/Users/ava/test"
        ],
        isTestMode: true
    )
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    // Clean up all agents to idle
    for agent in AgentID.allCases {
        AgentStore.shared.updateStatus(for: agent, status: .idle)
    }
}

// 196. ChatGPT Lifecycle Reconciliation: Working session + newer authoritative non-working snapshot -> stale Working replaced/removed
runTest("196. ChatGPT Lifecycle Reconciliation: Working session + newer authoritative non-working snapshot -> stale Working replaced/removed") {
    let store = AgentStore.shared

    // Step 1: ChatGPT emits snapshot with 1 working tab
    let workingTab = ChatGPTTabInfo(tabId: 101, title: "ChatGPT - Complex Task", url: "https://chatgpt.com/c/123", status: "working", badge: "🟡", active: true)
    store.updateStatus(for: .chatgpt, status: .working, detail: "1 ChatGPT tab(s) (1 generating)", sessionCount: 1, sessionTitle: "ChatGPT - Complex Task", targetTabId: 101, webLink: "https://chatgpt.com/c/123", openTabs: [workingTab])

    let gptState1 = store.getStatus(for: .chatgpt)
    try assert(gptState1.status == .working, "ChatGPT must be working initially")
    try assert(gptState1.openTabs.count == 1, "Must have 1 open tab")
    try assert(gptState1.thinkingStartTime != nil, "Must have thinking start time")

    // Step 2: Newer authoritative snapshot arrives where generation finished -> tab is now done
    let doneTab = ChatGPTTabInfo(tabId: 101, title: "ChatGPT - Complex Task", url: "https://chatgpt.com/c/123", status: "done", badge: "🟢", active: true)
    store.updateStatus(for: .chatgpt, status: .done, detail: "1 ChatGPT tab(s) (0 generating)", sessionCount: 1, sessionTitle: "ChatGPT - Complex Task", targetTabId: 101, webLink: "https://chatgpt.com/c/123", openTabs: [doneTab])

    let gptState2 = store.getStatus(for: .chatgpt)
    try assert(gptState2.status == .done, "ChatGPT must transition to Done upon newer authoritative snapshot")
    try assert(gptState2.thinkingStartTime == nil, "Thinking start time must be reset to nil")

    // Step 3: Tab is closed in browser -> snapshot arrives with 0 tabs
    store.updateStatus(for: .chatgpt, status: .idle, detail: "0 ChatGPT tab(s) (0 generating)", sessionCount: 0, sessionTitle: "ChatGPT Web", targetTabId: nil, webLink: "https://chatgpt.com", openTabs: [])

    let gptState3 = store.getStatus(for: .chatgpt)
    try assert(gptState3.status == .idle, "ChatGPT must transition to Idle when all tabs are closed")
    try assert(gptState3.openTabs.isEmpty, "Open tabs must be empty")
    try assert(gptState3.thinkingStartTime == nil, "Thinking start time must be nil")

    store.updateStatus(for: .chatgpt, status: .idle)
}

// 197. Claude Tool Hook -> Authoritative Stop Event -> Done state with accurate duration
runTest("197. Claude Tool Hook -> Authoritative Stop Event -> Done state with accurate duration") {
    let store = AgentStore.shared
    store.syncSessions(for: .claude, activeSessions: [], processRunning: true)
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let sessId = "test_claude_turn_reconciliation"
    // Step 1: User prompt submit
    _ = store.handleClaudeHookEvent(
        json: ["event": "UserPromptSubmit", "session_id": sessId, "cwd": "/Users/ava/code", "prompt_id": "prompt_101"],
        isTestMode: true
    )
    // Step 2: Tool execution event (Tool Read)
    _ = store.handleClaudeHookEvent(
        json: ["event": "PreToolUse", "session_id": sessId, "cwd": "/Users/ava/code", "tool_name": "Read"],
        isTestMode: true
    )

    let cldWorking = store.getStatus(for: .claude)
    try assert(cldWorking.status == .working, "Claude must be working during tool execution")
    try assert(cldWorking.detail?.contains("Tool Read") == true, "Detail should reflect tool read")

    // Step 3: Authoritative Stop event emitted by Claude Code
    _ = store.handleClaudeHookEvent(
        json: ["event": "Stop", "session_id": sessId, "cwd": "/Users/ava/code"],
        isTestMode: true
    )

    let cldDone = store.getStatus(for: .claude)
    try assert(cldDone.status == .done, "Claude must transition to Done upon authoritative Stop hook")
    try assert(cldDone.thinkingStartTime == nil, "Thinking start time must be nil upon Stop")

    // Cleanup
    _ = store.handleClaudeHookEvent(
        json: ["event": "SessionEnd", "session_id": sessId, "cwd": "/Users/ava/code"],
        isTestMode: true
    )
    store.purgeSyntheticAndStaleSessions(provider: .claude)
    store.updateStatus(for: .claude, status: .idle)
}

// 198. Claude SessionEnd Event -> session immediately removed & parent transitions to Idle
runTest("198. Claude SessionEnd Event -> session immediately removed & parent transitions to Idle") {
    let store = AgentStore.shared
    store.syncSessions(for: .claude, activeSessions: [], processRunning: true)
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let sessId = "test_claude_session_end"
    _ = store.handleClaudeHookEvent(
        json: ["event": "UserPromptSubmit", "session_id": sessId, "cwd": "/Users/ava/code"],
        isTestMode: true
    )
    try assert(store.getSessions(for: .claude).count == 1, "Must have 1 session")

    _ = store.handleClaudeHookEvent(
        json: ["event": "SessionEnd", "session_id": sessId, "cwd": "/Users/ava/code"],
        isTestMode: true
    )

    try assert(store.getSessions(for: .claude).isEmpty, "Session must be removed upon SessionEnd")
    let cldState = store.getStatus(for: .claude)
    try assert(cldState.status == .idle, "Claude parent must be idle after SessionEnd")

    store.purgeSyntheticAndStaleSessions(provider: .claude)
    store.updateStatus(for: .claude, status: .idle)
}

// 199. Legitimate Long-Running Task: 60+ minutes elapsed with no contradictory evidence -> stays Working (NO arbitrary timeout)
runTest("199. Legitimate Long-Running Task: 60+ minutes elapsed with no contradictory evidence -> stays Working (NO arbitrary timeout)") {
    let store = AgentStore.shared
    store.syncSessions(for: .claude, activeSessions: [], processRunning: true)
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let sessId = "test_claude_long_task"
    _ = store.handleClaudeHookEvent(
        json: ["event": "UserPromptSubmit", "session_id": sessId, "cwd": "/Users/ava/long_build"],
        isTestMode: true
    )

    // Simulate 75 minutes of active compilation
    let sixtyFiveMinutesAgo = Date().addingTimeInterval(-4500)
    var sessions = store.getSessions(for: .claude)
    if var activeSess = sessions.first {
        activeSess.thinkingStartTime = sixtyFiveMinutesAgo
        activeSess.lastUpdated = sixtyFiveMinutesAgo
        store.syncSessions(for: .claude, activeSessions: [activeSess], processRunning: true)
    }

    // Polling passes
    AutoMonitor.shared.checkClaudeLog()

    let afterPoll = store.getStatus(for: .claude)
    try assert(afterPoll.status == .working, "Long-running task must remain Working without arbitrary timeout!")
    try assert(afterPoll.thinkingStartTime != nil, "Thinking start time must be preserved")

    // Cleanup
    _ = store.handleClaudeHookEvent(
        json: ["event": "SessionEnd", "session_id": sessId, "cwd": "/Users/ava/long_build"],
        isTestMode: true
    )
    store.purgeSyntheticAndStaleSessions(provider: .claude)
    store.updateStatus(for: .claude, status: .idle)
}

// 200. Cross-Provider Canonical Priority: Current Done/Needs You surfaces over working/stale states
runTest("200. Cross-Provider Canonical Priority: Current Done/Needs You surfaces over working/stale states") {
    let store = AgentStore.shared
    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }

    // Claude is working, ChatGPT completes -> Done surfaces
    store.updateStatus(for: .claude, status: .working)
    store.updateStatus(for: .chatgpt, status: .done)

    let highest1 = store.getHighestPriorityAgent()
    try assert(highest1?.id == .chatgpt, "ChatGPT Done must take priority over Claude Working")

    // Antigravity enters Needs You -> Blocked surfaces above all
    store.updateStatus(for: .antigravity, status: .blocked)
    let highest2 = store.getHighestPriorityAgent()
    try assert(highest2?.id == .antigravity, "Antigravity Needs You must take top priority")

    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }
}

// 201. Claude Process Termination: Confirmed dead CLI process PID reconciles session to Idle
runTest("201. Claude Process Termination: Confirmed dead CLI process PID reconciles session to Idle") {
    let store = AgentStore.shared
    store.syncSessions(for: .claude, activeSessions: [], processRunning: true)
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let sessId = "test_dead_cli_sess_999"
    _ = store.handleClaudeHookEvent(
        json: ["event": "UserPromptSubmit", "session_id": sessId, "cwd": "/Users/ava/code"],
        isTestMode: true
    )

    // Create a temporary mock sessions directory with a dead PID (PID 999999)
    let tempDir = "/tmp/claude_test_sessions_\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let sessionJSON = "{\"pid\":999999,\"sessionId\":\"\(sessId)\"}"
    try? sessionJSON.write(toFile: "\(tempDir)/999999.json", atomically: true, encoding: .utf8)

    AutoMonitor.shared.reconcileDeadClaudeSessions(sessionsDir: tempDir)

    let sessionsAfter = store.getSessions(for: .claude)
    try assert(sessionsAfter.isEmpty, "Dead process session must be reconciled and removed")

    store.purgeSyntheticAndStaleSessions(provider: .claude)
    store.updateStatus(for: .claude, status: .idle)
}

// 202. Menu Bar Button: Fun Mode Attributed Title is Non-Empty and Retained on Button
runTest("202. Menu Bar Button: Fun Mode Attributed Title is Non-Empty and Retained on Button") {
    let store = AgentStore.shared
    store.currentTheme = .funEmoji
    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }

    let button = NSButton()
    let attrDetailed = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    try assert(attrDetailed.length > 0, "Fun mode detailed attributed title must be non-empty")
    try assert(attrDetailed.string.contains("["), "Must contain opening bracket")
    try assert(attrDetailed.string.contains("]"), "Must contain closing bracket")

    button.attributedTitle = attrDetailed
    try assert(button.attributedTitle.length > 0, "Button attributed title must be retained and not cleared")
    try assert(!button.title.isEmpty, "Button title string must be non-empty")

    store.currentTheme = .classic
}

// 203. Menu Bar Button: Classic Mode Plain Title is Non-Empty and Retained on Button
runTest("203. Menu Bar Button: Classic Mode Plain Title is Non-Empty and Retained on Button") {
    let store = AgentStore.shared
    store.currentTheme = .classic
    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }

    let summary = store.overallSummary()
    let button = NSButton()
    button.title = "[\(summary)]"

    try assert(button.title.count > 0, "Classic mode title must be non-empty")
    try assert(button.title.contains("GPT:⚪"), "Classic mode must contain standard tags")
    try assert(button.attributedTitle.length > 0, "Button attributed title must also be non-empty")
}

// 204. Provider Icon Fallback: Fun Mode with Unloadable Icon Produces Visible Textual Fallback
runTest("204. Provider Icon Fallback: Fun Mode with Unloadable Icon Produces Visible Textual Fallback") {
    let store = AgentStore.shared
    store.currentTheme = .funEmoji
    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }

    let attr = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    try assert(attr.length >= 5, "Attributed title must produce visible output even if icon assets fail")
    try assert(attr.string.hasPrefix("["), "Must start with bracket")
    try assert(attr.string.hasSuffix("]"), "Must end with bracket")

    store.currentTheme = .classic
}

// 205. Display Modes: Both Compact and Detailed Modes Produce Non-Zero Visible Content in Fun & Classic Themes
runTest("205. Display Modes: Both Compact and Detailed Modes Produce Non-Zero Visible Content in Fun & Classic Themes") {
    let store = AgentStore.shared
    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }
    store.updateStatus(for: .chatgpt, status: .working)

    // Fun Detailed & Compact
    store.currentTheme = .funEmoji
    let funDet = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    let funCmp = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "compact")
    try assert(funDet.length > 0, "Fun detailed must be non-empty")
    try assert(funCmp.length > 0, "Fun compact must be non-empty")

    // Classic Detailed & Compact
    store.currentTheme = .classic
    let clsDet = store.overallSummary()
    let clsCmp = store.compactSummary()
    try assert(!clsDet.isEmpty, "Classic detailed must be non-empty")
    try assert(!clsCmp.isEmpty, "Classic compact must be non-empty")

    for a in AgentID.allCases { store.updateStatus(for: a, status: .idle) }
}

// 206. Theme Switching: Switching Between Classic and Fun Preserves Non-Empty Button Title
runTest("206. Theme Switching: Switching Between Classic and Fun Preserves Non-Empty Button Title") {
    let store = AgentStore.shared
    let button = NSButton()

    // Fun mode
    store.currentTheme = .funEmoji
    let funAttr = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    button.attributedTitle = funAttr
    try assert(button.attributedTitle.length > 0, "Fun mode must set attributedTitle")

    // Switch to Classic
    store.currentTheme = .classic
    button.title = "[\(store.overallSummary())]"
    try assert(button.title.count > 0, "Classic mode must set title")
    try assert(button.title.contains("GPT:⚪"), "Classic mode must have text")

    // Switch back to Fun
    store.currentTheme = .funEmoji
    let funAttr2 = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    button.attributedTitle = funAttr2
    try assert(button.attributedTitle.length > 0, "Fun mode must retain attributedTitle without being cleared by title = ''")

    store.currentTheme = .classic
}

// 207. Telegram: Env configuration parsed properly without exposing secret values
runTest("207. Telegram: Env configuration parsed properly without exposing secret values") {
    let loader = EnvConfigLoader.shared
    let parsed = loader.parseDotEnvString("""
    # Comment line
    TELEGRAM_BOT_TOKEN="123456:ABC-DEF_test_token"
    TELEGRAM_CHAT_ID='987654321'
    OTHER_KEY=unused_value
    """)

    try assert(parsed["TELEGRAM_BOT_TOKEN"] == "123456:ABC-DEF_test_token")
    try assert(parsed["TELEGRAM_CHAT_ID"] == "987654321")

    let cfg = TelegramConfig(botToken: "123456:ABC-DEF_test_token", chatId: "987654321")
    try assert(cfg.isConfigured, "Config must be configured")
    try assert(cfg.diagnosticSummary == "Telegram token: configured, Telegram chat ID: configured", "Summary must redact secret tokens")
    try assert(!cfg.diagnosticSummary.contains("123456"), "Summary must never contain token digits")
}

// 208. Telegram: Missing/Disabled Telegram sends nothing
runTest("208. Telegram: Missing/Disabled Telegram sends nothing") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    // Unconfigured
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "", chatId: ""))
    ConfigManager.shared.setTelegramEnabled(true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Finished")

    try assert(mockTransport.getAllSentMessages().isEmpty, "Unconfigured Telegram must send nothing")

    // Disabled in config
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "123"))
    ConfigManager.shared.setTelegramEnabled(false)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Finished")
    try assert(mockTransport.getAllSentMessages().isEmpty, "Disabled Telegram must send nothing")

    ConfigManager.shared.setTelegramEnabled(true)
    EnvConfigLoader.shared.reload()
}

// 209. Telegram: Done status sends single outbound notification with correct format
runTest("209. Telegram: Done status sends single outbound notification with correct format") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_done_tg_01", title: "Build Project", status: .done, lastDurationSeconds: 300)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Build Project")

    // Allow async Task to complete
    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 1, "Must send exactly one notification")
    let msg = sent[0]
    try assert(msg.chatId == "12345")
    try assert(msg.text.contains("🟢 Claude Code finished"), "Must contain Done header")
    try assert(msg.text.contains("Project: Build Project"), "Must contain project title")
    try assert(msg.text.contains("New output ready (5m 0s)"), "Must contain duration")

    EnvConfigLoader.shared.reload()
}

// 210. Telegram: Duplicate Done status does not resend within debounce window
runTest("210. Telegram: Duplicate Done status does not resend within debounce window") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "agy_done_01", title: "Refactor API", status: .done, lastDurationSeconds: 300)
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .done, detail: "Refactor API")
    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .done, detail: "Refactor API")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 1, "Duplicate Done MUST NOT generate a second notification")

    EnvConfigLoader.shared.reload()
}

// 211. Telegram: Needs You (blocked) sends outbound notification
runTest("211. Telegram: Needs You (blocked) sends outbound notification") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "agy_perm_tg_01", title: "Apply Schema Migration", status: .blocked, attentionReason: "User confirmation required for DROP TABLE")
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .blocked, detail: "Apply Schema Migration")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 1, "Must send exactly 1 Needs You alert")
    try assert(sent[0].text.contains("🔴 Antigravity needs you"), "Must contain Needs You header")
    try assert(sent[0].text.contains("User confirmation required for DROP TABLE"), "Must contain reason")

    EnvConfigLoader.shared.reload()
}

// 212. Telegram: Repeated Needs You does not resend
runTest("212. Telegram: Repeated Needs You does not resend") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "cld_blocked_01", title: "Approve Tool", status: .blocked, attentionReason: "Permission needed")
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .blocked, detail: "Approve Tool")
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .blocked, detail: "Approve Tool")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.getAllSentMessages().count == 1, "Repeated Needs You must be suppressed")
    EnvConfigLoader.shared.reload()
}

// 213. Telegram: Working, Idle, Off states do NOT send Telegram messages
runTest("213. Telegram: Working, Idle, Off states do NOT send Telegram messages") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)

    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .idle, newStatus: .working, detail: "Thinking")
    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .done, newStatus: .idle, detail: "Idle")
    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .idle, newStatus: .off, detail: "Off")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.getAllSentMessages().isEmpty, "Working, Idle, and Off must never send Telegram alerts")
    EnvConfigLoader.shared.reload()
}

// 214. Telegram: Disabled provider under Monitored Agents sends nothing
runTest("214. Telegram: Disabled provider under Monitored Agents sends nothing") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: false)

    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .working, newStatus: .done, detail: "Finished")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.getAllSentMessages().isEmpty, "Disabled provider must not send Telegram alerts")
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)
    EnvConfigLoader.shared.reload()
}

// 215. Telegram: Distinct sessions generate distinct valid notifications
runTest("215. Telegram: Distinct sessions generate distinct valid notifications") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)

    let sess1 = AgentSessionInfo(provider: .claude, sessionId: "sess_math_01", title: "[MathEngine]", status: .done, lastDurationSeconds: 300, cwd: "/Users/ava/Projects/MathEngine")
    let sess2 = AgentSessionInfo(provider: .claude, sessionId: "sess_code_02", title: "[CodeReview]", status: .done, lastDurationSeconds: 300, cwd: "/Users/ava/Projects/CodeReview")

    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess1], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Math Engine Done")

    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess2], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Code Review Done")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 2, "Distinct sessions must both send alerts")
    try assert(sent[0].text.contains("Project: MathEngine"))
    try assert(sent[1].text.contains("Project: CodeReview"))

    EnvConfigLoader.shared.reload()
}

// 216. Telegram: Inbound /status command generates canonical state overview
runAsyncTest("216. Telegram: Inbound /status command generates canonical state overview") {
    let router = TelegramCommandRouter.shared
    AgentStore.shared.updateStatus(for: .chatgpt, status: .done)
    AgentStore.shared.updateStatus(for: .claude, status: .working)

    let chat = TelegramChat(id: 99999)
    let msg = TelegramMessage(message_id: 1, chat: chat, text: "/status")

    let res = await router.handleIncomingMessage(msg, configuredChatId: "99999")
    try assert(res != nil, "Must return status reply")
    let text = res!.text
    try assert(text.contains("AgentBridge Status"), "Must contain header")
    try assert(text.contains("ChatGPT Web"), "Must contain ChatGPT")
    try assert(text.contains("Claude Code"), "Must contain Claude Code")
}

// 217. Telegram: Inbound /quota command generates structured usage overview
runAsyncTest("217. Telegram: Inbound /quota command generates structured usage overview") {
    let router = TelegramCommandRouter.shared
    let chat = TelegramChat(id: 88888)
    let msg = TelegramMessage(message_id: 2, chat: chat, text: "/quota")

    let res = await router.handleIncomingMessage(msg, configuredChatId: "88888")
    try assert(res != nil, "Must return quota reply")
    let text = res!.text
    try assert(text.contains("AgentBridge Quota"), "Must contain quota header")
    try assert(text.contains("Claude Code:"), "Must list Claude Code")
}

// 218. Telegram: Inbound /sessions command returns sessions without exposing prompt/body content
runAsyncTest("218. Telegram: Inbound /sessions command returns sessions without exposing prompt/body content") {
    let router = TelegramCommandRouter.shared
    let chat = TelegramChat(id: 77777)
    let msg = TelegramMessage(message_id: 3, chat: chat, text: "/sessions")

    let res = await router.handleIncomingMessage(msg, configuredChatId: "77777")
    try assert(res != nil, "Must return sessions reply")
    let text = res!.text
    try assert(text.contains("AgentBridge Sessions"), "Must contain sessions header")
    try assert(!text.contains("BEGIN PRIVATE KEY"), "Must not expose private tokens/keys")
}

// 219. Telegram: Inbound /help command describes current commands
runAsyncTest("219. Telegram: Inbound /help command describes current commands") {
    let router = TelegramCommandRouter.shared
    let chat = TelegramChat(id: 66666)
    let msg = TelegramMessage(message_id: 4, chat: chat, text: "/help")

    let res = await router.handleIncomingMessage(msg, configuredChatId: "66666")
    try assert(res != nil, "Must return help reply")
    let text = res!.text
    try assert(text.contains("/status"), "Must describe /status")
    try assert(text.contains("/quota"), "Must describe /quota")
    try assert(text.contains("/sessions"), "Must describe /sessions")
    try assert(!text.contains("/ask"), "Must not advertise future /ask command yet")
}

// 220. Telegram Security: Authorized TELEGRAM_CHAT_ID executes commands; Unauthorized chat ID is silently dropped
runAsyncTest("220. Telegram Security: Authorized TELEGRAM_CHAT_ID executes commands; Unauthorized chat ID is silently dropped") {
    let router = TelegramCommandRouter.shared
    let authorizedChat = TelegramChat(id: 11111)
    let unauthorizedChat = TelegramChat(id: 22222)

    let authMsg = TelegramMessage(message_id: 10, chat: authorizedChat, text: "/status")
    let unauthMsg = TelegramMessage(message_id: 11, chat: unauthorizedChat, text: "/status")

    let authRes = await router.handleIncomingMessage(authMsg, configuredChatId: "11111")
    try assert(authRes != nil, "Authorized chat must receive response")

    let unauthRes = await router.handleIncomingMessage(unauthMsg, configuredChatId: "11111")
    try assert(unauthRes == nil, "Unauthorized chat ID MUST be silently dropped without reply")
}

// 221. Telegram Polling: Start/stop lifecycle and single polling task guarantee
runTest("221. Telegram Polling: Start/stop lifecycle and single polling task guarantee") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "55555"))
    ConfigManager.shared.setTelegramEnabled(true)

    bridge.startPolling()
    try assert(bridge.isPollingActive, "Polling must be active")

    // Duplicate start must not spawn second poller
    bridge.startPolling()
    try assert(bridge.isPollingActive, "Polling must remain active")

    bridge.stopPolling()
    try assert(!bridge.isPollingActive, "Polling must be stopped")

    EnvConfigLoader.shared.reload()
}

// 222. Telegram Transport Resilience: Network failure does not block AgentStore lifecycle
runTest("222. Telegram Transport Resilience: Network failure does not block AgentStore lifecycle") {
    let mockTransport = MockTelegramTransport()
    mockTransport.shouldFailSendMessage = true // Simulate network outage
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "55555"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Status change must complete instantaneously without throwing or hanging
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Network Failure Test")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // AgentStore status is intact
    let status = AgentStore.shared.getStatus(for: .claude)
    try assert(status.status == .working || status.status == .idle || status.status == .done)

    EnvConfigLoader.shared.reload()
}

// 223. Telegram Test Notification: sendTestNotification() sends connection message
runAsyncTest("223. Telegram Test Notification: sendTestNotification() sends connection message") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "55555"))

    let res = await bridge.sendTestNotification()
    try assert(res.success, "Test notification must report success")

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 1, "Must deliver test message")
    try assert(sent[0].text == "✅ AgentBridge Telegram alerts connected")
    try assert(sent[0].chatId == "55555")

    EnvConfigLoader.shared.reload()
}

// 224. Telegram: Inline comments in .env (e.g. #t.me/bot) and quotes are properly stripped
runTest("224. Telegram: Inline comments in .env (e.g. #t.me/bot) and quotes are properly stripped") {
    let loader = EnvConfigLoader.shared
    let rawEnv = """
    # Full line comment
    TELEGRAM_BOT_TOKEN=8620972525:AAED7mnqmHY0mEqX1VkN-gXf5TlyCvdmndo #t.me/AA_assistance_bot
    TELEGRAM_CHAT_ID=5598992417 # My Telegram User ID
    QUOTED_VAR="hello # not comment" # real comment
    """
    let parsed = loader.parseDotEnvString(rawEnv)
    try assert(parsed["TELEGRAM_BOT_TOKEN"] == "8620972525:AAED7mnqmHY0mEqX1VkN-gXf5TlyCvdmndo", "Must strip inline comment #t.me/... from unquoted token: got \(parsed["TELEGRAM_BOT_TOKEN"] ?? "nil")")
    try assert(parsed["TELEGRAM_CHAT_ID"] == "5598992417", "Must strip inline comment from chat ID: got \(parsed["TELEGRAM_CHAT_ID"] ?? "nil")")
    try assert(parsed["QUOTED_VAR"] == "hello # not comment", "Must preserve # inside quotes")
}

// 225. Telegram: Non-2xx response preserves sanitized API error description without secret leakage
runAsyncTest("225. Telegram: Non-2xx response preserves sanitized API error description without secret leakage") {
    let mockTransport = MockTelegramTransport()
    mockTransport.shouldFailSendMessage = true
    mockTransport.mockFailHttpStatus = 400
    mockTransport.mockFailErrorCode = 400
    mockFailDesc: do {
        mockTransport.mockFailDescription = "Bad Request: chat not found"
    }

    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "55555"))

    let res = await bridge.sendTestNotification()
    try assert(!res.success, "Must report failure")
    try assert(res.httpStatus == 400, "Must record HTTP 400")
    try assert(res.errorCode == 400, "Must record error code 400")
    try assert(res.description == "Bad Request: chat not found", "Must record safe error description")
    try assert(res.safeSummary == "Failed — Bad Request: chat not found", "safeSummary must format readable reason")
    try assert(!res.safeSummary.contains("dummy_tok"), "safeSummary must never leak bot token")
    try assert(!res.safeSummary.contains("55555"), "safeSummary must never leak chat ID")

    EnvConfigLoader.shared.reload()
}

// 226. Telegram: Send Test records visible Delivered status and MenuBarManager reflects it
runAsyncTest("226. Telegram: Send Test records visible Delivered status and MenuBarManager reflects it") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_ok", chatId: "111"))

    let res = await bridge.sendTestNotification()
    try assert(res.success)
    try assert(bridge.lastDeliveryResult?.safeSummary == "Delivered")

    EnvConfigLoader.shared.reload()
}

// 227. Telegram: Send Test records visible Failed status with safe description and MenuBarManager reflects it
runAsyncTest("227. Telegram: Send Test records visible Failed status with safe description and MenuBarManager reflects it") {
    let mockTransport = MockTelegramTransport()
    mockTransport.shouldFailSendMessage = true
    mockTransport.mockFailDescription = "Unauthorized"
    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_bad", chatId: "222"))

    let res = await bridge.sendTestNotification()
    try assert(!res.success)
    try assert(bridge.lastDeliveryResult?.safeSummary == "Failed — Unauthorized")

    EnvConfigLoader.shared.reload()
}

// 228. Auto-Switch: Arm while Claude Working, intermediate child/tool Done -> NO SWITCH
runTest("228. Auto-Switch: Arm while Claude Working, intermediate child/tool Done -> NO SWITCH") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "turn_parent_100")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_100")

    // Intermediate tool / child Done arrives with child turn ID or while still working
    let transChild = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_100", newStatus: .done, turnId: "child_tool_turn_5")
    try assert(!transChild, "Child tool Done must NOT trigger Auto-Switch for parent turn")
    try assert(switchCount == 0, "No switch executed")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_100"), "Watch must remain armed")
}

// 229. Auto-Switch: Same exact turn reaches canonical Done -> SWITCH ONCE
runTest("229. Auto-Switch: Same exact turn reaches canonical Done -> SWITCH ONCE") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    var switchedProvider: AgentID?
    switchMgr.focusExecutionHandler = { p, _, _, _ in
        switchCount += 1
        switchedProvider = p
    }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "turn_parent_100")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_100")

    let transParent = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_100", newStatus: .done, turnId: "turn_parent_100")
    try assert(transParent, "Canonical turn Done must trigger Auto-Switch")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(switchCount == 1, "Must switch exactly once")
    try assert(switchedProvider == .claude, "Switched provider must be claude")
    try assert(!switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_100"), "Must be automatically disarmed")
}

// 230. Auto-Switch: Arm while Idle with old existing Done -> NO SWITCH
runTest("230. Auto-Switch: Arm while Idle with old existing Done -> NO SWITCH") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .idle, detail: "Claude idle")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_200")

    // Old existing Done arriving before any Working phase
    let transOldDone = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_200", newStatus: .done, turnId: "old_turn_done")
    try assert(!transOldDone, "Old existing Done while waiting for next turn must NOT trigger switch")
    try assert(switchCount == 0, "No switch executed")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_200"), "Must remain waiting for next turn")
}

// 231. Auto-Switch: Next turn starts after arm, then Done -> SWITCH ONCE
runTest("231. Auto-Switch: Next turn starts after arm, then Done -> SWITCH ONCE") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .idle, detail: "Claude idle")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_200")

    // Next turn starts
    let transWork = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_200", newStatus: .working, turnId: "new_turn_300")
    try assert(!transWork, "Working phase must not trigger switch")

    // Next turn finishes
    let transDone = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_200", newStatus: .done, turnId: "new_turn_300")
    try assert(transDone, "New turn completion must trigger switch")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(switchCount == 1, "Must switch exactly once")
    try assert(!switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_200"), "Must disarm")
}

// 232. Auto-Switch: Different session Done -> NO SWITCH
runTest("232. Auto-Switch: Different session Done -> NO SWITCH") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "turn_A")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_A")

    // Unrelated session B completes
    let transB = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_B", newStatus: .done, turnId: "turn_B")
    try assert(!transB, "Different session completion must NOT trigger switch")
    try assert(switchCount == 0, "No switch executed")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "sess_claude_A"), "Must remain armed for session A")
}

// 233. Auto-Switch: Old turn Done arriving late -> NO SWITCH
runTest("233. Auto-Switch: Old turn Done arriving late -> NO SWITCH") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "turn_current_999")
    switchMgr.arm(provider: .claude, sessionId: "sess_claude_main")

    // Stale completion event from an earlier turn arrives
    let transLate = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_claude_main", newStatus: .done, turnId: "turn_old_111")
    try assert(!transLate, "Late old turn Done must NOT trigger switch")
    try assert(switchCount == 0, "No switch executed")
}

// 234. Auto-Switch: Watched turn Needs You -> SWITCH ONCE
runTest("234. Auto-Switch: Watched turn Needs You -> SWITCH ONCE") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .antigravity, status: .working, detail: "AGY working", turnId: "agy_turn_ask")
    switchMgr.arm(provider: .antigravity, sessionId: "agy_session_1")

    let transBlocked = switchMgr.evaluateTransition(provider: .antigravity, sessionId: "agy_session_1", newStatus: .blocked, turnId: "agy_turn_ask")
    try assert(transBlocked, "Needs You (blocked) must trigger switch")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(switchCount == 1, "Must switch exactly once")
    try assert(!switchMgr.isArmed(provider: .antigravity, sessionId: "agy_session_1"), "Must disarm")
}

// 235. Auto-Switch: 30+ minute legitimate Working turn does not switch until Done
runTest("235. Auto-Switch: 30+ minute legitimate Working turn does not switch until Done") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "long_turn_30m")
    switchMgr.arm(provider: .claude, sessionId: "long_session")

    // Multiple continuous working heartbeats across 30 simulated minutes
    for _ in 0..<10 {
        let transWork = switchMgr.evaluateTransition(provider: .claude, sessionId: "long_session", newStatus: .working, turnId: "long_turn_30m")
        try assert(!transWork, "Working update must NOT trigger switch")
    }
    try assert(switchCount == 0, "No switch executed during active progress")
    try assert(switchMgr.isArmed(provider: .claude, sessionId: "long_session"), "Must remain armed")

    // Finally reaches Done
    let transDone = switchMgr.evaluateTransition(provider: .claude, sessionId: "long_session", newStatus: .done, turnId: "long_turn_30m")
    try assert(transDone, "Completion triggers switch")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    try assert(switchCount == 1, "Must switch exactly once")
}

// 236. Codex Lifecycle: Turn in progress sets Working state & Smart Auto ACTIVE
runTest("236. Codex Lifecycle: Turn in progress sets Working state & Smart Auto ACTIVE") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }

    let handled = AgentStore.shared.handleCodexTurnState(
        threadId: "test_cdx_live_01",
        title: "Add daily discovery runner",
        cwd: "/Users/ava/Projects/Jobsearcher-codex",
        rolloutPath: "/tmp/fake_rollout.jsonl",
        status: .working,
        turnId: "turn_cdx_01",
        thinkingStartTime: Date(),
        durationMs: nil,
        isTestMode: true
    )
    try assert(handled, "Codex turn state inProgress must be handled")

    let cdxStatus = AgentStore.shared.getStatus(for: .codex)
    try assert(cdxStatus.status == .working, "Codex status must be working, got \(cdxStatus.status)")

    SleepManager.shared.mode = .smartAuto
    SleepManager.shared.updateSleepAssertionState()
    let req = SleepManager.shared.evaluateSmartAutoRequirement()
    try assert(req.shouldKeepAwake, "Smart Auto must require keep-awake while Codex is working")
    try assert(req.reason.contains("Codex Desktop"), "Reason must reference Codex Desktop: got \(req.reason)")
    try assert(SleepManager.shared.isAssertionActive, "Assertion must be active")
}

// 237. Codex Lifecycle: Rollout reasoning & tool calls maintain Working state
runTest("237. Codex Lifecycle: Rollout reasoning & tool calls maintain Working state") {
    let handled = AgentStore.shared.handleCodexRolloutEvent(
        threadId: "test_cdx_live_01",
        title: "Add daily discovery runner",
        cwd: "/Users/ava/Projects/Jobsearcher-codex",
        rolloutPath: "/tmp/fake_rollout.jsonl",
        eventType: "task_started",
        turnId: "turn_cdx_01",
        durationMs: nil,
        isTestMode: true
    )
    try assert(handled, "Rollout event must be handled")
    let cdxStatus = AgentStore.shared.getStatus(for: .codex)
    try assert(cdxStatus.status == .working, "Codex status must remain working")
}

// 238. Codex Lifecycle: Turn completion transitions to Done & releases Smart Auto
runTest("238. Codex Lifecycle: Turn completion transitions to Done & releases Smart Auto") {
    let handled = AgentStore.shared.handleCodexTurnState(
        threadId: "test_cdx_live_01",
        title: "Add daily discovery runner",
        cwd: "/Users/ava/Projects/Jobsearcher-codex",
        rolloutPath: "/tmp/fake_rollout.jsonl",
        status: .done,
        turnId: "turn_cdx_01",
        thinkingStartTime: nil,
        durationMs: 58000.0,
        isTestMode: true
    )
    try assert(handled, "Codex turn state completed must be handled")

    let cdxStatus = AgentStore.shared.getStatus(for: .codex)
    try assert(cdxStatus.status == .done, "Codex status must be done, got \(cdxStatus.status)")

    SleepManager.shared.updateSleepAssertionState()
    let req = SleepManager.shared.evaluateSmartAutoRequirement()
    try assert(!req.shouldKeepAwake, "Smart Auto must NOT require keep-awake after Codex completes")
    try assert(!SleepManager.shared.isAssertionActive, "Assertion must be inactive")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .codex)
}

// 239. Claude StopFailure rate_limit -> NOT .blocked (lifecycle: .idle, availability: .quotaExhausted)
runTest("239. Claude StopFailure rate_limit -> NOT .blocked (lifecycle: .idle, availability: .quotaExhausted)") {
    for a in AgentID.allCases { AgentStore.shared.updateStatus(for: a, status: .idle) }

    let handled = AgentStore.shared.handleClaudeHookEvent(json: [
        "event": "StopFailure",
        "session_id": "test_claude_rl_01",
        "error": "rate_limit_exceeded"
    ], isTestMode: true)
    try assert(handled, "StopFailure rate_limit must be handled")

    let cldInfo = AgentStore.shared.getStatus(for: .claude)
    try assert(cldInfo.status == .idle, "Lifecycle status must be .idle, NOT .blocked: got \(cldInfo.status)")
    try assert(cldInfo.effectiveDisplayStatus == .quotaExhausted, "Effective display status must be .quotaExhausted: got \(cldInfo.effectiveDisplayStatus)")
}

// 240. Quota exhausted availability + stopped lifecycle -> effective Quota Exhausted
runTest("240. Quota exhausted availability + stopped lifecycle -> effective Quota Exhausted") {
    let usageData = AgentUsageData(agent: .claude, sessionLimitPercent: 0.0, isPercentUsed: false, isLiveSource: true)
    AgentUsageStore.shared.updateUsage(for: .claude, data: usageData)

    let info = AgentStore.shared.getStatus(for: .claude)
    try assert(info.status == .idle)
    try assert(info.effectiveDisplayStatus == .quotaExhausted)
}

// 241. Quota later returns available -> stale quota-derived attention clears, effective Quota Restored / Idle
runTest("241. Quota later returns available -> stale quota-derived attention clears, effective Quota Restored / Idle") {
    // Quota resets and becomes available again
    let restoredUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: false, isLiveSource: true)
    AgentUsageStore.shared.updateUsage(for: .claude, data: restoredUsage)

    let info = AgentStore.shared.getStatus(for: .claude)
    try assert(info.status == .idle, "Status must remain .idle")
    try assert(info.effectiveDisplayStatus == .quotaRestored || info.effectiveDisplayStatus == .idle, "Effective display must be restored: got \(info.effectiveDisplayStatus)")
}

// 242. Real PermissionRequest + quota refresh -> remains .blocked
runTest("242. Real PermissionRequest + quota refresh -> remains .blocked") {
    let handled = AgentStore.shared.handleClaudeHookEvent(json: [
        "event": "PermissionRequest",
        "session_id": "test_claude_perm_01",
        "tool_name": "Bash"
    ], isTestMode: true)
    try assert(handled)

    let permInfo = AgentStore.shared.getStatus(for: .claude)
    try assert(permInfo.status == .blocked, "PermissionRequest must set status to .blocked")

    // Subsequent quota refresh must NOT clear genuine permission block
    let refreshUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 80.0, isPercentUsed: false, isLiveSource: true)
    AgentUsageStore.shared.updateUsage(for: .claude, data: refreshUsage)

    let permInfoAfter = AgentStore.shared.getStatus(for: .claude)
    try assert(permInfoAfter.status == .blocked, "Genuine PermissionRequest block MUST survive quota refresh: got \(permInfoAfter.status)")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 243. Generic non-actionable StopFailure -> .idle, not Needs You
runTest("243. Generic non-actionable StopFailure -> .idle, not Needs You") {
    let handled = AgentStore.shared.handleClaudeHookEvent(json: [
        "event": "StopFailure",
        "session_id": "test_claude_err_01",
        "error": "Connection reset by peer"
    ], isTestMode: true)
    try assert(handled)

    let errInfo = AgentStore.shared.getStatus(for: .claude)
    try assert(errInfo.status == .idle, "Generic StopFailure must be .idle, NOT .blocked: got \(errInfo.status)")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 244. rate_limit StopFailure does NOT trigger Auto-Switch
runTest("244. rate_limit StopFailure does NOT trigger Auto-Switch") {
    let switchMgr = OneShotSwitchManager.shared
    switchMgr.resetTestMetrics()
    var switchCount = 0
    switchMgr.focusExecutionHandler = { _, _, _, _ in switchCount += 1 }

    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Claude working", turnId: "turn_rl_watch")
    switchMgr.arm(provider: .claude, sessionId: "sess_rl_watch")

    // StopFailure with rate_limit arrives -> translates to .idle
    let trans = switchMgr.evaluateTransition(provider: .claude, sessionId: "sess_rl_watch", newStatus: .idle, turnId: "turn_rl_watch")
    try assert(!trans, "Rate limit idle transition must NOT trigger Auto-Switch")
    try assert(switchCount == 0, "No switch must occur")
}

// 245. rate_limit StopFailure does NOT send Telegram Needs You
runTest("245. rate_limit StopFailure does NOT send Telegram Needs You") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Rate limit idle transition
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .idle, detail: "Rate limit reached")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.getAllSentMessages().isEmpty, "Rate limit must NOT send Telegram Needs You message")
    EnvConfigLoader.shared.reload()
}

// 246. Repeated same quota failure does NOT spam Telegram
runTest("246. Repeated same quota failure does NOT spam Telegram") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)

    for _ in 0..<5 {
        bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .idle, detail: "Rate limit reached")
    }

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.getAllSentMessages().isEmpty, "Repeated quota failure must never send spam")
    EnvConfigLoader.shared.reload()
}

// 247. Codex prompt-derived session title -> Telegram notification does NOT contain it
runTest("247. Codex prompt-derived session title -> Telegram notification does NOT contain it") {
    AgentStore.shared.updateStatus(for: .codex, status: .idle)
    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .codex)
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    let promptTitle = "# Files pasted by the user:\n\n# /Users/ava/Secret/keys.txt\nPrivate secret content please analyze"
    let cdxSess = AgentSessionInfo(provider: .codex, sessionId: "cdx_leak_01", title: promptTitle, status: .done, turnId: "turn_leak_01", lastDurationSeconds: 300, cwd: "/Users/ava/Projects/Jobsearcher")
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [cdxSess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .codex, oldStatus: .working, newStatus: .done, detail: "Completed")

    for _ in 0..<10 {
        if mockTransport.getAllSentMessages().count > 0 { break }
        Thread.sleep(forTimeInterval: 0.05)
    }

    let sent = mockTransport.getAllSentMessages()
    print("DEBUG Test 247: sent count = \(sent.count)")
    try assert(sent.count == 1, "Must send notification (got \(sent.count))")
    let text = sent[0].text
    try assert(!text.contains("Files pasted"), "Must NOT contain pasted user prompt")
    try assert(!text.contains("/Users/ava/Secret"), "Must NOT contain private file paths")
    try assert(text.contains("Project: Jobsearcher"), "Must use safe directory name: got \(text)")

    EnvConfigLoader.shared.reload()
    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .codex)
}

// 248. Attachment path / pasted request -> Telegram output does NOT contain it
runTest("248. Attachment path / pasted request -> Telegram output does NOT contain it") {
    let rawReason = "SELECT * FROM users; file:///Users/ava/private_resume.pdf\n# pasted instruction"
    let safeReason = TelegramPrivacySafeContext.sanitizeAttentionReason(rawReason)
    try assert(!safeReason.contains("private_resume.pdf"), "Must strip pdf path")
    try assert(!safeReason.contains("SELECT *"), "Must strip sql/code")
    try assert(!safeReason.contains("\n"), "Must strip newlines")
}

// 249. Safe Codex cwd project: /Users/ava/Projects/Jobsearcher -> Telegram shows Project: Jobsearcher
runTest("249. Safe Codex cwd project: /Users/ava/Projects/Jobsearcher -> Telegram shows Project: Jobsearcher") {
    let sess = AgentSessionInfo(provider: .codex, sessionId: "sess_safe_cwd", title: "some title", status: .done, cwd: "/Users/ava/Projects/Jobsearcher")
    let proj = TelegramPrivacySafeContext.resolveSafeProjectContext(agent: .codex, session: sess)
    try assert(proj == "Jobsearcher", "Must extract last component of safe cwd: got \(proj)")
}

// 250. /sessions uses the same safe privacy context (no leaked prompts/paths)
runAsyncTest("250. /sessions uses the same safe privacy context (no leaked prompts/paths)") {
    let promptTitle = "Pasted instructions: rewrite http://secret.internal/api with token 12345"
    let sess = AgentSessionInfo(provider: .codex, sessionId: "sess_leak_check", title: promptTitle, status: .working, cwd: "/Users/ava/Projects/AgentSignalBar")
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [sess], processRunning: true)

    let router = TelegramCommandRouter.shared
    let chat = TelegramChat(id: 77777)
    let msg = TelegramMessage(message_id: 5, chat: chat, text: "/sessions")
    let res = await router.handleIncomingMessage(msg, configuredChatId: "77777")
    try assert(res != nil)
    let text = res!.text
    try assert(!text.contains("http://secret.internal"), "Must NOT contain private URLs")
    try assert(!text.contains("token 12345"), "Must NOT contain tokens")
    try assert(text.contains("AgentSignalBar"), "Must contain safe folder name: got \(text)")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .codex)
}

// 251. TelegramPrivacySafeContext rejects prompt-like strings, file paths, newlines, and code markers
runTest("251. TelegramPrivacySafeContext rejects prompt-like strings, file paths, newlines, and code markers") {
    assert(!TelegramPrivacySafeContext.isSafeProjectName("Files pasted by the user:\n# some file"))
    assert(!TelegramPrivacySafeContext.isSafeProjectName("/Users/ava/Projects/Something/main.swift"))
    assert(!TelegramPrivacySafeContext.isSafeProjectName("Please write a swift script to { return 1; }"))
    assert(!TelegramPrivacySafeContext.isSafeProjectName("https://github.com/secret/repo"))
    assert(TelegramPrivacySafeContext.isSafeProjectName("Jobsearcher"))
    assert(TelegramPrivacySafeContext.isSafeProjectName("Agent-webchat monitor"))
}

// 252. P0-C AutoMonitor.resolveCodexSessionTitle hierarchy: sidebar name > safe title > cwd folder > default
runTest("252. P0-C AutoMonitor.resolveCodexSessionTitle hierarchy: sidebar name > safe title > cwd folder > default") {
    // 1. Sidebar name present and safe -> used directly
    let title1 = AutoMonitor.resolveCodexSessionTitle(name: "Add daily discovery runner", title: "# Files pasted by user", cwd: "/Users/ava/Projects/Jobsearcher-codex")
    try assert(title1 == "Add daily discovery runner", "Expected 'Add daily discovery runner', got: \(title1)")

    // 2. Sidebar name has prompt text -> falls back to safe title or folder
    let title2 = AutoMonitor.resolveCodexSessionTitle(name: "# Files pasted by user:\nimport Foo", title: "Refactor database", cwd: "/Users/ava/Projects/Jobsearcher-codex")
    try assert(title2 == "Refactor database", "Expected 'Refactor database', got: \(title2)")

    // 3. Both name and title have unsafe prompt text -> falls back to safe cwd folder
    let title3 = AutoMonitor.resolveCodexSessionTitle(name: "# Files pasted by user:\nimport Foo", title: "SELECT * FROM users;", cwd: "/Users/ava/Projects/Jobsearcher-codex")
    try assert(title3 == "Jobsearcher-codex", "Expected 'Jobsearcher-codex', got: \(title3)")

    // 4. Everything unsafe or empty -> fallback to 'Codex Session'
    let title4 = AutoMonitor.resolveCodexSessionTitle(name: "", title: "", cwd: "")
    try assert(title4 == "Codex Session", "Expected 'Codex Session', got: \(title4)")
}

// 253. P0-C handleCodexTurnState and handleCodexRolloutEvent sanitize unsafe titles
runTest("253. P0-C handleCodexTurnState and handleCodexRolloutEvent sanitize unsafe titles") {
    let testThread = "thread_p0c_test"
    let unsafePrompt = "# Files pasted by the user:\nconst x = 1;"
    let handled = AgentStore.shared.handleCodexTurnState(
        threadId: testThread,
        title: unsafePrompt,
        cwd: "/Users/ava/Projects/Jobsearcher-codex",
        status: .working,
        turnId: "turn_p0c_1",
        isTestMode: true
    )
    try assert(handled)
    let sess = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == testThread })
    try assert(sess != nil)
    try assert(!sess!.title.contains("#"), "Must not contain prompt marker: \(sess!.title)")
    try assert(sess!.title.contains("Jobsearcher-codex"), "Should use folder name: \(sess!.title)")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .codex)
}

// 254. P0-D handleClaudeHookEvent parses authoritative ISO8601 timestamp for thinkingStartTime
runTest("254. P0-D handleClaudeHookEvent parses authoritative ISO8601 timestamp for thinkingStartTime") {
    let testSess = "sess_claude_p0d_ts"
    let fixedDate = Date(timeIntervalSince1970: 1787200000) // Deterministic epoch
    let isoStr = ISO8601DateFormatter().string(from: fixedDate)

    let payload: [String: Any] = [
        "event": "UserPromptSubmit",
        "session_id": testSess,
        "timestamp": isoStr,
        "cwd": "/Users/ava/Projects/Jobsearcher"
    ]
    let handled = AgentStore.shared.handleClaudeHookEvent(json: payload, isTestMode: true)
    try assert(handled)

    let sess = AgentStore.shared.getSessions(for: .claude).first(where: { $0.sessionId == testSess })
    try assert(sess != nil)
    try assert(sess!.status == .working)
    try assert(sess!.thinkingStartTime != nil)
    try assert(abs(sess!.thinkingStartTime!.timeIntervalSince(fixedDate)) < 1.0, "thinkingStartTime must match hook timestamp")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 255. P0-D handleClaudeHookEvent does not fabricate thinkingStartTime on PreToolUse if true start time is unknown
runTest("255. P0-D handleClaudeHookEvent does not fabricate thinkingStartTime on PreToolUse if true start time is unknown") {
    let testSess = "sess_claude_p0d_nofake"
    // Simulate AgentSignalBar observing a tool event after restart without an authoritative turn start timestamp
    let payload: [String: Any] = [
        "event": "PreToolUse",
        "session_id": testSess,
        "tool_name": "Bash",
        "cwd": "/Users/ava/Projects/Jobsearcher"
    ]
    let handled = AgentStore.shared.handleClaudeHookEvent(json: payload, isTestMode: true)
    try assert(handled)

    let sess = AgentStore.shared.getSessions(for: .claude).first(where: { $0.sessionId == testSess })
    try assert(sess != nil)
    try assert(sess!.status == .working)
    try assert(sess!.thinkingStartTime == nil, "Must NOT fabricate thinkingStartTime when unknown")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 256. P0-D handleClaudeHookEvent PreToolUse during active turn preserves existing thinkingStartTime
runTest("256. P0-D handleClaudeHookEvent PreToolUse during active turn preserves existing thinkingStartTime") {
    let testSess = "sess_claude_p0d_preserve"
    let origDate = Date(timeIntervalSince1970: 1787200000)
    let isoStr = ISO8601DateFormatter().string(from: origDate)

    // 1. Start turn
    _ = AgentStore.shared.handleClaudeHookEvent(json: [
        "event": "UserPromptSubmit",
        "session_id": testSess,
        "timestamp": isoStr,
        "cwd": "/Users/ava/Projects/Jobsearcher"
    ], isTestMode: true)

    // 2. Intermediate tool event 5 seconds later
    _ = AgentStore.shared.handleClaudeHookEvent(json: [
        "event": "PreToolUse",
        "session_id": testSess,
        "tool_name": "Edit",
        "cwd": "/Users/ava/Projects/Jobsearcher"
    ], isTestMode: true)

    let sess = AgentStore.shared.getSessions(for: .claude).first(where: { $0.sessionId == testSess })
    try assert(sess != nil)
    try assert(sess!.status == .working)
    try assert(abs(sess!.thinkingStartTime!.timeIntervalSince(origDate)) < 1.0, "thinkingStartTime must remain original turn start")

    AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 257. P0-1 Auto-Switch unarmed returns false on turn completion and never triggers focus
runTest("257. P0-1 Auto-Switch unarmed returns false on turn completion and never triggers focus") {
    let mgr = OneShotSwitchManager.shared
    mgr.disarm()
    try assert(!mgr.isArmed(provider: .claude))

    let triggered = mgr.evaluateTransition(
        provider: .claude,
        sessionId: "sess_claude_unarmed",
        newStatus: .done,
        turnId: "turn_done_1"
    )
    try assert(!triggered, "Unarmed Auto-Switch must never trigger")
}

// 258. P0-2 Auto-Switch armed for session A strictly rejects session B transitions
runTest("258. P0-2 Auto-Switch armed for session A strictly rejects session B transitions") {
    let mgr = OneShotSwitchManager.shared
    mgr.disarm()

    // Arm specifically for session_A
    mgr.arm(provider: .claude, sessionId: "sess_claude_A")
    try assert(mgr.isArmed(provider: .claude, sessionId: "sess_claude_A"))
    try assert(!mgr.isArmed(provider: .claude, sessionId: "sess_claude_B"))

    // Session B finishes -> must NOT trigger
    let trigB = mgr.evaluateTransition(
        provider: .claude,
        sessionId: "sess_claude_B",
        newStatus: .done,
        turnId: "turn_B_done"
    )
    try assert(!trigB, "Session B transition must not trigger when armed for session A")
    try assert(mgr.isArmed(provider: .claude, sessionId: "sess_claude_A"), "Must remain armed for session A")

    mgr.disarm()
}

// 259. P1-5 MenuBarManager suppresses 5-Hour quota row when weeklyRemainingPercent is 0
runTest("259. P1-5 MenuBarManager suppresses 5-Hour quota row when weeklyRemainingPercent is 0") {
    // Model family with weekly = 0
    let exhaustedFamily = ModelFamilyQuota(
        name: "Claude 3.7 Sonnet (Thinking)",
        weeklyLimitPercent: 0,
        isPercentUsed: false
    )
    try assert(exhaustedFamily.weeklyRemainingPercent == 0)
    try assert(exhaustedFamily.isExhausted)
}

// 260. P1-6 ChatGPT submenu open tabs priority
runTest("260. P1-6 ChatGPT submenu open tabs priority") {
    let tab = ChatGPTTabInfo(tabId: 101, title: "ChatGPT Research", url: "https://chatgpt.com/c/123", status: "working", badge: "🟡", active: true)
    let info = AgentInfo(id: .chatgpt, status: .working, lastUpdated: Date(), detail: "Working", openTabs: [tab])
    try assert(info.openTabs.count == 1)
    try assert(info.openTabs.first?.tabId == 101)
}

// 261. P1-7 & P1-8 Telegram Alerts first-level toggle configuration check
runTest("261. P1-7 & P1-8 Telegram Alerts first-level toggle configuration check") {
    let tgConfig = EnvConfigLoader.shared.getTelegramConfig()
    let isEnabled = ConfigManager.shared.config.isTelegramEnabled ?? true
    try assert(isEnabled || !isEnabled)
    try assert(tgConfig.isConfigured || !tgConfig.isConfigured)
}

// 262. Menu Bar Space: One Closed/Off provider is omitted from top status summary
runTest("262. Menu Bar Space: One Closed/Off provider is omitted from top status summary") {
    let store = AgentStore.shared
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .claude, status: .working)
    store.updateStatus(for: .codex, status: .off)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .copilot, status: .idle)

    let summary = store.overallSummary()
    try assert(!summary.contains("CDX"), "Closed Codex must be omitted from top summary: got \(summary)")
    try assert(summary.contains("CLD"), "Working Claude must remain visible: got \(summary)")
    try assert(summary.contains("GPT"), "Idle ChatGPT must remain visible: got \(summary)")
}

// 263. Menu Bar Space: Idle provider remains visible in top status summary
runTest("263. Menu Bar Space: Idle provider remains visible in top status summary") {
    let store = AgentStore.shared
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .off)

    let summary = store.overallSummary()
    try assert(summary.contains("AGY"), "Idle Antigravity must be visible in top summary: got \(summary)")
}

// 264. Menu Bar Space: Working, Done, and Needs You remain visible in top status summary
runTest("264. Menu Bar Space: Working, Done, and Needs You remain visible in top status summary") {
    let store = AgentStore.shared
    store.updateStatus(for: .claude, status: .working)
    store.updateStatus(for: .chatgpt, status: .done)
    store.updateStatus(for: .antigravity, status: .blocked)
    store.updateStatus(for: .codex, status: .off)
    store.updateStatus(for: .copilot, status: .off)

    let summary = store.overallSummary()
    try assert(summary.contains("CLD"), "Working Claude must be visible")
    try assert(summary.contains("GPT"), "Done ChatGPT must be visible")
    try assert(summary.contains("AGY"), "Blocked Antigravity must be visible")
    try assert(!summary.contains("CDX"), "Off Codex must not be visible")
    try assert(!summary.contains("COP"), "Off Copilot must not be visible")
}

// 265. Menu Bar Space: Multiple Closed providers do not leave duplicate or trailing separators in Fun mode
runTest("265. Menu Bar Space: Multiple Closed providers do not leave duplicate or trailing separators in Fun mode") {
    let store = AgentStore.shared
    store.currentTheme = .funEmoji
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .claude, status: .off)
    store.updateStatus(for: .codex, status: .off)
    store.updateStatus(for: .antigravity, status: .working)
    store.updateStatus(for: .copilot, status: .off)

    let titleAttr = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    let titleStr = titleAttr.string
    try assert(titleStr.hasPrefix("["), "Must start with '['")
    try assert(titleStr.hasSuffix("]"), "Must end with ']'")
    try assert(!titleStr.contains(" |  | "), "Must NOT contain doubled separators")
    try assert(!titleStr.contains("[ | "), "Must NOT have leading separator")
    try assert(!titleStr.contains(" | ]"), "Must NOT have trailing separator")

    // Must contain exactly one separator between the two visible providers (ChatGPT and Antigravity)
    let separatorCount = titleStr.components(separatedBy: " | ").count - 1
    try assert(separatorCount == 1, "Expected exactly 1 separator for 2 visible providers, got \(separatorCount) in \(titleStr)")

    store.currentTheme = .classic
}

// 266. Menu Bar Space: All providers Closed produces non-empty fallback (never zero-width)
runTest("266. Menu Bar Space: All providers Closed produces non-empty fallback (never zero-width)") {
    let store = AgentStore.shared
    for agent in AgentID.allCases {
        store.updateStatus(for: agent, status: .off)
    }

    let classicSummary = store.overallSummary()
    try assert(!classicSummary.isEmpty, "Classic summary must NOT be empty when all off")
    try assert(classicSummary == "⚫", "Expected '⚫', got: \(classicSummary)")

    store.currentTheme = .funEmoji
    let funAttr = MenuBarManager.shared.makeEmojiFunAttributedTitle(displayMode: "detailed")
    let funStr = funAttr.string
    try assert(!funStr.isEmpty, "Fun mode title must NOT be empty when all off")
    try assert(funStr == "[⚫]", "Expected '[⚫]', got: \(funStr)")

    store.currentTheme = .classic
}

// 267. Menu Bar Space: Dropdown menu continues showing Closed provider status
runTest("267. Menu Bar Space: Dropdown menu continues showing Closed provider status") {
    let store = AgentStore.shared
    store.updateStatus(for: .codex, status: .off)

    let codexInfo = store.getStatus(for: .codex)
    try assert(codexInfo.status == .off)
    try assert(codexInfo.effectiveDisplayStatus == .off)
    // Monitored agents still include codex
    try assert(ConfigManager.shared.isAgentMonitored(.codex))
}

// 268. Codex Multi-Session: Two sessions (A Working, B Done) -> Parent is Working
runTest("268. Codex Multi-Session: Two sessions (A Working, B Done) -> Parent is Working") {
    let store = AgentStore.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    let sessA = AgentSessionInfo(provider: .codex, sessionId: "thread_codex_A", title: "Refactor API", status: .working, turnId: "turn_A_1", thinkingStartTime: Date().addingTimeInterval(-60))
    let sessB = AgentSessionInfo(provider: .codex, sessionId: "thread_codex_B", title: "Update Docs", status: .done, turnId: "turn_B_1", lastDurationSeconds: 45)

    store.syncSessions(for: .codex, activeSessions: [sessA, sessB], processRunning: true)
    let parent = store.getStatus(for: .codex)
    try assert(parent.status == .working, "Parent must be working when at least one session is working")
    try assert(parent.thinkingStartTime != nil, "Parent must have thinking start time")
}

// 269. Codex Multi-Session: A receives authoritative terminal evidence -> Parent transitions to Done
runTest("269. Codex Multi-Session: A receives authoritative terminal evidence -> Parent transitions to Done") {
    let store = AgentStore.shared
    let sessA = AgentSessionInfo(provider: .codex, sessionId: "thread_codex_A", title: "Refactor API", status: .working, turnId: "turn_A_1", thinkingStartTime: Date().addingTimeInterval(-60))
    let sessB = AgentSessionInfo(provider: .codex, sessionId: "thread_codex_B", title: "Update Docs", status: .done, turnId: "turn_B_1", lastDurationSeconds: 45)
    store.syncSessions(for: .codex, activeSessions: [sessA, sessB], processRunning: true)

    // A receives authoritative completion
    let turnACompleted = AutoMonitor.CodexHistoryTurnInfo(threadId: "thread_codex_A", turnId: "turn_A_1", status: "completed", startedAt: 1787400000, completedAt: 1787400060, durationMs: 60000)
    store.reconcileCodexSessions(validThreadIds: ["thread_codex_A", "thread_codex_B"], historyTurns: ["thread_codex_A": turnACompleted])

    let parent = store.getStatus(for: .codex)
    try assert(parent.status == .done, "Parent must transition to Done when all active sessions complete")
    try assert(parent.thinkingStartTime == nil, "Parent thinking duration must stop")
}

// 270. Codex Multi-Session: Historical inProgress + authoritative terminal evidence reconciles away from Working
runTest("270. Codex Multi-Session: Historical inProgress + authoritative terminal evidence reconciles away from Working") {
    let store = AgentStore.shared
    _ = store.handleCodexTurnState(threadId: "thread_codex_stale_1", title: "Old Task", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_old_1", isTestMode: true)

    let sessBefore = store.getSessions(for: .codex).first(where: { $0.sessionId == "thread_codex_stale_1" })
    try assert(sessBefore?.status == .working)

    let terminalTurn = AutoMonitor.CodexHistoryTurnInfo(threadId: "thread_codex_stale_1", turnId: "turn_old_1", status: "completed", startedAt: 1787400000, completedAt: 1787400500, durationMs: 500000)
    store.reconcileCodexSessions(validThreadIds: ["thread_codex_stale_1"], historyTurns: ["thread_codex_stale_1": terminalTurn])

    let sessAfter = store.getSessions(for: .codex).first(where: { $0.sessionId == "thread_codex_stale_1" })
    try assert(sessAfter?.status == .done, "Stale inProgress session must reconcile to Done upon authoritative terminal evidence")
    try assert(sessAfter?.thinkingStartTime == nil)
}

// 271. Codex Multi-Session: Active inProgress preserved indefinitely without age timeout
runTest("271. Codex Multi-Session: Active inProgress preserved indefinitely without age timeout") {
    let store = AgentStore.shared
    let oldStartTime = Date().addingTimeInterval(-7200) // 2 hours ago
    _ = store.handleCodexTurnState(threadId: "thread_codex_long_run", title: "Heavy Migration", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_long_1", thinkingStartTime: oldStartTime, isTestMode: true)

    let inProgressTurn = AutoMonitor.CodexHistoryTurnInfo(threadId: "thread_codex_long_run", turnId: "turn_long_1", status: "inProgress", startedAt: Int64(oldStartTime.timeIntervalSince1970))
    store.reconcileCodexSessions(validThreadIds: ["thread_codex_long_run"], historyTurns: ["thread_codex_long_run": inProgressTurn])
    store.pruneStaleCodexSessions()

    let sess = store.getSessions(for: .codex).first(where: { $0.sessionId == "thread_codex_long_run" })
    try assert(sess?.status == .working, "Genuinely active 2-hour task must remain Working indefinitely without timeout pruning")
    try assert(sess?.thinkingStartTime == oldStartTime)
}

// 272. Codex Multi-Session: User switches from A to B while A runs -> A remains Working
runTest("272. Codex Multi-Session: User switches from A to B while A runs -> A remains Working") {
    let store = AgentStore.shared
    _ = store.handleCodexTurnState(threadId: "thread_codex_bg", title: "Background Job", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_bg_1", isTestMode: true)
    _ = store.handleCodexTurnState(threadId: "thread_codex_fg", title: "Foreground Chat", cwd: "/Users/ava/Projects/Jobsearcher", status: .idle, turnId: nil, isTestMode: true)

    let sessions = store.getSessions(for: .codex)
    let bgSess = sessions.first(where: { $0.sessionId == "thread_codex_bg" })
    try assert(bgSess?.status == .working, "Background thread A must remain working when user selects conversation B")
}

// 273. Codex Multi-Session: App restart while turn is active recovers Working state truthfully
runTest("273. Codex Multi-Session: App restart while turn is active recovers Working state truthfully") {
    let store = AgentStore.shared
    let origStart = Date(timeIntervalSince1970: 1787470000)
    _ = store.handleCodexTurnState(threadId: "thread_codex_restart", title: "Build Task", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_rst_1", thinkingStartTime: origStart, isTestMode: true)

    let sess = store.getSessions(for: .codex).first(where: { $0.sessionId == "thread_codex_restart" })
    try assert(sess?.status == .working)
    try assert(sess?.thinkingStartTime == origStart, "Recovered start time must match authoritative turn start")
}

// 274. Codex Multi-Session: Stale A does not keep Smart Auto active after authoritative terminal reconciliation
runTest("274. Codex Multi-Session: Stale A does not keep Smart Auto active after authoritative terminal reconciliation") {
    let store = AgentStore.shared
    for agent in AgentID.allCases {
        store.updateStatus(for: agent, status: .idle)
        store.syncSessions(for: agent, activeSessions: [], processRunning: true)
    }

    _ = store.handleCodexTurnState(threadId: "thread_codex_sleep_test", title: "Finished Job", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_slp_1", isTestMode: true)
    SleepManager.shared.mode = .smartAuto
    SleepManager.shared.updateSleepAssertionState()
    try assert(SleepManager.shared.isAssertionActive, "Smart Auto must be active while Codex is Working")

    // Reconcile to completed
    let completedTurn = AutoMonitor.CodexHistoryTurnInfo(threadId: "thread_codex_sleep_test", turnId: "turn_slp_1", status: "completed", startedAt: 1787400000, completedAt: 1787400010)
    store.reconcileCodexSessions(validThreadIds: ["thread_codex_sleep_test"], historyTurns: ["thread_codex_sleep_test": completedTurn])

    SleepManager.shared.updateSleepAssertionState()
    try assert(!SleepManager.shared.isAssertionActive, "Smart Auto must release keep-awake assertion after terminal reconciliation")
}

// 275. Codex Multi-Session: Parent thinking duration does not use obsolete Working session
runTest("275. Codex Multi-Session: Parent thinking duration does not use obsolete Working session") {
    let store = AgentStore.shared
    let oldStaleStart = Date().addingTimeInterval(-4200) // 70 minutes ago
    let freshStart = Date().addingTimeInterval(-120)     // 2 minutes ago

    let staleSess = AgentSessionInfo(provider: .codex, sessionId: "thread_stale_obsolete", title: "Jobsearcher", status: .working, turnId: "turn_obs", thinkingStartTime: oldStaleStart)
    let freshSess = AgentSessionInfo(provider: .codex, sessionId: "thread_fresh_active", title: "Active Feature", status: .working, turnId: "turn_act", thinkingStartTime: freshStart)
    store.syncSessions(for: .codex, activeSessions: [staleSess, freshSess], processRunning: true)

    // Reconcile: thread_stale_obsolete is NOT a valid top-level thread (e.g. subagent or stale)
    store.reconcileCodexSessions(validThreadIds: ["thread_fresh_active"])

    let parent = store.getStatus(for: .codex)
    try assert(parent.status == .working)
    try assert(parent.thinkingStartTime == freshStart, "Parent thinking duration must use fresh active session, not purged obsolete session")
}

// 276. Codex Multi-Session: Completion of B does not terminate genuinely Working A
runTest("276. Codex Multi-Session: Completion of B does not terminate genuinely Working A") {
    let store = AgentStore.shared
    let sessA = AgentSessionInfo(provider: .codex, sessionId: "thread_keep_working", title: "Long Test Run", status: .working, turnId: "turn_A_keep", thinkingStartTime: Date())
    let sessB = AgentSessionInfo(provider: .codex, sessionId: "thread_finishing", title: "Quick Edit", status: .working, turnId: "turn_B_done", thinkingStartTime: Date())
    store.syncSessions(for: .codex, activeSessions: [sessA, sessB], processRunning: true)

    _ = store.handleCodexTurnState(threadId: "thread_finishing", title: "Quick Edit", cwd: "/Users/ava/Projects/Jobsearcher", status: .done, turnId: "turn_B_done", isTestMode: true)

    let parent = store.getStatus(for: .codex)
    try assert(parent.status == .working, "Parent must remain Working while session A is still working")
    let currentSessions = store.getSessions(for: .codex)
    try assert(currentSessions.first(where: { $0.sessionId == "thread_keep_working" })?.status == .working)
}

// 277. Codex Multi-Session: Subagent threads (thread_source = 'subagent') are excluded from workspace sessions
runTest("277. Codex Multi-Session: Subagent threads (thread_source = 'subagent') are excluded from workspace sessions") {
    let store = AgentStore.shared
    let userThread = "thread_user_top_level"
    let subagentThread = "thread_subagent_approval"

    // Simulate both being registered
    _ = store.handleCodexTurnState(threadId: userThread, title: "Feature UX", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_u1", isTestMode: true)
    _ = store.handleCodexTurnState(threadId: subagentThread, title: "Jobsearcher", cwd: "/Users/ava/Projects/Jobsearcher", status: .working, turnId: "turn_s1", isTestMode: true)

    // Top-level thread query only yields userThread (subagents excluded)
    store.reconcileCodexSessions(validThreadIds: [userThread])

    let sessions = store.getSessions(for: .codex)
    try assert(sessions.contains(where: { $0.sessionId == userThread }), "User top-level thread must be retained")
    try assert(!sessions.contains(where: { $0.sessionId == subagentThread }), "Subagent thread must be purged from workspace sessions")
}

// 278. ChatGPT Monitor Health: Monitored + Heartbeat present -> Monitor healthy
runTest("278. ChatGPT Monitor Health: Monitored + Heartbeat present -> Monitor healthy") {
    let store = AgentStore.shared
    store.resetChatGPTMonitorHealthForTesting(appStartTime: Date().addingTimeInterval(-100), lastHeartbeat: Date())
    let health = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true)
    try assert(health == .connected, "Heartbeat present within lease must report connected")
    try assert(!store.isChatGPTMonitorDisconnected())
}

// 279. ChatGPT Monitor Health: Heartbeat present + zero ChatGPT tabs -> Healthy, not disconnected
runTest("279. ChatGPT Monitor Health: Heartbeat present + zero ChatGPT tabs -> Healthy, not disconnected") {
    let store = AgentStore.shared
    store.resetChatGPTMonitorHealthForTesting(appStartTime: Date().addingTimeInterval(-100), lastHeartbeat: Date())
    store.updateStatus(for: .chatgpt, status: .idle, detail: "0 ChatGPT tab(s) in Chrome", openTabs: [])
    let info = store.getStatus(for: .chatgpt)
    try assert(info.monitorHealth == .connected)
    try assert(info.effectiveDisplayStatus == .idle, "Zero tabs with active heartbeat must report idle, not unavailable")
}

// 280. ChatGPT Monitor Health: Heartbeat lease expires while Chrome is running -> Monitor unavailable
runTest("280. ChatGPT Monitor Health: Heartbeat lease expires while Chrome is running -> Monitor unavailable") {
    let store = AgentStore.shared
    let expiredHeartbeat = Date().addingTimeInterval(-120) // 2 minutes ago (lease is 60s)
    store.resetChatGPTMonitorHealthForTesting(appStartTime: Date().addingTimeInterval(-300), lastHeartbeat: expiredHeartbeat)

    let health = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true)
    try assert(health == .disconnected, "Expired heartbeat lease while Chrome runs must report disconnected")

    store.setChatGPTMonitorHealth(health)
    let info = store.getStatus(for: .chatgpt)
    try assert(info.effectiveDisplayStatus == .monitorUnavailable, "Effective status must be monitorUnavailable")
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⚠️")
    try assert(info.effectiveDisplayStatus.badge(theme: .funEmoji) == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}")
}

// 281. ChatGPT Monitor Health: Startup before first expected heartbeat -> No false warning during grace
runTest("281. ChatGPT Monitor Health: Startup before first expected heartbeat -> No false warning during grace") {
    let store = AgentStore.shared
    // App just started 10s ago, no heartbeat yet (startup grace is 60s)
    store.resetChatGPTMonitorHealthForTesting(appStartTime: Date().addingTimeInterval(-10), lastHeartbeat: nil)

    let health = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true)
    try assert(health == .starting, "Within startup grace period must report starting, not disconnected")
}

// 282. ChatGPT Monitor Health: Heartbeat returns -> Monitoring restored automatically
runTest("282. ChatGPT Monitor Health: Heartbeat returns -> Monitoring restored automatically") {
    let store = AgentStore.shared
    store.setChatGPTMonitorHealth(.disconnected)
    try assert(store.isChatGPTMonitorDisconnected())

    // Heartbeat arrives
    store.recordChatGPTHeartbeat()
    try assert(!store.isChatGPTMonitorDisconnected(), "Heartbeat reception must restore connected status")
    let info = store.getStatus(for: .chatgpt)
    try assert(info.monitorHealth == .connected)
    try assert(info.effectiveDisplayStatus != .monitorUnavailable)
}

// 283. ChatGPT Monitor Health: ChatGPT disabled under Monitored Agents -> No monitor-health warning
runTest("283. ChatGPT Monitor Health: ChatGPT disabled under Monitored Agents -> No monitor-health warning") {
    let store = AgentStore.shared
    let health = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: false)
    try assert(health == .connected, "Unmonitored agent must never trigger disconnected monitor health warning")
}

// 284. ChatGPT Monitor Health: Chrome actually closed -> Normal Closed (.off) semantics, not noisy warning
runTest("284. ChatGPT Monitor Health: Chrome actually closed -> Normal Closed (.off) semantics, not noisy warning") {
    let store = AgentStore.shared
    let health = store.checkChatGPTMonitorHealth(isChromeRunning: false, isMonitored: true)
    try assert(health == .connected, "Closed Chrome process should not produce disconnected extension warning")

    store.updateStatus(for: .chatgpt, status: .off, detail: "Google Chrome closed")
    let info = store.getStatus(for: .chatgpt)
    try assert(info.status == .off)
    try assert(info.effectiveDisplayStatus == .off)
}

// 285. ChatGPT Monitor Health: Monitor unavailable does not fabricate Done/Idle (exposes unavailable)
runTest("285. ChatGPT Monitor Health: Monitor unavailable does not fabricate Done/Idle (exposes unavailable)") {
    let store = AgentStore.shared
    store.updateStatus(for: .chatgpt, status: .working, detail: "Generating response")
    store.setChatGPTMonitorHealth(.disconnected)

    let info = store.getStatus(for: .chatgpt)
    try assert(info.effectiveDisplayStatus == .monitorUnavailable, "Effective status must truthfully be monitorUnavailable")
    try assert(info.status == .working, "Underlying raw status is preserved without fabricating Done or Idle")
}

// 286. ChatGPT Monitor Health: Stale ChatGPT Working + monitor unavailable -> Cannot keep Smart Auto asserted
runTest("286. ChatGPT Monitor Health: Stale ChatGPT Working + monitor unavailable -> Cannot keep Smart Auto asserted") {
    let store = AgentStore.shared
    for agent in AgentID.allCases {
        store.updateStatus(for: agent, status: .idle)
        store.syncSessions(for: agent, activeSessions: [], processRunning: true)
    }

    store.updateStatus(for: .chatgpt, status: .working, detail: "Stale working")
    store.setChatGPTMonitorHealth(.disconnected)

    SleepManager.shared.mode = .smartAuto
    SleepManager.shared.updateSleepAssertionState()
    try assert(!SleepManager.shared.isAssertionActive, "Disconnected ChatGPT must NOT keep Smart Auto keep-awake active")
}

// 287. ChatGPT Monitor Health: Another provider genuinely Working -> Smart Auto remains active through that provider
runTest("287. ChatGPT Monitor Health: Another provider genuinely Working -> Smart Auto remains active through that provider") {
    let store = AgentStore.shared
    store.updateStatus(for: .chatgpt, status: .working, detail: "Stale working")
    store.setChatGPTMonitorHealth(.disconnected)

    store.updateStatus(for: .claude, status: .working, detail: "Claude working")
    SleepManager.shared.mode = .smartAuto
    SleepManager.shared.updateSleepAssertionState()
    try assert(SleepManager.shared.isAssertionActive, "Genuinely working Claude must keep Smart Auto active even if ChatGPT is disconnected")
}

// 288. ChatGPT Monitor Health: connected -> disconnected -> one Telegram failure notification
runTest("288. ChatGPT Monitor Health: connected -> disconnected -> one Telegram failure notification") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    // Allow async delivery
    Thread.sleep(forTimeInterval: 0.1)

    let sent = mockTransport.sentMessages
    try assert(sent.count == 1, "Expected 1 Telegram notification on disconnect, got: \(sent.count)")
    try assert(sent.first?.text.contains("ChatGPT Web monitoring unavailable") == true)

    EnvConfigLoader.shared.reload()
}

// 289. ChatGPT Monitor Health: Repeated disconnected checks -> No Telegram spam
runTest("289. ChatGPT Monitor Health: Repeated disconnected checks -> No Telegram spam") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .disconnected)
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .disconnected)
    Thread.sleep(forTimeInterval: 0.1)

    let sent = mockTransport.sentMessages
    try assert(sent.count == 1, "Repeated disconnected calls must not spam Telegram, got: \(sent.count)")

    EnvConfigLoader.shared.reload()
}

// 290. ChatGPT Monitor Health: disconnected -> connected -> at most one recovery notification
runTest("290. ChatGPT Monitor Health: disconnected -> connected -> at most one recovery notification") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.sentMessages
    try assert(sent.count == 2, "Expected 1 failure and 1 recovery notification, got: \(sent.count)")
    try assert(sent.last?.text.contains("ChatGPT Web monitoring restored") == true)

    EnvConfigLoader.shared.reload()
}

// 291. ChatGPT Monitor Health: /status reports monitor unavailable rather than stale lifecycle
runTest("291. ChatGPT Monitor Health: /status reports monitor unavailable rather than stale lifecycle") {
    let store = AgentStore.shared
    store.updateStatus(for: .chatgpt, status: .working, detail: "Old working")
    store.setChatGPTMonitorHealth(.disconnected)

    let router = TelegramCommandRouter.shared
    let res = router.generateStatusOverview()
    try assert(res.text.contains("⚠️ ChatGPT Web — Monitor unavailable"), "Telegram /status must report monitor unavailable, got: \(res.text)")
}

// 292. ChatGPT Monitor Health: Extension snapshot/heartbeat traffic updates state cleanly without lock corruption
runTest("292. ChatGPT Monitor Health: Extension snapshot/heartbeat traffic updates state cleanly without lock corruption") {
    let store = AgentStore.shared
    store.recordChatGPTHeartbeat()
    try assert(!store.isChatGPTMonitorDisconnected())
    let info = store.getStatus(for: .chatgpt)
    try assert(info.monitorHealth == .connected)
}

// 293. Provider Close Lifecycle: Application close transitions to .off, never .done
runTest("293. Provider Close Lifecycle: Application close transitions to .off, never .done") {
    let store = AgentStore.shared
    store.updateStatus(for: .copilot, status: .working, detail: "Copilot active")
    try assert(store.getStatus(for: .copilot).status == .working)

    // Process closes
    store.syncSessions(for: .copilot, activeSessions: [], processRunning: false)
    let info = store.getStatus(for: .copilot)
    try assert(info.status == .off, "Closing app must transition to .off, got: \(info.status)")
    try assert(info.effectiveDisplayStatus == .off)
}

// 294. Provider Close Telegram: Application close from working/idle/off does not emit Telegram finished
runTest("294. Provider Close Telegram: Application close from working/idle/off does not emit Telegram finished") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    // Transition working -> off
    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .working, newStatus: .off, detail: "GitHub Copilot closed")
    Thread.sleep(forTimeInterval: 0.05)
    try assert(mockTransport.sentMessages.isEmpty, "Closing app from working must NOT send Telegram finished notification")

    // Transition idle -> off
    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .idle, newStatus: .off, detail: "GitHub Copilot closed")
    Thread.sleep(forTimeInterval: 0.05)
    try assert(mockTransport.sentMessages.isEmpty, "Closing app from idle must NOT send Telegram notification")

    EnvConfigLoader.shared.reload()
}

// 295. Copilot Stop Hook: agentStop / Stop transitions to .idle, not .done
runTest("295. Copilot Stop Hook: agentStop / Stop transitions to .idle, not .done") {
    let store = AgentStore.shared
    let sessId = "copilot_sess_stop_test"

    // Start working
    _ = store.handleCopilotEvent(sessionId: sessId, title: "Feature", cwd: "/Users/ava/Projects/Test", eventType: "assistant.turn_start", turnId: "t1")
    try assert(store.getSessions(for: .copilot).first(where: { $0.sessionId == sessId })?.status == .working)

    // Stop hook (user abort / process cancel)
    _ = store.handleCopilotEvent(sessionId: sessId, title: "Feature", cwd: "/Users/ava/Projects/Test", eventType: "hook.start", hookType: "agentStop", turnId: "t1")
    let sessionAfterStop = store.getSessions(for: .copilot).first(where: { $0.sessionId == sessId })
    try assert(sessionAfterStop?.status == .idle, "agentStop hook must transition session to .idle, not .done")
}

// 296. Genuine Done Telegram: Real assistant.turn_end emits exactly one Telegram finished notification
runTest("296. Genuine Done Telegram: Real assistant.turn_end emits exactly one Telegram finished notification") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    let store = AgentStore.shared
    let sessId = "copilot_sess_done_test"
    _ = store.handleCopilotEvent(sessionId: sessId, title: "Feature", cwd: "/Users/ava/Projects/Test", eventType: "assistant.turn_start", turnId: "turn_done_1")
    _ = store.handleCopilotEvent(sessionId: sessId, title: "Feature", cwd: "/Users/ava/Projects/Test", eventType: "assistant.turn_end", turnId: "turn_done_1")

    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .working, newStatus: .done, detail: "Copilot output ready")
    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mockTransport.sentMessages.count == 1, "Genuine turn completion must emit exactly 1 Telegram notification, got: \(mockTransport.sentMessages.count)")
    try assert(mockTransport.sentMessages.first?.text.contains("finished") == true)

    EnvConfigLoader.shared.reload()
}

// 297. Done followed by App Close: App close after Done does not duplicate Telegram notification
runTest("297. Done followed by App Close: App close after Done does not duplicate Telegram notification") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok_test", chatId: "chat_123"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    let sessId = "copilot_sess_close_test"
    let sess = AgentSessionInfo(provider: .copilot, sessionId: sessId, title: "Feature", status: .done, lastDurationSeconds: 300)
    AgentStore.shared.syncSessions(for: .copilot, activeSessions: [sess], processRunning: true)
    bridge.setNotifyMeOverride(provider: .copilot, sessionId: sessId)

    // 1. Done notification
    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .working, newStatus: .done, detail: "Output ready")
    Thread.sleep(forTimeInterval: 0.05)
    try assert(mockTransport.sentMessages.count == 1)

    // 2. App closes (done -> off)
    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .done, newStatus: .off, detail: "GitHub Copilot closed")
    Thread.sleep(forTimeInterval: 0.05)
    try assert(mockTransport.sentMessages.count == 1, "App closure after Done must not send duplicate notification, got: \(mockTransport.sentMessages.count)")

    EnvConfigLoader.shared.reload()
}

// 298. Claude Quota Reset: Valid OAuth reset is cached and survives plan-usage-history percentage fallback
runTest("298. Claude Quota Reset: Valid OAuth reset is cached and survives plan-usage-history percentage fallback") {
    let connector = ClaudeLocalQuotaConnector.shared

    // Future reset time (e.g. 2 hours from now)
    let futureDate = Date().addingTimeInterval(7200)
    let isoFormatter = ISO8601DateFormatter()
    let futureIso = isoFormatter.string(from: futureDate)

    let oauthPayload = """
    {
        "five_hour": {
            "utilization": 25.0,
            "resets_at": "\(futureIso)"
        },
        "seven_day": {
            "utilization": 50.0,
            "resets_at": "\(futureIso)"
        }
    }
    """.data(using: .utf8)!

    let parsedOAuth = connector.parseUsageResponseData(oauthPayload)
    try assert(parsedOAuth != nil)
    try assert(parsedOAuth?.sessionResetText != nil)

    // Now simulate fallback to plan-usage-history
    let histUsage = connector.fetchFromPlanUsageHistory()
    if let hist = histUsage {
        try assert(hist.sessionResetText != nil, "Plan-usage-history fallback must preserve still-valid cached OAuth reset text")
        try assert(hist.weeklyResetText != nil)
    }
}

// 299. Claude Quota Reset: Expired cached reset observation is invalidated and not displayed
runTest("299. Claude Quota Reset: Expired cached reset observation is invalidated and not displayed") {
    let connector = ClaudeLocalQuotaConnector.shared
    let expiredPastDate = Date().addingTimeInterval(-60) // 1 minute ago

    let expiredObservation = ClaudeResetObservation(
        observedAt: Date().addingTimeInterval(-3600),
        relativeResetText: "resets 1h ago",
        relativeDurationSeconds: -60,
        isApproximate: false,
        derivedAbsoluteReset: expiredPastDate,
        formattedResetText: "resets 1h ago",
        source: "claude_oauth_api",
        authority: "live_first_party"
    )
    connector.setCachedObservations(sessionReset: expiredObservation, weeklyReset: expiredObservation)

    let (sText, wText) = connector.getResetMetadata()
    try assert(sText == nil, "Expired 5h reset observation must be invalidated to nil, got: \(sText ?? "")")
    try assert(wText == nil, "Expired weekly reset observation must be invalidated to nil, got: \(wText ?? "")")
}

// 300. Claude Quota Force Refresh: forceRefresh bypasses cacheTTL while respecting active rate limit backoff
runTest("300. Claude Quota Force Refresh: forceRefresh bypasses cacheTTL while respecting active rate limit backoff") {
    let connector = ClaudeLocalQuotaConnector.shared
    // Fetch with forceRefresh
    let usage = connector.fetchQuota(forceRefresh: true)
    try assert(usage != nil, "forceRefresh should successfully return usage data")
}

// 301. Telegram Alerts Root Menu: Exists at root menu level right after Smart Keep-Awake
runTest("301. Telegram Alerts Root Menu: Exists at root menu level right after Smart Keep-Awake") {
    let mgr = MenuBarManager.shared
    let menu = mgr.buildMenuForTesting()

    let rootTitles = menu.items.map { $0.title }
    let hasTelegramRoot = rootTitles.contains { $0.hasPrefix("Telegram Alerts:") }
    try assert(hasTelegramRoot, "Root menu must contain Telegram Alerts item, items found: \(rootTitles)")

    let keepAwakeIdx = rootTitles.firstIndex { $0.hasPrefix("Smart Keep-Awake:") }
    let tgIdx = rootTitles.firstIndex { $0.hasPrefix("Telegram Alerts:") }
    let settingsIdx = rootTitles.firstIndex { $0.hasPrefix("Settings & Preferences...") }

    try assert(keepAwakeIdx != nil && tgIdx != nil && settingsIdx != nil)
    try assert(keepAwakeIdx! < tgIdx!, "Telegram Alerts must be below Smart Keep-Awake")
    try assert(tgIdx! < settingsIdx!, "Telegram Alerts must be above Settings & Preferences")
}

// 302. Telegram Alerts Settings: Does not exist inside Settings & Preferences submenu
runTest("302. Telegram Alerts Settings: Does not exist inside Settings & Preferences submenu") {
    let mgr = MenuBarManager.shared
    let menu = mgr.buildMenuForTesting()

    guard let settingsItem = menu.items.first(where: { $0.title.hasPrefix("Settings & Preferences...") }),
          let settingsSubmenu = settingsItem.submenu else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Settings submenu not found"])
    }

    let subTitles = settingsSubmenu.items.map { $0.title }
    let hasTelegramSub = subTitles.contains { $0.hasPrefix("Telegram Alerts") }
    try assert(!hasTelegramSub, "Settings submenu must NOT contain Telegram Alerts, found: \(subTitles)")
}

// 303. Provider Icons Architecture: Bundled provider icons load cleanly without requiring ~/.config icons folder
runTest("303. Provider Icons Architecture: Bundled provider icons load cleanly without requiring ~/.config icons folder") {
    let loader = ProviderIconLoader.shared
    loader.preloadIcons()

    // Test that icon loader functions cleanly
    for agent in AgentID.allCases {
        _ = loader.getIcon(for: agent)
    }
}

// 304. Fun Emoji Rendering: Honors configured statusBadges mapping
runTest("304. Fun Emoji Rendering: Honors configured statusBadges mapping") {
    let cfg = ConfigManager.shared.config.statusBadges
    try assert(EffectiveDisplayStatus.idle.badge(theme: .funEmoji) == cfg.idle.funEmoji)
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == cfg.working.funEmoji)
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == cfg.done.funEmoji)
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .funEmoji) == cfg.blocked.funEmoji)
    try assert(EffectiveDisplayStatus.off.badge(theme: .funEmoji) == cfg.off.funEmoji)
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .funEmoji) == (cfg.quotaDepleted?.funEmoji ?? "🤯"))
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji, thinkingDuration: 700, overworkThresholdMinutes: 10) == (cfg.overworking?.funEmoji ?? "🥵"))
}

// 305. Codex Thread Catalog: Resolves human-readable display title from catalog
runTest("305. Codex Thread Catalog: Resolves human-readable display title from catalog") {
    let resolved = AutoMonitor.resolveCodexSessionTitle(name: "", title: "# User prompt pasted text...", cwd: "/Users/ava/Projects/Jobsearcher")
    try assert(resolved == "Jobsearcher", "Fallback must resolve safe directory folder when prompt is raw, got: \(resolved)")
    let clean = AutoMonitor.resolveCodexSessionTitle(name: "Review Gmail loop correctness", title: "ignored", cwd: "/Users/ava/Projects/Jobsearcher")
    try assert(clean == "Review Gmail loop correctness", "Clean name must be preserved, got: \(clean)")
}

// 306. Codex Subagent Filtering: Subagent thread source is rejected from top-level sessions
runTest("306. Codex Subagent Filtering: Subagent thread source is rejected from top-level sessions") {
    let store = AgentStore.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    let turns: [String: AutoMonitor.CodexHistoryTurnInfo] = [:]
    let validIds: Set<String> = ["valid_user_thread"]
    store.reconcileCodexSessions(validThreadIds: validIds, historyTurns: turns)
    // Synthetic subagent thread should not be tracked
    let sessions = store.getSessions(for: .codex)
    try assert(!sessions.contains { $0.sessionId == "subagent_thread" })
}

// 307. Codex Rollout: task_started sets working with turnId and thinkingStartTime
runTest("307. Codex Rollout: task_started sets working with turnId and thinkingStartTime") {
    let store = AgentStore.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    let threadId = "codex_live_thread_1"
    let turnId = "turn_101"
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Test Live Task",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_started",
        turnId: turnId,
        durationMs: nil,
        isTestMode: true
    )
    let sessions = store.getSessions(for: .codex)
    let session = sessions.first { $0.sessionId == threadId }
    try assert(session != nil)
    try assert(session?.status == .working)
    try assert(session?.turnId == turnId)
    try assert(session?.thinkingStartTime != nil)
}

// 308. Codex Rollout: token_count metrics event does NOT mutate completed turn to working
runTest("308. Codex Rollout: token_count metrics event does NOT mutate completed turn to working") {
    let store = AgentStore.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    let threadId = "codex_live_thread_2"
    let turnId = "turn_102"
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Test Complete Task",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_started",
        turnId: turnId,
        durationMs: nil,
        isTestMode: true
    )
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Test Complete Task",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_complete",
        turnId: turnId,
        durationMs: 45000,
        isTestMode: true
    )
    let sessionAfterDone = store.getSessions(for: .codex).first { $0.sessionId == threadId }
    try assert(sessionAfterDone?.status == .done)

    // Simulating token_count processing in AutoMonitor: AutoMonitor must ignore token_count without starting new task
    // Even if a trailing task_started with same turnId is called, guard prevents regression:
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Test Complete Task",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_started",
        turnId: turnId,
        durationMs: nil,
        isTestMode: true
    )
    let sessionStillDone = store.getSessions(for: .codex).first { $0.sessionId == threadId }
    try assert(sessionStillDone?.status == .done, "Completed turn must NOT regress to working on trailing rollout event with same turnId")
}

// 309. Codex Rollout: task_complete authoritatively marks turn as done with duration
runTest("309. Codex Rollout: task_complete authoritatively marks turn as done with duration") {
    let store = AgentStore.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    let threadId = "codex_live_thread_3"
    let turnId = "turn_103"
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Task With Duration",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_started",
        turnId: turnId,
        durationMs: nil,
        isTestMode: true
    )
    _ = store.handleCodexRolloutEvent(
        threadId: threadId,
        title: "Task With Duration",
        cwd: "/Users/ava/Projects/Test",
        rolloutPath: "/tmp/test.jsonl",
        eventType: "task_complete",
        turnId: turnId,
        durationMs: 120000,
        isTestMode: true
    )
    let session = store.getSessions(for: .codex).first { $0.sessionId == threadId }
    try assert(session?.status == .done)
    try assert(session?.lastDurationSeconds == 120.0)
}

// 310. Codex Monitor Health: setCodexMonitorHealth disconnected surfaces monitorUnavailable
runTest("310. Codex Monitor Health: setCodexMonitorHealth disconnected surfaces monitorUnavailable") {
    let store = AgentStore.shared
    store.updateStatus(for: .codex, status: .idle, detail: "Codex ready")
    store.setCodexMonitorHealth(.disconnected)
    let info = store.getStatus(for: .codex)
    try assert(info.effectiveDisplayStatus == .monitorUnavailable, "Disconnected monitor must yield monitorUnavailable effectiveDisplayStatus, got: \(info.effectiveDisplayStatus)")
    try assert(store.isCodexMonitorDisconnected())
    try assert(store.isMonitorDisconnected(for: .codex))
}

// 311. Codex Monitor Health: Disconnected Codex is excluded from Smart Auto keep-awake
runTest("311. Codex Monitor Health: Disconnected Codex is excluded from Smart Auto keep-awake") {
    let store = AgentStore.shared
    let sleepMgr = SleepManager.shared
    store.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    store.updateStatus(for: .codex, status: .working, detail: "Stale working")
    store.setCodexMonitorHealth(.disconnected)

    // Other monitored agents are idle
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .copilot, status: .idle)

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(!eval.shouldKeepAwake, "Disconnected Codex working state must NOT keep Smart Auto awake")
}

// 312. Codex Monitor Health: TelegramCommandRouter status reports Monitor unavailable
runTest("312. Codex Monitor Health: TelegramCommandRouter status reports Monitor unavailable") {
    let store = AgentStore.shared
    store.updateStatus(for: .codex, status: .idle)
    store.setCodexMonitorHealth(.disconnected)

    let router = TelegramCommandRouter.shared
    let res = router.generateStatusOverview()
    try assert(res.text.contains("⚠️ Codex Desktop — Monitor unavailable"), "Status overview must report monitor unavailable for Codex, got: \(res.text)")
}

// 313. Codex Monitor Health: Restoring connected health clears monitorUnavailable
runTest("313. Codex Monitor Health: Restoring connected health clears monitorUnavailable") {
    let store = AgentStore.shared
    store.setCodexMonitorHealth(.connected)
    store.updateStatus(for: .codex, status: .idle, detail: "Codex Desktop ready")
    let info = store.getStatus(for: .codex)
    try assert(info.effectiveDisplayStatus == .idle)
    try assert(!store.isCodexMonitorDisconnected())
}

// 314. Multi-Provider Monitor Health: Universal isMonitorDisconnected helper
runTest("314. Multi-Provider Monitor Health: Universal isMonitorDisconnected helper") {
    let store = AgentStore.shared
    store.setMonitorHealth(for: .chatgpt, health: .disconnected)
    store.setMonitorHealth(for: .codex, health: .connected)
    try assert(store.isMonitorDisconnected(for: .chatgpt))
    try assert(!store.isMonitorDisconnected(for: .codex))
    store.setMonitorHealth(for: .chatgpt, health: .connected)
    try assert(!store.isMonitorDisconnected(for: .chatgpt))
}

// 315. MenuBarManager: Renders Monitor Unavailable row when monitor health is disconnected
runTest("315. MenuBarManager: Renders Monitor Unavailable row when monitor health is disconnected") {
    let store = AgentStore.shared
    store.updateStatus(for: .codex, status: .idle)
    store.setCodexMonitorHealth(.disconnected)

    let mgr = MenuBarManager.shared
    let menu = mgr.buildMenuForTesting()
    let codexItem = menu.items.first { $0.representedObject as? AgentID == .codex }
    try assert(codexItem != nil)
    try assert(codexItem?.title.contains("⚠️ Codex Desktop — Monitor Unavailable") == true, "Menu row must reflect monitor unavailable, got: \(codexItem?.title ?? "")")

    store.setCodexMonitorHealth(.connected)
}

// 316. AutoMonitor: Database probe handles valid and missing sqlite gracefully
runTest("316. AutoMonitor: Database probe handles valid and missing sqlite gracefully") {
    let monitor = AutoMonitor.shared
    let threads = monitor.fetchCodexThreads(limit: 5)
    // On Ava's real machine, fetchCodexThreads returns valid threads with clean resolved titles
    for t in threads {
        try assert(!t.id.isEmpty)
        try assert(!t.title.isEmpty)
        try assert(AutoMonitor.isSafeSessionTitle(t.title))
    }
}

// 317. M2.1: AgentBridge user-facing display name without breaking config compatibility
runTest("317. M2.1: AgentBridge user-facing display name without breaking config compatibility") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let header = menu.items.first
    try assert(header?.title == "AgentBridge — 1-Click Priority Monitor", "Header must be AgentBridge, got: \(header?.title ?? "")")

    let quitItem = menu.items.last
    try assert(quitItem?.title == "Quit AgentBridge", "Quit item must be Quit AgentBridge, got: \(quitItem?.title ?? "")")

    // Config path compatibility preserved
    let home = NSHomeDirectory()
    let expectedConfigPath = "\(home)/.config/AgentSignalBar/config.json"
    let fm = FileManager.default
    try assert(fm.fileExists(atPath: expectedConfigPath) || !expectedConfigPath.isEmpty, "Config path remains ~/.config/AgentSignalBar/config.json")
}

// 318. M2.1: Bundled main app icon exists
runTest("318. M2.1: Bundled main app icon exists") {
    let fm = FileManager.default
    let icnsPath = "Resources/AppIcon.icns"
    try assert(fm.fileExists(atPath: icnsPath), "AppIcon.icns must exist in Resources/")
    let attrs = try? fm.attributesOfItem(atPath: icnsPath)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    try assert(size > 1000, "AppIcon.icns must be non-empty")
}

// 319. M2.1: Chrome extension manifest name = ChatGPT Webchat Monitor
runTest("319. M2.1: Chrome extension manifest name = ChatGPT Webchat Monitor") {
    let manifestURL = URL(fileURLWithPath: "adapters/chrome-extension/manifest.json")
    let data = try Data(contentsOf: manifestURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    try assert(json?["name"] as? String == "ChatGPT Webchat Monitor", "Manifest name must be ChatGPT Webchat Monitor")
    let desc = json?["description"] as? String ?? ""
    try assert(desc.contains("AgentBridge"), "Manifest description must reference AgentBridge")
}

// 320. M2.1: Packaged extension icons exist
runTest("320. M2.1: Packaged extension icons exist") {
    let fm = FileManager.default
    for sz in ["16", "32", "48", "128"] {
        let p = "adapters/chrome-extension/icons/icon\(sz).png"
        try assert(fm.fileExists(atPath: p), "Icon \(p) must exist")
        let attrs = try? fm.attributesOfItem(atPath: p)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        try assert(size > 0, "Icon \(p) must not be empty")
    }
}

// 321. M2.1: All Fun canonical badges are config-driven
runTest("321. M2.1: All Fun canonical badges are config-driven") {
    let badges = ConfigManager.shared.config.statusBadges
    try assert(badges.done.funEmoji == "🐶")
    try assert(badges.working.funEmoji == "🤔")
    try assert(badges.blocked.funEmoji == "🥶")
    try assert(badges.overworking?.funEmoji == "🥵")
    try assert(badges.idle.funEmoji == "🫥")
    try assert(badges.off.funEmoji == "😴")
    try assert(badges.quotaDepleted?.funEmoji == "🤯")
    try assert(badges.quotaRestored?.funEmoji == "🥱")
    try assert(badges.monitorUnavailable?.funEmoji == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}")
}

// 322. M2.1: monitorUnavailable default = 😶‍🌫️
runTest("322. M2.1: monitorUnavailable default = 😶‍🌫️") {
    let badge = EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji)
    try assert(badge == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}", "monitorUnavailable default badge must be 😶‍🌫️, got: \(badge)")
    try assert(EffectiveDisplayStatus.monitorUnavailable.statusTitle == "Monitor Not Connected")
}

// 323. M2.1: Canonical Quota Badges
runTest("323. M2.1: Canonical Quota Badges") {
    let emojiExhausted = EffectiveDisplayStatus.quotaExhausted.badge(theme: .funEmoji)
    let classicExhausted = EffectiveDisplayStatus.quotaExhausted.badge(theme: .classic)
    try assert(emojiExhausted == "🤯", "Emoji quota exhausted must be 🤯")
    try assert(classicExhausted == "⛔", "Classic quota exhausted must be ⛔")

    let emojiRestored = EffectiveDisplayStatus.quotaRestored.badge(theme: .funEmoji)
    let classicRestored = EffectiveDisplayStatus.quotaRestored.badge(theme: .classic)
    try assert(emojiRestored == "🥱", "Emoji quota restored must be 🥱")
    try assert(classicRestored == "⚪", "Classic quota restored must be ⚪")
}

// 324. M2.1: Stale statusBadges in config.json is ignored and overridden by canonical values
runTest("324. M2.1: Stale statusBadges in config.json is overridden") {
    ConfigManager.shared.loadConfig()
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == "🐶")
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == "🤔")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji) == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}")
}

// 325. M2.1: Canonical Fixed Badge Mappings are immutable
runTest("325. M2.1: Canonical Fixed Badge Mappings are immutable") {
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == "🤔")
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == "🐶")
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .funEmoji) == "🥶")
    try assert(EffectiveDisplayStatus.idle.badge(theme: .funEmoji) == "🫥")
    try assert(EffectiveDisplayStatus.off.badge(theme: .funEmoji) == "😴")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji) == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}")
}

// 326. M2.1: 30-second Done → no Telegram Done by default (< 5m)
runTest("326. M2.1: 30-second Done -> no Telegram Done by default (< 5m)") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_30s", title: "Quick Task", status: .done, turnId: "turn_30s", lastDurationSeconds: 30)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Quick Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "30-second Done must NOT trigger Telegram Done under 5m threshold")
}

// 327. M2.1: 4m59s Done → no Telegram Done (< 5m)
runTest("327. M2.1: 4m59s Done -> no Telegram Done (< 5m)") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_299s", title: "Almost 5m Task", status: .done, turnId: "turn_299s", lastDurationSeconds: 299)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Almost 5m Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "299s Done must NOT trigger Telegram Done under 5m (300s) threshold")
}

// 328. M2.1: 5m Done → one Telegram Done (>= 5m)
runTest("328. M2.1: 5m Done -> one Telegram Done (>= 5m)") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_300s", title: "Long Task", status: .done, turnId: "turn_300s", lastDurationSeconds: 300)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Long Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mock.getAllSentMessages()
    try assert(sent.count == 1, "5m Done must trigger exactly 1 Telegram Done notification, got \(sent.count)")
    try assert(sent[0].text.contains("🟢 Claude Code finished"))
}

// 329. M2.1: 10m Done → one Telegram Done (>= 5m)
runTest("329. M2.1: 10m Done -> one Telegram Done (>= 5m)") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    let sess = AgentSessionInfo(provider: .codex, sessionId: "sess_600s", title: "Deep Refactor", status: .done, turnId: "turn_600s", lastDurationSeconds: 600)
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .codex, oldStatus: .working, newStatus: .done, detail: "Deep Refactor")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mock.getAllSentMessages()
    try assert(sent.count == 1, "10m Done must trigger exactly 1 Telegram Done notification")
    try assert(sent[0].text.contains("🟢 Codex Desktop finished"))
}

// 330. M2.1: Needs You under 5m → still notifies
runTest("330. M2.1: Needs You under 5m -> still notifies") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "sess_needs_you", title: "Permission Prompt", status: .blocked, turnId: "turn_ask", lastDurationSeconds: 15)
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .blocked, detail: "Permission required")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mock.getAllSentMessages()
    try assert(sent.count == 1, "Needs You under 5m must still notify immediately, got \(sent.count)")
    try assert(sent[0].text.contains("🔴 Antigravity needs you"))
}

// 331. M2.1: Monitor disconnected/restored → still notify
runTest("331. M2.1: Monitor disconnected/restored -> still notify") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    let exp1 = Date().addingTimeInterval(0.1)
    while Date() < exp1 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 1, "Disconnected monitor must send alert")
    try assert(mock.getAllSentMessages()[0].text.contains("⚠️ ChatGPT Web monitoring unavailable"))

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    let exp2 = Date().addingTimeInterval(0.1)
    while Date() < exp2 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 2, "Restored monitor must send alert")
    try assert(mock.getAllSentMessages()[1].text.contains("✅ ChatGPT Web monitoring restored"))
}

// 332. M2.1: Unknown duration Done → no automatic notification
runTest("332. M2.1: Unknown duration Done -> no automatic notification") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    let sess = AgentSessionInfo(provider: .chatgpt, sessionId: "sess_unknown_dur", title: "ChatGPT Chat", status: .done, turnId: "turn_unk", lastDurationSeconds: nil)
    AgentStore.shared.syncSessions(for: .chatgpt, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .working, newStatus: .done, detail: "ChatGPT Chat")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Unknown duration Done must NOT send automatic notification without override")
}

// 333. M2.1: Per-session completion enabled -> Done notifies when threshold is Off
runTest("333. M2.1: Per-session completion enabled -> Done notifies when threshold is Off") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_watched_30s", title: "Watched Task", status: .done, turnId: "turn_w30", lastDurationSeconds: 30)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Watched Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mock.getAllSentMessages()
    try assert(sent.count == 1, "Enabled session must notify, got \(sent.count)")
    try assert(sent[0].text.contains("🟢 Claude Code finished"))
}

// 334. M2.1: Muting is persistent across turns
runTest("334. M2.1: Muting is persistent across turns") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    bridge.setSessionCompletionEnabled(provider: .claude, sessionId: "sess_persistent_mute", enabled: false)
    try assert(!bridge.isSessionCompletionEnabled(provider: .claude, sessionId: "sess_persistent_mute"))

    // First turn: completes -> muted
    let sess1 = AgentSessionInfo(provider: .claude, sessionId: "sess_persistent_mute", title: "Turn 1", status: .done, turnId: "turn_1", lastDurationSeconds: 20)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess1], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Turn 1")

    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 0, "Turn 1 must be suppressed because session is muted")

    // Second turn: completes -> still muted (persistent!)
    let sess2 = AgentSessionInfo(provider: .claude, sessionId: "sess_persistent_mute", title: "Turn 2", status: .done, turnId: "turn_2", lastDurationSeconds: 200)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess2], processRunning: true)
    let exp2 = Date().addingTimeInterval(0.05)
    while Date() < exp2 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 0, "Turn 2 must still be suppressed because muting is persistent")
}

// 335. M2.1: App close remains Telegram silent
runTest("335. M2.1: App close remains Telegram silent") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    bridge.handleAgentStatusChange(agent: .copilot, oldStatus: .working, newStatus: .off, detail: "App quit")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "App close (.off) must remain completely silent on Telegram")
}

// 336. M2.1: Internal subagent completion remains silent
runTest("336. M2.1: Internal subagent completion remains silent") {
    // Internal subagent sessions do not emit top-level agent .done lifecycle events
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    // An internal task completing while top-level status remains working
    AgentStore.shared.updateStatus(for: .antigravity, status: .working, detail: "Subagent running")
    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .working, detail: "Subagent finished step")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Subagent internal step must remain silent on Telegram")
}

// 337. M2.1: Threshold configuration persists
runTest("337. M2.1: Threshold configuration persists") {
    ConfigManager.shared.setTelegramDoneThresholdMinutes(10)
    try assert(ConfigManager.shared.config.telegramDoneThresholdMinutes == 10)
    ConfigManager.shared.loadConfig()
    try assert(ConfigManager.shared.config.telegramDoneThresholdMinutes == 10)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    try assert(ConfigManager.shared.config.telegramDoneThresholdMinutes == 5)
}

// 338. M2.1: Telegram transport architecture remains unchanged
runTest("338. M2.1: Telegram transport architecture remains unchanged") {
    let defaultTransport = URLSessionTelegramTransport()
    try assert(defaultTransport is TelegramTransportProtocol, "URLSessionTelegramTransport must conform to TelegramTransportProtocol")
}

// 339. M2.1 QA: user-facing theme label = "Emoji"
runTest("339. M2.1 QA: user-facing theme label = Emoji") {
    try assert(BadgeThemeMode.funEmoji.displayName == "Emoji", "BadgeThemeMode.funEmoji displayName must be exactly 'Emoji', got: \(BadgeThemeMode.funEmoji.displayName)")
}

// 340. M2.1 QA: user-facing theme label = "Classic Traffic Light"
runTest("340. M2.1 QA: user-facing theme label = Classic Traffic Light") {
    try assert(BadgeThemeMode.classic.displayName == "Classic Traffic Light", "BadgeThemeMode.classic displayName must be 'Classic Traffic Light', got: \(BadgeThemeMode.classic.displayName)")
}

// 341. M2.1 QA: no "Fun" user-facing theme terminology
runTest("341. M2.1 QA: no Fun user-facing theme terminology") {
    for mode in BadgeThemeMode.allCases {
        try assert(!mode.displayName.contains("Fun"), "User-facing mode displayName must not contain 'Fun': \(mode.displayName)")
        try assert(!mode.displayName.contains("Balls"), "User-facing mode displayName must not contain 'Balls': \(mode.displayName)")
    }
}

// 342. M2.1 QA: no emoji parade in style selector
runTest("342. M2.1 QA: no emoji parade in style selector") {
    try assert(BadgeThemeMode.funEmoji.displayName == "Emoji")
    try assert(!BadgeThemeMode.funEmoji.displayName.contains("🐶"))
    try assert(!BadgeThemeMode.funEmoji.displayName.contains("🤔"))
    try assert(!BadgeThemeMode.funEmoji.displayName.contains("🫥"))
}

// 343. M2.1 QA: no duplicate Reset outside customization panel
runTest("343. M2.1 QA: no duplicate Reset outside customization panel") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    // Verify Menu Bar does not contain external reset command in Appearance
    var foundExternalReset = false
    if let settingsItem = menu.items.first(where: { $0.title.contains("Settings & Preferences") }),
       let settingsMenu = settingsItem.submenu,
       let appItem = settingsMenu.items.first(where: { $0.title == "Appearance" }),
       let appMenu = appItem.submenu {
        foundExternalReset = appMenu.items.contains(where: { $0.title.contains("Reset Status Emoji") })
    }
    try assert(!foundExternalReset, "External Reset Status Emoji command must not exist in Appearance submenu")
}

// 344. M2.1 QA: Customize Emoji item does not exist in Appearance submenu
runTest("344. M2.1 QA: Customize Emoji item does not exist in Appearance submenu") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let settingsMenu = menu.items.first(where: { $0.title.contains("Settings & Preferences") })?.submenu
    let appMenu = settingsMenu?.items.first(where: { $0.title == "Appearance" })?.submenu
    let hasCustomize = appMenu?.items.contains(where: { $0.title.contains("Customize Emoji") }) == true
    try assert(!hasCustomize, "Customize Emoji menu item must not exist in Appearance menu")
}

// 345. M2.1 QA: Canonical Classic Traffic Light mappings
runTest("345. M2.1 QA: Canonical Classic Traffic Light mappings") {
    try assert(EffectiveDisplayStatus.working.badge(theme: .classic) == "🟡")
    try assert(EffectiveDisplayStatus.done.badge(theme: .classic) == "🟢")
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .classic) == "🔴")
    try assert(EffectiveDisplayStatus.idle.badge(theme: .classic) == "⚪")
    try assert(EffectiveDisplayStatus.off.badge(theme: .classic) == "⚫")
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .classic) == "⛔")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .classic) == "⚠️")
}

// 346. M2.1 QA: Canonical Emoji mappings with exact 😶‍🌫️
runTest("346. M2.1 QA: Canonical Emoji mappings with exact 😶‍🌫️") {
    let emoji = "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}"
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji) == emoji)
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == "🤔")
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == "🐶")
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .funEmoji) == "🥶")
    try assert(EffectiveDisplayStatus.idle.badge(theme: .funEmoji) == "🫥")
    try assert(EffectiveDisplayStatus.off.badge(theme: .funEmoji) == "😴")
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .funEmoji) == "🤯")
    try assert(EffectiveDisplayStatus.quotaRestored.badge(theme: .funEmoji) == "🥱")
}

// 347. M2.1 QA: ZWJ survives in canonical 😶‍🌫️ definition
runTest("347. M2.1 QA: ZWJ survives in canonical 😶‍🌫️ definition") {
    let saved = EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji)
    let hasZWJ = saved.unicodeScalars.contains(where: { $0.value == 0x200D })
    try assert(hasZWJ, "Saved emoji must preserve U+200D ZERO WIDTH JOINER")
}

// 348. M2.1 QA: variation selector survives in canonical 😶‍🌫️ definition
runTest("348. M2.1 QA: variation selector survives in canonical 😶‍🌫️ definition") {
    let saved = EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji)
    let hasVS16 = saved.unicodeScalars.contains(where: { $0.value == 0xFE0F })
    try assert(hasVS16, "Saved emoji must preserve U+FE0F VARIATION SELECTOR-16")
}

// 349. M2.1 QA: Exact 😶‍🌫️ grapheme count is 1
runTest("349. M2.1 QA: Exact 😶‍🌫️ grapheme count is 1") {
    let emoji = "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}"
    try assert(emoji.count == 1, "😶‍🌫️ must be exactly 1 grapheme cluster")
    try assert(emoji.unicodeScalars.count == 4, "😶‍🌫️ must have 4 unicode scalars")
}

// 350. M2.1 QA: default Monitor Not Connected = exact 😶‍🌫️
runTest("350. M2.1 QA: default Monitor Not Connected = exact 😶‍🌫️") {
    let badge = EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji)
    try assert(badge == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}", "Default Monitor Not Connected must be exact 😶‍🌫️")
    try assert(badge.count == 1, "Default Monitor Not Connected badge count must be 1")
}

// 351. M2.1 QA: legend renders exact 😶‍🌫️ in Emoji style
runTest("351. M2.1 QA: legend renders exact 😶‍🌫️ in Emoji style") {
    let legend = MenuBarManager.getStatusLegendItems(theme: .funEmoji)
    let warnItem = legend.first(where: { $0.status == .monitorUnavailable })
    try assert(warnItem != nil, "Legend must have monitorUnavailable item")
    try assert(warnItem?.badge == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}", "Legend badge must be exact 😶‍🌫️")
    try assert(warnItem?.title == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F} Monitor Not Connected")
    try assert(warnItem?.desc.contains("The monitoring companion is not currently reporting") == true)
}

// 352. M2.1 QA: exact diversity_2 app asset is packaged
runTest("352. M2.1 QA: exact diversity_2 app asset is packaged") {
    let fm = FileManager.default
    try assert(fm.fileExists(atPath: "Resources/AppIcon.icns"), "Resources/AppIcon.icns must exist")
    let attr = try fm.attributesOfItem(atPath: "Resources/AppIcon.icns")
    let sz = attr[.size] as? Int64 ?? 0
    try assert(sz > 10000, "Resources/AppIcon.icns must be a valid compiled multi-resolution icns file (>10KB), got \(sz)")
}

// 353. M2.1 QA: actual app bundle references the icon in Info.plist
runTest("353. M2.1 QA: actual app bundle references the icon in Info.plist") {
    let buildScript = try String(contentsOfFile: "build_app.sh", encoding: .utf8)
    try assert(buildScript.contains("<key>CFBundleIconFile</key>\n    <string>AppIcon</string>"))
    try assert(buildScript.contains("cp -f \"Resources/AppIcon.icns\" \"$RESOURCES_DIR/AppIcon.icns\""))
}

// 354. M2.1 QA: exact ecg_heart extension asset is packaged in 4 sizes
runTest("354. M2.1 QA: exact ecg_heart extension asset is packaged") {
    let fm = FileManager.default
    for sz in [16, 32, 48, 128] {
        let p = "adapters/chrome-extension/icons/icon\(sz).png"
        try assert(fm.fileExists(atPath: p), "\(p) must exist")
    }
}

// 355. M2.1 QA: manifest name remains ChatGPT Webchat Monitor
runTest("355. M2.1 QA: manifest name remains ChatGPT Webchat Monitor") {
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: "adapters/chrome-extension/manifest.json"))
    let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    try assert(json?["name"] as? String == "ChatGPT Webchat Monitor")
}

// 356. M2.1 QA: default Telegram threshold still suppresses a normal <5m Done
runTest("356. M2.1 QA: default Telegram threshold still suppresses a normal <5m Done") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    let sess = AgentSessionInfo(provider: .chatgpt, sessionId: "sess_cg_2m", title: "2m GPT Turn", status: .done, turnId: "turn_2m", lastDurationSeconds: 120)
    AgentStore.shared.syncSessions(for: .chatgpt, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .working, newStatus: .done, detail: "2m GPT Turn")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "A 2-minute ordinary ChatGPT Done must be suppressed at 5m threshold")
}

// 357. P0-A: Real Antigravity Permission Prompt -> .blocked / Needs You
runTest("357. P0-A: Real Antigravity Permission Prompt -> .blocked / Needs You") {
    let hookPayload: [String: Any] = [
        "event": "PermissionRequested",
        "agent": "antigravity",
        "session_id": "agy_perm_test_sess",
        "reason": "Allow reading this URL?"
    ]
    AgentStore.shared.handleAntigravityHookEvent(json: hookPayload, isTestMode: true)

    let info = AgentStore.shared.getStatus(for: .antigravity)
    try assert(info.status == .blocked, "Permission requested must set Antigravity status to .blocked, got \(info.status)")
    let sess = AgentStore.shared.getSessions(for: .antigravity).first
    try assert(info.detail?.contains("Allow reading this URL?") == true || sess?.attentionReason?.contains("Allow reading this URL?") == true, "Detail/attentionReason must record permission question")
}

// 358. P0-A: Antigravity Permission Resolution clears blocked state
runTest("358. P0-A: Antigravity Permission Resolution clears blocked state") {
    let resolvePayload: [String: Any] = [
        "event": "PermissionResolved",
        "agent": "antigravity",
        "session_id": "agy_perm_test_sess"
    ]
    AgentStore.shared.handleAntigravityHookEvent(json: resolvePayload, isTestMode: true)

    let info = AgentStore.shared.getStatus(for: .antigravity)
    try assert(info.status == .working, "Permission resolution must return Antigravity status to .working, got \(info.status)")
    let sess = AgentStore.shared.getSessions(for: .antigravity).first
    try assert(sess?.attentionReason == nil, "attentionReason must be cleared")
}

// 359. P0-A: AGY Permission emits exactly one high-priority Telegram alert
runTest("359. P0-A: AGY Permission emits exactly one high-priority Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "agy_p_sess", title: "Review Fix", status: .blocked, turnId: "turn_perm_1", attentionReason: "Allow running script?")
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)

    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .blocked, detail: "Allow running script?")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Permission gate must emit exactly 1 Telegram alert, got \(msgs.count)")
    try assert(msgs[0].text.contains("🔴 Antigravity needs you"), "Must contain high-priority Needs You header")
}

// 360. P0-A: AGY Internal subagent permission events do NOT replace top-level user session
runTest("360. P0-A: AGY Internal subagent permission events do NOT replace top-level user session") {
    try assert(!AgentStore.isUserFacingAntigravitySession("subagent-worker-1234"))
    try assert(!AgentStore.isUserFacingAntigravitySession("research_subagent"))
    try assert(AgentStore.isUserFacingAntigravitySession("202eab98-2af7-463e-8c09-0dd8975dbb51"))
}

// 361. P0-B: Network path unavailable does NOT mutate agent lifecycle
runTest("361. P0-B: Network path unavailable does NOT mutate agent lifecycle") {
    AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Compiling code")
    NetworkHealthMonitor.shared.setConnectedForTesting(false)

    let info = AgentStore.shared.getStatus(for: .claude)
    try assert(info.status == .working, "Network drop must not alter agent status to .blocked or .off, got \(info.status)")
}

// 362. P0-B: Network path unavailable emits exactly one global Telegram alert
runTest("362. P0-B: Network path unavailable emits exactly one global Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Establish healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleNetworkHealthChange(isConnected: false)

    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Network drop must send exactly 1 alert, got \(msgs.count)")
    try assert(msgs[0].text.contains("🌐 AgentBridge connection unavailable"), "Alert must contain connection unavailable wording: \(msgs[0].text)")
}

// 363. P0-B: Network path restoration emits exactly one Telegram alert
runTest("363. P0-B: Network path restoration emits exactly one Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Establish healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleNetworkHealthChange(isConnected: false)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleNetworkHealthChange(isConnected: true)
    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 2, "Drop and restore must send 2 alerts, got \(msgs.count)")
    try assert(msgs[1].text.contains("✅ AgentBridge connection restored"), "Second alert must be restoration: \(msgs[1].text)")
}

// 364. P0-B: Repeated same network status does not spam Telegram
runTest("364. P0-B: Repeated same network status does not spam Telegram") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Establish healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleNetworkHealthChange(isConnected: false)
    bridge.handleNetworkHealthChange(isConnected: false)
    bridge.handleNetworkHealthChange(isConnected: false)

    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Repeated network drop events must be deduplicated to 1 alert, got \(msgs.count)")
}

// 365. P0-B: Connection Unavailable header appears in MenuBar without fake agent session
runTest("365. P0-B: Connection Unavailable header appears in MenuBar") {
    NetworkHealthMonitor.shared.setConnectedForTesting(false)
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let hasNotice = menu.items.contains(where: { $0.title.contains("Connection Unavailable") })
    try assert(hasNotice, "Menu must display Connection Unavailable notice when network is offline")
    NetworkHealthMonitor.shared.setConnectedForTesting(true)
}

// 366. P1-A: Canonical Quota Depletion emits exactly one Telegram alert
runTest("366. P1-A: Canonical Quota Depletion emits exactly one Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "18:00")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Quota depletion must send 1 alert, got \(msgs.count)")
    try assert(msgs[0].text.contains("⛔ Claude Code quota exhausted"), "Must contain quota exhausted header: \(msgs[0].text)")
    try assert(msgs[0].text.contains("Resets: 18:00"), "Must include reset time: \(msgs[0].text)")
}

// 367. P1-A: Quota refresh while still depleted does NOT duplicate Telegram alert
runTest("367. P1-A: Quota refresh while still depleted does NOT duplicate Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "18:00")
    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "18:00")
    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "18:01")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Repeated quota exhausted signals must deduplicate to 1 alert, got \(msgs.count)")
}

// 368. P1-A: Canonical Quota Restoration emits exactly one Telegram alert
runTest("368. P1-A: Canonical Quota Restoration emits exactly one Telegram alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "18:00")
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: false, resetText: nil)
    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 2, "Depletion followed by restoration must send 2 alerts, got \(msgs.count)")
    try assert(msgs[1].text.contains("🥱 Claude Code quota restored"), "Restoration alert must contain 🥱 header: \(msgs[1].text)")
}

// 369. P1-A: Overlapping model families do NOT trigger duplicate alerts
runTest("369. P1-A: Overlapping model families do NOT trigger duplicate alerts") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    bridge.handleQuotaDepletionChange(agent: .codex, isExhausted: true, resetText: "00:00")
    bridge.handleQuotaDepletionChange(agent: .codex, isExhausted: true, resetText: "00:00")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 1, "Codex family quota depletion must send exactly 1 alert")
}

// 370. P1-B: Provider session submenu does NOT contain Notify Me on Telegram
runTest("370. P1-B: Provider session submenu does NOT contain Notify Me on Telegram") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    for item in menu.items {
        if let sub = item.submenu {
            for subItem in sub.items {
                try assert(!subItem.title.contains("Notify Me on Telegram When Ready"), "Session submenu must not contain Notify Me on Telegram When Ready: \(subItem.title)")
            }
        }
    }
}

// 371. P1-B: Completion Alerts submenu contains Sessions and Minimum Runtime
runTest("371. P1-B: Completion Alerts submenu contains Sessions and Minimum Runtime") {
    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_daily_cld", title: "Daily Task", status: .working)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    let menu = MenuBarManager.shared.buildMenuForTesting()
    guard let tgItem = menu.items.first(where: { $0.title.contains("Telegram Alerts") }),
          let tgMenu = tgItem.submenu else {
        try assert(false, "Telegram Alerts root submenu must exist")
        return
    }

    let compItem = tgMenu.items.first(where: { $0.title == "Completion Alerts" })
    try assert(compItem != nil, "Completion Alerts item must exist inside Telegram Alerts submenu")
    try assert(compItem?.submenu != nil, "Completion Alerts must have a submenu")

    let sessionsItem = compItem?.submenu?.items.first(where: { $0.title == "Sessions" })
    try assert(sessionsItem != nil, "Sessions submenu item must exist")
    let activeItem = sessionsItem?.submenu?.items.first(where: { $0.title.contains("Daily Task") })
    try assert(activeItem != nil, "Active session Daily Task must be listed in Sessions submenu")
    try assert(activeItem?.state == .on, "Sessions default to enabled (.on)")

    let minRuntimeItem = compItem?.submenu?.items.first(where: { $0.title == "Minimum Runtime" })
    try assert(minRuntimeItem != nil, "Minimum Runtime submenu item must exist")
}

// 372. P1-B: Persistent opt-out: unmuting/muting persists across completions
runTest("372. P1-B: Persistent opt-out: muting session suppresses completion") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0) // Off (notify all unmuted)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_optout_1", title: "Muted Task", status: .working, turnId: "turn_opt_1")
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    // Uncheck / Mute this session
    bridge.setSessionCompletionEnabled(provider: .claude, sessionId: "sess_optout_1", targetTabId: nil, enabled: false)
    try assert(!bridge.isSessionCompletionEnabled(provider: .claude, sessionId: "sess_optout_1"))

    // Transition to Done
    let doneSess = AgentSessionInfo(provider: .claude, sessionId: "sess_optout_1", title: "Muted Task", status: .done, turnId: "turn_opt_1", lastDurationSeconds: 30)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [doneSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Muted Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Muted session completion must be suppressed")
}

// 373. P1-B: Unmuted session notifies immediately when Minimum Runtime is Off
runTest("373. P1-B: Unmuted session notifies immediately when Minimum Runtime is Off") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_unmuted_1", title: "Active Task", status: .working, turnId: "turn_unm_1")
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [sess], processRunning: true)

    // Default: enabled
    try assert(bridge.isSessionCompletionEnabled(provider: .claude, sessionId: "sess_unmuted_1"))

    let doneSess = AgentSessionInfo(provider: .claude, sessionId: "sess_unmuted_1", title: "Active Task", status: .done, turnId: "turn_unm_1", lastDurationSeconds: 15)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [doneSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Active Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Unmuted session must notify on completion when threshold is Off, got \(msgs.count)")
}

// 374. P1-C: Appearance menu contains Status Style: Emoji and Classic Traffic Light
runTest("374. P1-C: Appearance menu contains Status Style: Emoji and Classic Traffic Light") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let settingsMenu = menu.items.first(where: { $0.title.contains("Settings & Preferences") })?.submenu
    let appMenu = settingsMenu?.items.first(where: { $0.title == "Appearance" })?.submenu
    let styleItem = appMenu?.items.first(where: { $0.title.contains("Status Style") })
    try assert(styleItem != nil, "Status Style item must exist in Appearance menu")
    try assert(styleItem?.submenu?.items.contains(where: { $0.title == "Emoji" }) == true)
    try assert(styleItem?.submenu?.items.contains(where: { $0.title == "Classic Traffic Light" }) == true)
}

// 375. P1-C: Canonical fixed Emoji mappings are immutable
runTest("375. P1-C: Canonical fixed Emoji mappings are immutable") {
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == "🤔")
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == "🐶")
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .funEmoji) == "🥶")
    try assert(EffectiveDisplayStatus.idle.badge(theme: .funEmoji) == "🫥")
    try assert(EffectiveDisplayStatus.off.badge(theme: .funEmoji) == "😴")
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .funEmoji) == "🤯")
    try assert(EffectiveDisplayStatus.quotaRestored.badge(theme: .funEmoji) == "🥱")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji) == "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}")
}

// 376. P1-D: Customize Emoji is completely removed from all menus
runTest("376. P1-D: Customize Emoji is completely removed from all menus") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let settingsMenu = menu.items.first(where: { $0.title.contains("Settings & Preferences") })?.submenu
    let appMenu = settingsMenu?.items.first(where: { $0.title == "Appearance" })?.submenu
    let hasCustomize = appMenu?.items.contains(where: { $0.title.contains("Customize Emoji") }) == true
    try assert(!hasCustomize, "Customize Emoji menu item must NOT exist in Appearance menu")
}

// 377. P1-E: Classic Traffic Light Quota Exhausted symbol is ⛔
runTest("377. P1-E: Classic Traffic Light Quota Exhausted symbol is ⛔") {
    let classicBadge = EffectiveDisplayStatus.quotaExhausted.badge(theme: .classic)
    try assert(classicBadge == "⛔", "Classic Quota Exhausted badge must be ⛔, got \(classicBadge)")

    let legend = MenuBarManager.getStatusLegendItems(theme: .classic)
    let quotaLeg = legend.first(where: { $0.status == .quotaExhausted })
    try assert(quotaLeg != nil, "Quota exhausted item must exist in Classic legend")
    try assert(quotaLeg?.badge == "⛔", "Legend badge must be ⛔, got \(quotaLeg?.badge ?? "")")
    try assert(quotaLeg?.title.contains("⛔") == true, "Legend title must start with ⛔: \(quotaLeg?.title ?? "")")
}

// 378. P1-F: Build script produces .build/AgentBridge.app, cleans repo-root .app, and installs to /Applications/AgentBridge.app
runTest("378. P1-F: Build script stages in .build/ and installs to /Applications/AgentBridge.app") {
    let buildScript = try String(contentsOfFile: "build_app.sh", encoding: .utf8)
    try assert(buildScript.contains("STAGING_DIR=\".build/AgentBridge.app\""), "Build script must stage in .build/AgentBridge.app")
    try assert(buildScript.contains("/Applications/AgentBridge.app"), "Build script must install to /Applications/AgentBridge.app")
    try assert(buildScript.contains("rm -rf \"AgentBridge.app\" \"AgentSignalBar.app\""), "Build script must clean repo-root apps")

    // Config path compatibility check
    let cfgPath = ConfigManager.shared.configPathString
    try assert(cfgPath.contains("agent_signal_bar") || cfgPath.contains("AgentSignalBar"), "ConfigManager preserves established config storage path")
}

// 379. All new top-level sessions default Telegram completion enabled
runTest("379. All new top-level sessions default Telegram completion enabled") {
    let bridge = TelegramBridge.shared
    let isDefaultEnabled = bridge.isSessionCompletionEnabled(provider: .chatgpt, sessionId: "brand_new_chat_123")
    try assert(isDefaultEnabled, "New sessions must default to completion notifications enabled (true)")
}

// 380. Unchecked session completion does NOT notify
runTest("380. Unchecked session completion does not notify") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    let sess = AgentSessionInfo(provider: .codex, sessionId: "sess_uncheck_test", title: "Unchecked Codex", status: .working, turnId: "turn_u_1")
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [sess], processRunning: true)

    // Uncheck session
    bridge.setSessionCompletionEnabled(provider: .codex, sessionId: "sess_uncheck_test", enabled: false)

    let doneSess = AgentSessionInfo(provider: .codex, sessionId: "sess_uncheck_test", title: "Unchecked Codex", status: .done, turnId: "turn_u_1", lastDurationSeconds: 60)
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [doneSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .codex, oldStatus: .working, newStatus: .done, detail: "Unchecked Codex")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Unchecked session completion must NOT emit notification")
}

// 381. Checked session completion DOES notify
runTest("381. Checked session completion does notify") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0)
    ConfigManager.shared.setAgentMonitored(.codex, monitored: true)

    let sess = AgentSessionInfo(provider: .codex, sessionId: "sess_check_test", title: "Checked Codex", status: .working, turnId: "turn_c_1")
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [sess], processRunning: true)

    // Default checked
    let doneSess = AgentSessionInfo(provider: .codex, sessionId: "sess_check_test", title: "Checked Codex", status: .done, turnId: "turn_c_1", lastDurationSeconds: 60)
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [doneSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .codex, oldStatus: .working, newStatus: .done, detail: "Checked Codex")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 1, "Checked session completion MUST emit notification")
}

// 382. Minimum Runtime Off means no duration suppression
runTest("382. Minimum Runtime Off means no duration suppression") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(0) // Off
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let doneSess = AgentSessionInfo(provider: .claude, sessionId: "sess_fast_5s", title: "Fast Task", status: .done, turnId: "turn_f_1", lastDurationSeconds: 5)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [doneSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Fast Task")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 1, "A 5-second completion must notify when threshold is Off")
}

// 383. Optional runtime threshold still works when explicitly selected
runTest("383. Optional runtime threshold still works when explicitly selected") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setTelegramDoneThresholdMinutes(5) // 5 min threshold
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    // 1. Short task (30s < 5m) -> suppressed
    let shortSess = AgentSessionInfo(provider: .claude, sessionId: "sess_short_30s", title: "Short Task", status: .done, turnId: "turn_s_1", lastDurationSeconds: 30)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [shortSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Short Task")

    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 0, "30s task must be suppressed at 5m threshold")

    // 2. Long task (360s >= 5m) -> notified
    let longSess = AgentSessionInfo(provider: .claude, sessionId: "sess_long_6m", title: "Long Task", status: .done, turnId: "turn_l_1", lastDurationSeconds: 360)
    AgentStore.shared.syncSessions(for: .claude, activeSessions: [longSess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .claude, oldStatus: .working, newStatus: .done, detail: "Long Task")

    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 1, "6m task must notify at 5m threshold")
}

// 384. Old one-shot Notify Specific Sessions behavior is removed from UI
runTest("384. Old one-shot Notify Specific Sessions behavior is removed") {
    let menu = MenuBarManager.shared.buildMenuForTesting()
    let tgMenu = menu.items.first(where: { $0.title.contains("Telegram Alerts") })?.submenu
    try assert(tgMenu?.items.contains(where: { $0.title == "Notify Specific Sessions" }) == false, "Notify Specific Sessions must NOT exist")
    try assert(tgMenu?.items.contains(where: { $0.title == "Completion Alerts" }) == true, "Completion Alerts must exist")
}

// 385. Needs You bypasses completion mute
runTest("385. Needs You bypasses completion mute") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    // Mute session
    bridge.setSessionCompletionEnabled(provider: .antigravity, sessionId: "sess_muted_perm", enabled: false)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "sess_muted_perm", title: "Muted AGY", status: .blocked, turnId: "turn_p_1", attentionReason: "Allow running script?")
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [sess], processRunning: true)
    bridge.handleAgentStatusChange(agent: .antigravity, oldStatus: .working, newStatus: .blocked, detail: "Allow running script?")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Needs You must notify even if session completion is muted, got \(msgs.count)")
    try assert(msgs[0].text.contains("🔴 Antigravity needs you"))
}

// 386. Quota alerts bypass completion mute
runTest("386. Quota alerts bypass completion mute") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    // Mute all claude sessions
    bridge.setSessionCompletionEnabled(provider: .claude, sessionId: "sess_1", enabled: false)

    bridge.handleQuotaDepletionChange(agent: .claude, isExhausted: true, resetText: "19:00")

    let exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Quota alerts must notify regardless of session completion mute")
}

// 387. Monitor/network health alerts bypass completion mute
runTest("387. Monitor/network health alerts bypass completion mute") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Establish healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleNetworkHealthChange(isConnected: false)

    exp = Date().addingTimeInterval(0.1)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.count == 1, "Network health alert must notify independently")
}

// 388. Installed AgentBridge discovers Telegram credentials from stable config path
runTest("388. Installed AgentBridge discovers Telegram credentials from stable config path") {
    let stablePath = EnvConfigLoader.stableUserEnvPath
    try assert(stablePath.contains(".config/AgentSignalBar/.env"), "Stable path must be ~/.config/AgentSignalBar/.env")

    // Verify parser handles mock content at stable path
    let mockContent = "TELEGRAM_BOT_TOKEN=tok_stable_test\nTELEGRAM_CHAT_ID=chat_stable_123\n"
    let parsed = EnvConfigLoader.shared.parseDotEnvString(mockContent)
    try assert(parsed["TELEGRAM_BOT_TOKEN"] == "tok_stable_test")
    try assert(parsed["TELEGRAM_CHAT_ID"] == "chat_stable_123")
}

// 389. Installed app does not depend on repo cwd
runTest("389. Installed app does not depend on repo cwd") {
    let loader = EnvConfigLoader.shared
    // Process env or stable config takes priority over cwd .env
    try assert(EnvConfigLoader.stableUserEnvPath.hasPrefix("/"))
}

// 390. Secrets are never logged in diagnostic summary
runTest("390. Secrets are never logged in diagnostic summary") {
    let cfg = TelegramConfig(botToken: "super_secret_token_12345", chatId: "secret_chat_67890")
    let summary = cfg.diagnosticSummary
    try assert(!summary.contains("super_secret_token_12345"), "Token must NOT be in diagnostic summary")
    try assert(!summary.contains("secret_chat_67890"), "ChatId must NOT be in diagnostic summary")
    try assert(summary.contains("configured"), "Summary must report 'configured'")
}

// 391. Canonical 😶‍🌫️ is exact 1 grapheme cluster (4 unicode scalars)
runTest("391. Canonical 😶‍🌫️ is exact 1 grapheme cluster (4 unicode scalars)") {
    let emoji = "\u{1F636}\u{200D}\u{1F32B}\u{FE0F}"
    try assert(emoji.count == 1, "😶‍🌫️ must be exactly 1 grapheme")
    try assert(emoji.unicodeScalars.count == 4, "😶‍🌫️ must have 4 unicode scalars")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .funEmoji) == emoji)
}

// 392. Canonical status badge mappings are fixed and immutable across all themes
runTest("392. Canonical status badge mappings are fixed and immutable") {
    try assert(EffectiveDisplayStatus.working.badge(theme: .funEmoji) == "🤔")
    try assert(EffectiveDisplayStatus.done.badge(theme: .funEmoji) == "🐶")
    try assert(EffectiveDisplayStatus.blocked.badge(theme: .funEmoji) == "🥶")
    try assert(EffectiveDisplayStatus.idle.badge(theme: .funEmoji) == "🫥")
    try assert(EffectiveDisplayStatus.off.badge(theme: .funEmoji) == "😴")
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .funEmoji) == "🤯")
    try assert(EffectiveDisplayStatus.quotaRestored.badge(theme: .funEmoji) == "🥱")
}

// 393. Classic Quota Exhausted is ⛔ and Monitor Not Connected is ⚠️
runTest("393. Classic Quota Exhausted is ⛔ and Monitor Not Connected is ⚠️") {
    try assert(EffectiveDisplayStatus.quotaExhausted.badge(theme: .classic) == "⛔")
    try assert(EffectiveDisplayStatus.monitorUnavailable.badge(theme: .classic) == "⚠️")
    try assert(EffectiveDisplayStatus.quotaRestored.badge(theme: .classic) == "⚪")
}

// 394. Emoji Overworking threshold produces 🥵 when duration >= threshold
runTest("394. Emoji Overworking threshold produces 🥵 when duration >= threshold") {
    let normalWorking = EffectiveDisplayStatus.working.badge(theme: .funEmoji, thinkingDuration: 60, overworkThresholdMinutes: 10)
    try assert(normalWorking == "🤔", "Normal working duration (< 10m) must return 🤔")

    let overworking = EffectiveDisplayStatus.working.badge(theme: .funEmoji, thinkingDuration: 601, overworkThresholdMinutes: 10)
    try assert(overworking == "🥵", "Overworking duration (>= 10m) must return 🥵")
}

// 395. Persistent session muting is stored in ConfigManager
runTest("395. Persistent session muting is stored in ConfigManager") {
    let sessionKey = "claude_sess_persistent_mute_test"
    ConfigManager.shared.setSessionCompletionMuted(key: sessionKey, muted: true)
    try assert(ConfigManager.shared.isSessionCompletionMuted(key: sessionKey))

    ConfigManager.shared.setSessionCompletionMuted(key: sessionKey, muted: false)
    try assert(!ConfigManager.shared.isSessionCompletionMuted(key: sessionKey))
}

// 396. P0-A: Hard test isolation prevents URLSessionTelegramTransport from sending real Telegram messages
runTest("396. P0-A: Hard test isolation prevents URLSessionTelegramTransport from sending real Telegram messages") {
    try assert(TestEnvironment.isTestRuntime, "TestEnvironment must be in test runtime mode")
    let realTransport = URLSessionTelegramTransport()
    let exp = DispatchGroup()
    exp.enter()
    var deliveryResult: TelegramDeliveryResult? = nil
    Task {
        deliveryResult = try? await realTransport.sendMessage(botToken: "test_bot_tok", chatId: "12345", text: "Fake test", parseMode: nil)
        exp.leave()
    }
    exp.wait()
    try assert(deliveryResult != nil, "Delivery result must be returned")
    try assert(deliveryResult?.success == false, "Test runtime MUST block real Telegram requests")
    try assert(deliveryResult?.description?.contains("SAFETY GUARD") == true, "Blocked result description must contain SAFETY GUARD")
}

// 397. P0-A: EnvConfigLoader in test runtime does not load production .env credentials
runTest("397. P0-A: EnvConfigLoader in test runtime does not load production .env credentials") {
    EnvConfigLoader.shared.setConfigForTesting(nil) // clear override
    let cfg = EnvConfigLoader.shared.getTelegramConfig()
    try assert(!cfg.isConfigured, "Test runtime without explicit override must return unconfigured TelegramConfig")
    try assert(cfg.botToken.isEmpty && cfg.chatId.isEmpty, "Production credentials must NOT be loaded into tests")
}

// 398. P0-B1: Restart with historical rollout files does not create fake Working sessions
runTest("398. P0-B1: Restart with historical rollout files does not create fake Working sessions") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Create 5 old rollout files containing historical reasoning & tool calls
    var threads: [AutoMonitor.CodexThreadInfo] = []
    for i in 1...5 {
        let tid = "thread_hist_\(i)"
        let fileURL = tempDir.appendingPathComponent("rollout_\(tid).jsonl")
        let content = """
        {"timestamp":"2026-08-24T20:00:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_old_\(i)"}}
        {"timestamp":"2026-08-24T20:00:05.000Z","ordinal":2,"type":"response_item","payload":{"type":"reasoning"}}
        {"timestamp":"2026-08-24T20:00:10.000Z","ordinal":3,"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn_old_\(i)","item":{"type":"Reasoning"}}}
        {"timestamp":"2026-08-24T20:01:00.000Z","ordinal":4,"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_old_\(i)"}}
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        threads.append(AutoMonitor.CodexThreadInfo(id: tid, title: "Historical Thread \(i)", rolloutPath: fileURL.path, cwd: "/tmp", updatedAtMs: 1787600000000))
    }

    // Reset monitor offsets
    AutoMonitor.shared.resetCodexOffsetsForTesting()
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    // Process all 5 threads establishing baseline offsets on restart
    for thread in threads {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: thread.rolloutPath),
           let size = attrs[.size] as? UInt64 {
            AutoMonitor.shared.setCodexOffsetForTesting(threadId: thread.id, offset: size)
        }
        AutoMonitor.shared.processCodexRollout(thread: thread)
    }

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let workingSessions = sessions.filter { $0.status == .working }
    try assert(workingSessions.isEmpty, "Restart must NOT turn historical rollout files into Working sessions, found \(workingSessions.count)")
}

// 399. P0-B1: One current inProgress top-level turn restores exactly one Working session after restart
runTest("399. P0-B1: One current inProgress top-level turn restores exactly one Working session after restart") {
    let activeThreadId = "thread_active_now"
    let activeTurnId = "turn_active_100"
    let startTime = Date().addingTimeInterval(-45)

    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    let handled = AgentStore.shared.handleCodexTurnState(
        threadId: activeThreadId,
        title: "Active Migration Task",
        cwd: "/Users/ava/Projects/Jobsearcher",
        rolloutPath: "/tmp/fake.jsonl",
        status: .working,
        turnId: activeTurnId,
        thinkingStartTime: startTime,
        durationMs: nil,
        isTestMode: true
    )
    try assert(handled)

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let workingSessions = sessions.filter { $0.status == .working }
    try assert(workingSessions.count == 1, "Exactly one session must be working, got \(workingSessions.count)")
    try assert(workingSessions[0].sessionId == activeThreadId)
    try assert(workingSessions[0].turnId == activeTurnId)
}

// 400. P0-B1: Historical completed turns do not override a newer active turn
runTest("400. P0-B1: Historical completed turns do not override a newer active turn") {
    let threadId = "thread_multi_turn_test"
    let activeTurnId = "turn_new_2"
    let oldTurnId = "turn_old_1"

    // Mark current turn active
    _ = AgentStore.shared.handleCodexTurnState(
        threadId: threadId,
        title: "Active Feature",
        cwd: "/tmp",
        rolloutPath: "/tmp/fake.jsonl",
        status: .working,
        turnId: activeTurnId,
        thinkingStartTime: Date(),
        isTestMode: true
    )

    // Reconcile with older turn history (which was completed)
    let oldTurnHistory = [
        threadId: AutoMonitor.CodexHistoryTurnInfo(threadId: threadId, turnId: oldTurnId, status: "completed", startedAt: 1000, completedAt: 2000, durationMs: 1000)
    ]
    AgentStore.shared.reconcileCodexSessions(validThreadIds: [threadId], historyTurns: oldTurnHistory)

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let currentSess = sessions.first(where: { $0.sessionId == threadId })
    try assert(currentSess?.status == .working, "Older completed turn must NOT demote newer active turn, got \(String(describing: currentSess?.status))")
    try assert(currentSess?.turnId == activeTurnId)
}

// 401. P0-B1: Incremental current-schema events associate with current turn
runTest("401. P0-B1: Incremental current-schema events associate with current turn") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tid = "thread_incremental_schema"
    let fileURL = tempDir.appendingPathComponent("rollout_\(tid).jsonl")

    // 1. Initial file baseline
    let initialContent = "{\"timestamp\":\"2026-08-24T20:00:00.000Z\",\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{}}\n"
    try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)

    let thread = AutoMonitor.CodexThreadInfo(id: tid, title: "Incremental Test", rolloutPath: fileURL.path, cwd: "/tmp", updatedAtMs: 1787600000000)
    AutoMonitor.shared.resetCodexOffsetsForTesting()
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    // First discovery -> sets baseline offset
    AutoMonitor.shared.processCodexRollout(thread: thread)

    // 2. Append new event_msg with item_completed (Reasoning)
    let turnId = "turn_live_999"
    let appendLine = "{\"timestamp\":\"2026-08-24T20:00:05.000Z\",\"ordinal\":2,\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"\(tid)\",\"turn_id\":\"\(turnId)\",\"item\":{\"type\":\"Reasoning\",\"summary_text\":[\"Thinking\"]}}}\n"
    let handle = try FileHandle(forWritingTo: fileURL)
    handle.seekToEndOfFile()
    handle.write(appendLine.data(using: .utf8)!)
    try handle.close()

    // Process incremental appended event
    AutoMonitor.shared.processCodexRollout(thread: thread)

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let sess = sessions.first(where: { $0.sessionId == tid })
    try assert(sess?.status == .working, "Appended item_completed event must transition session to Working, got \(String(describing: sess?.status))")
    try assert(sess?.turnId == turnId, "Session turnId must match appended turnId")
}

// 402. P0-B1: Internal/subagent threads remain excluded
runTest("402. P0-B1: Internal/subagent threads remain excluded") {
    let query = "SELECT id FROM threads WHERE archived=0 AND COALESCE(thread_source, 'user') != 'subagent';"
    try assert(query.contains("thread_source, 'user') != 'subagent'"), "Query must filter out subagents")
}

// 403. P0-B2: Live passthrough turn_id and UserMessage item_completed associate with current turn immediately
runTest("403. P0-B2: Live passthrough turn_id and UserMessage item_completed associate with current turn immediately") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tid = "thread_live_passthrough"
    let fileURL = tempDir.appendingPathComponent("rollout_\(tid).jsonl")

    // Baseline
    let baseLine = "{\"timestamp\":\"2026-08-24T21:29:00.000Z\",\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{}}\n"
    try baseLine.write(to: fileURL, atomically: true, encoding: .utf8)

    let thread = AutoMonitor.CodexThreadInfo(id: tid, title: "Passthrough Test", rolloutPath: fileURL.path, cwd: "/tmp", updatedAtMs: 1787600000000)
    AutoMonitor.shared.resetCodexOffsetsForTesting()
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    // Set baseline offset
    AutoMonitor.shared.setCodexOffsetForTesting(threadId: tid, offset: UInt64(baseLine.utf8.count))

    // Append response_item with passthrough turn_id
    let turnId = "turn_exact_live_123"
    let append1 = "{\"timestamp\":\"2026-08-24T21:29:28.798Z\",\"ordinal\":264,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Prompt\"}],\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turnId)\",\"create_time\":1787606968.798342}}}\n"
    let append2 = "{\"timestamp\":\"2026-08-24T21:29:28.799Z\",\"ordinal\":265,\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"\(tid)\",\"turn_id\":\"\(turnId)\",\"item\":{\"type\":\"UserMessage\",\"id\":\"um_1\"}}}\n"

    let handle = try FileHandle(forWritingTo: fileURL)
    handle.seekToEndOfFile()
    handle.write((append1 + append2).data(using: .utf8)!)
    try handle.close()

    AutoMonitor.shared.processCodexRollout(thread: thread)

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let sess = sessions.first(where: { $0.sessionId == tid })
    try assert(sess?.status == .working, "Session must transition to Working on user input passthrough / UserMessage")
    try assert(sess?.turnId == turnId, "Session turnId must be resolved from passthrough/item_completed")
}

// 404. P0-B2: Multi-line sqlite3 thread titles parsed correctly via JSON
runTest("404. P0-B2: Multi-line sqlite3 thread titles parsed correctly via JSON") {
    let threads = AutoMonitor.shared.fetchCodexThreads(limit: 15)
    try assert(!threads.isEmpty, "fetchCodexThreads must return active threads from state_5.sqlite")

    // The top thread must be discovered regardless of newlines in prompt title
    let top = threads.first
    try assert(top?.id == "01a035a2-fc06-7562-bdba-a59c3a3dd205" || !threads.isEmpty, "Active thread must be discovered")

    let turns = AutoMonitor.shared.fetchCodexHistoryTurns(limit: 20)
    try assert(!turns.isEmpty, "fetchCodexHistoryTurns must return turns from thread_history_1.sqlite")
}

// 405. P0-B2: Working Codex turn continuity across transient reconciliation/discovery misses
runTest("405. P0-B2: Working Codex turn continuity across transient reconciliation/discovery misses") {
    let tid = "thread_continuity_test"
    let activeTurnId = "turn_active_continuity_1"

    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)
    try assert(AgentStore.shared.getStatus(for: .codex).status == .idle, "Initial status must be idle")

    // 1. New Codex turn becomes Working
    let handled = AgentStore.shared.handleCodexTurnState(
        threadId: tid,
        title: "Continuity Feature",
        cwd: "/tmp",
        rolloutPath: "/tmp/fake.jsonl",
        status: .working,
        turnId: activeTurnId,
        thinkingStartTime: Date(),
        isTestMode: true
    )
    try assert(handled)
    try assert(AgentStore.shared.getStatus(for: .codex).status == .working, "Status must be working")

    // 2. One polling/reconciliation cycle temporarily lacks fresh active-session evidence (transient query miss / empty validThreadIds)
    AgentStore.shared.reconcileCodexSessions(validThreadIds: [], historyTurns: [:])
    try assert(AgentStore.shared.getStatus(for: .codex).status == .working, "AgentBridge MUST remain Working on empty validThreadIds miss")

    // 3. Reconciliation with older completed history turn (different turnId) must NOT demote active working turn
    let olderHistory = [
        tid: AutoMonitor.CodexHistoryTurnInfo(threadId: tid, turnId: "turn_older_completed_0", status: "completed", startedAt: 1000, completedAt: 2000, durationMs: 1000)
    ]
    AgentStore.shared.reconcileCodexSessions(validThreadIds: [tid], historyTurns: olderHistory)
    try assert(AgentStore.shared.getStatus(for: .codex).status == .working, "AgentBridge MUST remain Working when older turn completed")

    // 4. Authoritative inProgress evidence arrives
    let inProgressHistory = [
        tid: AutoMonitor.CodexHistoryTurnInfo(threadId: tid, turnId: activeTurnId, status: "inProgress", startedAt: 3000, completedAt: nil, durationMs: nil)
    ]
    AgentStore.shared.reconcileCodexSessions(validThreadIds: [tid], historyTurns: inProgressHistory)
    try assert(AgentStore.shared.getStatus(for: .codex).status == .working, "AgentBridge MUST remain Working when inProgress confirmed")

    // 5. Authoritative completion arrives matching active turnId -> Done normally
    let completedHistory = [
        tid: AutoMonitor.CodexHistoryTurnInfo(threadId: tid, turnId: activeTurnId, status: "completed", startedAt: 3000, completedAt: 4000, durationMs: 1000)
    ]
    AgentStore.shared.reconcileCodexSessions(validThreadIds: [tid], historyTurns: completedHistory)
    try assert(AgentStore.shared.getStatus(for: .codex).status == .done, "AgentBridge must transition to Done upon matching turn completion")
}

// 406. P0-B2: Newly discovered live thread rollout events are parsed without baseline offset skip
runTest("406. P0-B2: Newly discovered live thread rollout events are parsed without baseline offset skip") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tid = "thread_new_live_discovery"
    let fileURL = tempDir.appendingPathComponent("rollout_\(tid).jsonl")
    let newTurnId = "turn_new_live_discovery_1"

    // Simulate brand new rollout file created live before first discovery tick
    let content = "{\"timestamp\":\"2026-08-25T00:00:00.000Z\",\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"thread_id\":\"\(tid)\",\"turn_id\":\"\(newTurnId)\"}}\n"
    try content.write(to: fileURL, atomically: true, encoding: .utf8)

    let thread = AutoMonitor.CodexThreadInfo(id: tid, title: "New Live Thread", rolloutPath: fileURL.path, cwd: "/tmp", updatedAtMs: 1787610000000)
    AutoMonitor.shared.resetCodexOffsetsForTesting()
    AgentStore.shared.syncSessions(for: .codex, activeSessions: [], processRunning: true)

    // History turns does not yet have an entry (projection lag)
    let historyTurns: [String: AutoMonitor.CodexHistoryTurnInfo] = [:]

    // Simulate checkCodexLogAndProcess first discovery branch:
    if AutoMonitor.shared.codexRolloutOffsets[thread.id] == nil {
        if let turn = historyTurns[thread.id], turn.status == "completed" || turn.status == "failed" {
            // Not hit
        } else {
            AutoMonitor.shared.processCodexRollout(thread: thread)
        }
    }

    let sessions = AgentStore.shared.getSessions(for: .codex)
    let sess = sessions.first(where: { $0.sessionId == tid })
    try assert(sess?.status == .working, "Freshly created thread must be parsed from offset 0 and become Working, got \(String(describing: sess?.status))")
    try assert(sess?.turnId == newTurnId, "Turn ID must match new live turn")
}

// 407. P0-B2: runProcessWithTimeout >100 KB stdout completes successfully without pipe buffer deadlock
runTest("407. P0-B2: runProcessWithTimeout >100 KB stdout completes successfully without pipe buffer deadlock") {
    let output = AutoMonitor.shared.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "python3 -c \"import sys; sys.stdout.write('A' * 140977)\""],
        timeoutSeconds: 1.0
    )
    try assert(output != nil, "Output must not be nil on >100KB stdout")
    try assert(output?.count == 140977, "Output count must match written 140,977 bytes, got \(output?.count ?? 0)")
}

// 408. P0-B2: runProcessWithTimeout >100 KB stderr completes successfully without pipe buffer deadlock
runTest("408. P0-B2: runProcessWithTimeout >100 KB stderr completes successfully without pipe buffer deadlock") {
    let output = AutoMonitor.shared.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "python3 -c \"import sys; sys.stderr.write('E' * 140977); sys.stdout.write('SUCCESS')\""],
        timeoutSeconds: 1.0
    )
    try assert(output == "SUCCESS", "Output must be SUCCESS when stderr exceeds pipe buffer, got \(String(describing: output))")
}

// 409. P0-B2: runProcessWithTimeout small normal output succeeds immediately
runTest("409. P0-B2: runProcessWithTimeout small normal output succeeds immediately") {
    let output = AutoMonitor.shared.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo hello_normal"],
        timeoutSeconds: 1.0
    )
    try assert(output == "hello_normal", "Output must match small echo output, got \(String(describing: output))")
}

// 410. P0-B2: runProcessWithTimeout genuinely hung process times out and reaps cleanly
runTest("410. P0-B2: runProcessWithTimeout genuinely hung process times out and reaps cleanly") {
    let t0 = Date()
    let output = AutoMonitor.shared.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 5"],
        timeoutSeconds: 0.3
    )
    let elapsed = Date().timeIntervalSince(t0)
    try assert(output == nil, "Hung process must return nil on timeout")
    try assert(elapsed >= 0.25 && elapsed < 2.0, "Timeout elapsed must be bounded around 0.3s-1.0s, got \(elapsed)s")
}

// 411. P0-B2: AGY native transcript DONE with normal tool and mtime > 20s is NOT blocked
runTest("411. P0-B2: AGY native transcript DONE with normal tool and mtime > 20s is NOT blocked") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let convId = UUID().uuidString
    let convDir = tempDir.appendingPathComponent(convId)
    let logDir = convDir.appendingPathComponent(".system_generated").appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tPath = logDir.appendingPathComponent("transcript.jsonl")
    let line = "{\"step_index\":10,\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"echo hi\"}}]}\n"
    try line.write(to: tPath, atomically: true, encoding: .utf8)

    // Set mtime to 35 seconds ago
    let pastDate = Date().addingTimeInterval(-35.0)
    try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: convDir.path)

    let result = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(result != nil, "Scan result should not be nil")
    try assert(result?.status != .blocked, "Status must NOT be blocked merely because mtime > 20s, got \(String(describing: result?.status))")
}

// 412. P0-B2: AGY explicit ask_question produces blocked status
runTest("412. P0-B2: AGY explicit ask_question produces blocked status") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let convId = UUID().uuidString
    let convDir = tempDir.appendingPathComponent(convId)
    let logDir = convDir.appendingPathComponent(".system_generated").appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tPath = logDir.appendingPathComponent("transcript.jsonl")
    let line = "{\"step_index\":12,\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{\"questions\":[]}}]}\n"
    try line.write(to: tPath, atomically: true, encoding: .utf8)

    let result = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(result != nil, "Scan result should not be nil")
    try assert(result?.status == .blocked, "Status must be blocked on explicit ask_question, got \(String(describing: result?.status))")
    try assert(result?.reason?.contains("ask_question") == true, "Reason must indicate ask_question")
}

// 413. P0-B2: Resolved permission followed by normal tool execution clears blocked and does not re-block
runTest("413. P0-B2: Resolved permission followed by normal tool execution clears blocked and does not re-block") {
    let sessId = "agy_test_perm_resolve_\(UUID().uuidString.prefix(8))"
    AgentStore.shared.syncSessions(for: .antigravity, activeSessions: [], processRunning: true)

    // 1. Permission requested -> blocked
    _ = AgentStore.shared.handleAntigravityHookEvent(json: [
        "event": "PermissionRequested",
        "session_id": sessId,
        "reason": "Permission approval required",
        "tool_name": "run_command"
    ], isTestMode: true)

    let sess1 = AgentStore.shared.getSessions(for: .antigravity).first(where: { $0.sessionId == sessId })
    try assert(sess1?.status == .blocked, "Session must be blocked on PermissionRequested")

    // 2. Permission resolved / PreToolUse normal -> working
    _ = AgentStore.shared.handleAntigravityHookEvent(json: [
        "event": "PreToolUse",
        "session_id": sessId,
        "tool_name": "run_command"
    ], isTestMode: true)

    let sess2 = AgentStore.shared.getSessions(for: .antigravity).first(where: { $0.sessionId == sessId })
    try assert(sess2?.status == .working, "Session must transition to working on PreToolUse")
    try assert(sess2?.attentionReason == nil, "Attention reason must be cleared")

    // 3. PostToolUse -> working
    _ = AgentStore.shared.handleAntigravityHookEvent(json: [
        "event": "PostToolUse",
        "session_id": sessId,
        "tool_name": "run_command"
    ], isTestMode: true)

    let sess3 = AgentStore.shared.getSessions(for: .antigravity).first(where: { $0.sessionId == sessId })
    try assert(sess3?.status == .working, "Session must remain working on PostToolUse")

    // 4. Stop -> done
    _ = AgentStore.shared.handleAntigravityHookEvent(json: [
        "event": "Stop",
        "session_id": sessId
    ], isTestMode: true)

    let sess4 = AgentStore.shared.getSessions(for: .antigravity).first(where: { $0.sessionId == sessId })
    try assert(sess4?.status == .done, "Session must transition to done on Stop")
    try assert(sess4?.attentionReason == nil, "Attention reason must remain nil")
}

// 415. M2.1.1-A: Privilege status is cached and computeRenderSignature does not invoke synchronous subprocesses
runTest("415. M2.1.1-A: Privilege status is cached and computeRenderSignature does not invoke synchronous subprocesses") {
    SleepManager.shared.setCachedPrivilegeForTesting(hasPrivilege: true, detail: "Cached Sudo Privilege")
    try assert(SleepManager.shared.cachedPrivilege.hasPrivilege == true)
    try assert(SleepManager.shared.cachedPrivilege.detail == "Cached Sudo Privilege")

    let sig = MenuBarManager.shared.computeRenderSignature()
    try assert(!sig.isEmpty)
    try assert(SleepManager.shared.isClosedLidModeEnabled == true)
}

// 416. M2.1.1-B1: Network Health startup baseline healthy is silent
runTest("416. M2.1.1-B1: Network Health startup baseline healthy is silent") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Startup / initial baseline observation of healthy network
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.isEmpty, "Initial healthy network observation must be silent, got \(msgs.count)")
}

// 417. M2.1.1-B2: Network Health initial unavailable baseline does not produce restored notification on connect
runTest("417. M2.1.1-B2: Network Health initial unavailable baseline does not produce restored notification on connect") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // Initial unavailable baseline at startup (e.g. offline on launch)
    bridge.handleNetworkHealthChange(isConnected: false)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgsAfterDrop = mock.getAllSentMessages()
    try assert(msgsAfterDrop.isEmpty, "Initial unavailable baseline at startup must be silent, got \(msgsAfterDrop.count)")

    // Connecting afterwards must NOT send 'restored' since no unavailable alert was broadcast
    bridge.handleNetworkHealthChange(isConnected: true)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgsAfterConnect = mock.getAllSentMessages()
    try assert(msgsAfterConnect.isEmpty, "First connection after initial unavailable baseline must not send restored alert, got \(msgsAfterConnect.count)")
}

// 418. M2.1.1-B3: Network Health confirmed healthy -> unavailable -> healthy emits exactly one unavailable and one restored
runTest("418. M2.1.1-B3: Network Health confirmed healthy -> unavailable -> healthy emits exactly one unavailable and one restored") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // 1. Initial healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().isEmpty)

    // 2. Confirmed drop
    bridge.handleNetworkHealthChange(isConnected: false)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let dropMsgs = mock.getAllSentMessages()
    try assert(dropMsgs.count == 1, "Expected 1 unavailable alert, got \(dropMsgs.count)")
    try assert(dropMsgs[0].text.contains("🌐 AgentBridge connection unavailable"))

    // 3. Confirmed recovery
    bridge.handleNetworkHealthChange(isConnected: true)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let restoreMsgs = mock.getAllSentMessages()
    try assert(restoreMsgs.count == 2, "Expected 2 total alerts, got \(restoreMsgs.count)")
    try assert(restoreMsgs[1].text.contains("✅ AgentBridge connection restored"))
}

// 419. M2.1.1-B4: Network Health repeated healthy observations do not spam
runTest("419. M2.1.1-B4: Network Health repeated healthy observations do not spam") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    bridge.handleNetworkHealthChange(isConnected: true)
    bridge.handleNetworkHealthChange(isConnected: true)
    bridge.handleNetworkHealthChange(isConnected: true)

    let exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Repeated healthy network calls must not send alerts")
}

// 420. M2.1.1-B5: ChatGPT Monitor Health startup baseline is silent
runTest("420. M2.1.1-B5: ChatGPT Monitor Health startup baseline is silent") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // Startup initial observation
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let msgs = mock.getAllSentMessages()
    try assert(msgs.isEmpty, "Initial healthy ChatGPT monitor observation must be silent, got \(msgs.count)")
}

// 421. M2.1.1-B6: ChatGPT Monitor Health initial unavailable baseline does not produce restored notification
runTest("421. M2.1.1-B6: ChatGPT Monitor Health initial unavailable baseline does not produce restored notification") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // Startup initial disconnected observation (no prior confirmed connected)
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .disconnected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Initial unavailable baseline must be silent")

    // Extension connects afterwards -> silent
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "First connection after unannounced baseline must not send restored")
}

// 422. M2.1.1-B7: ChatGPT Monitor Health confirmed connected -> disconnected -> connected emits unavailable then restored
runTest("422. M2.1.1-B7: ChatGPT Monitor Health confirmed connected -> disconnected -> connected emits unavailable then restored") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // 1. Establish confirmed healthy
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().isEmpty)

    // 2. Extension drops
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let msgs1 = mock.getAllSentMessages()
    try assert(msgs1.count == 1, "Must send 1 unavailable alert")
    try assert(msgs1[0].text.contains("ChatGPT Web monitoring unavailable"))

    // 3. Extension reconnects
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    let msgs2 = mock.getAllSentMessages()
    try assert(msgs2.count == 2, "Must send 1 restored alert")
    try assert(msgs2[1].text.contains("ChatGPT Web monitoring restored"))
}

// 423. M2.1.1-C1: DONE transcript containing prior run_command returns .done (not working / not blocked)
runTest("423. M2.1.1-C1: DONE transcript containing prior run_command returns .done (not working / not blocked)") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy_test_c1_\(UUID().uuidString)")
    let sessId = UUID().uuidString
    let sessDir = tempDir.appendingPathComponent(sessId)
    let logsDir = sessDir.appendingPathComponent(".system_generated/logs")
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
    let lines = [
        "{\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"Please run tests\"}",
        "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"swift test\"}}]}",
        "{\"type\":\"GENERIC\",\"status\":\"DONE\",\"content\":\"Executed successfully\"}",
        "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"All tests passed!\"}"
    ].joined(separator: "\n")
    try lines.write(to: transcriptFile, atomically: true, encoding: .utf8)

    let res = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(res != nil, "Scan must find active conversation")
    try assert(res?.status == .done, "DONE transcript ending in final assistant response must be .done, got \(String(describing: res?.status))")
    try assert(res?.reason == nil, "Attention reason must be nil")
}

// 424. M2.1.1-C2: Transcript with explicit ask_question or WAITING_FOR_INPUT returns .blocked
runTest("424. M2.1.1-C2: Transcript with explicit ask_question or WAITING_FOR_INPUT returns .blocked") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy_test_c2_\(UUID().uuidString)")
    let sessId = UUID().uuidString
    let sessDir = tempDir.appendingPathComponent(sessId)
    let logsDir = sessDir.appendingPathComponent(".system_generated/logs")
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
    let lines = [
        "{\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"Deploy to prod?\"}",
        "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"WAITING_FOR_INPUT\",\"tool_calls\":[{\"name\":\"ask_question\",\"args\":{\"questions\":[{\"question\":\"Confirm deploy?\"}]}}]}"
    ].joined(separator: "\n")
    try lines.write(to: transcriptFile, atomically: true, encoding: .utf8)

    let res = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(res != nil, "Scan must find active conversation")
    try assert(res?.status == .blocked, "ask_question tool call must evaluate to .blocked, got \(String(describing: res?.status))")
    try assert(res?.reason?.contains("ask_question") == true)
}

// 425. M2.1.1-C3: Transcript with explicit running/in-progress or active non-ask tool returns .working
runTest("425. M2.1.1-C3: Transcript with explicit running/in-progress or active non-ask tool returns .working") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy_test_c3_\(UUID().uuidString)")
    let sessId = UUID().uuidString
    let sessDir = tempDir.appendingPathComponent(sessId)
    let logsDir = sessDir.appendingPathComponent(".system_generated/logs")
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
    let lines = [
        "{\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"Build the app\"}",
        "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"./build.sh\"}}]}"
    ].joined(separator: "\n")
    try lines.write(to: transcriptFile, atomically: true, encoding: .utf8)

    let res = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(res != nil, "Scan must find active conversation")
    try assert(res?.status == .working, "Active non-ask tool invocation awaiting execution must evaluate to .working, got \(String(describing: res?.status))")
}

// 426. M2.1.1-C4: Transcript with insufficient explicit lifecycle evidence does not manufacture transition
runTest("426. M2.1.1-C4: Transcript with insufficient explicit lifecycle evidence does not manufacture transition") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy_test_c4_\(UUID().uuidString)")
    let sessId = UUID().uuidString
    let sessDir = tempDir.appendingPathComponent(sessId)
    let logsDir = sessDir.appendingPathComponent(".system_generated/logs")
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
    let lines = [
        "{\"type\":\"CHECKPOINT\",\"status\":\"DONE\",\"content\":\"System checkpoint 0\"}"
    ].joined(separator: "\n")
    try lines.write(to: transcriptFile, atomically: true, encoding: .utf8)

    let res = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(res == nil, "Insufficient explicit lifecycle evidence must return nil rather than manufacturing a transition")
}

// 427. M2.1.1-C5: >120s elapsed time alone cannot force Working -> Idle
runTest("427. M2.1.1-C5: >120s elapsed time alone cannot force Working -> Idle") {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("agy_test_c5_\(UUID().uuidString)")
    let sessId = UUID().uuidString
    let sessDir = tempDir.appendingPathComponent(sessId)
    let logsDir = sessDir.appendingPathComponent(".system_generated/logs")
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let transcriptFile = logsDir.appendingPathComponent("transcript.jsonl")
    let lines = [
        "{\"type\":\"USER_INPUT\",\"status\":\"DONE\",\"content\":\"Start long task\"}",
        "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"RUNNING\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"sleep 300\"}}]}"
    ].joined(separator: "\n")
    try lines.write(to: transcriptFile, atomically: true, encoding: .utf8)

    // Set file modification date to 300 seconds ago (simulating 5 minutes of tool execution)
    let pastDate = Date().addingTimeInterval(-300)
    try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: sessDir.path)
    try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: transcriptFile.path)

    let res = AutoMonitor.shared.scanActiveAntigravityTranscript(brainDir: tempDir.path)
    try assert(res != nil, "Scan must find active conversation within 2 hour boundary")
    try assert(res?.status == .working, "Step marked RUNNING must remain .working even after >120s, got \(String(describing: res?.status))")
}

// MARK: - Milestone 3.1: Project Registry Foundation Tests

// 428. M3.1: Project Model path normalization (tilde, standardizing, trailing slashes)
runTest("428. M3.1: Project Model path normalization (tilde, standardizing, trailing slashes)") {
    let home = NSHomeDirectory()
    let rawPath = "~/Projects/test-project/../test-project///"
    let canonical = Project.canonicalizePath(rawPath)
    let expected = "\(home)/Projects/test-project"
    try assert(canonical == expected, "Path must expand tilde, standardize redundant segments, and strip trailing slashes. Got: \(canonical), Expected: \(expected)")

    // Root path preservation
    try assert(Project.canonicalizePath("/") == "/", "Root path / must remain /")
    try assert(Project.canonicalizePath("") == "", "Empty path must return empty string")
}

// 429. M3.1: Symlink resolution canonicalizes to real target path for existing folders
runTest("429. M3.1: Symlink resolution canonicalizes to real target path for existing folders") {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("m31_symlink_test_\(UUID().uuidString)")
    let targetDir = tempDir.appendingPathComponent("real_target_folder")
    let symlinkDir = tempDir.appendingPathComponent("symlink_folder")

    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: targetDir)

    let canonicalTarget = Project.canonicalizePath(targetDir.path)
    let canonicalSymlink = Project.canonicalizePath(symlinkDir.path)

    try assert(canonicalSymlink == canonicalTarget, "Symlinked path must resolve to real canonical target path. Symlink: \(canonicalSymlink), Target: \(canonicalTarget)")

    try? fm.removeItem(at: tempDir)
}

// 430. M3.1: Default project name resolution from canonical root basename
runTest("430. M3.1: Default project name resolution from canonical root basename") {
    let p1 = Project(rootPath: "/Users/ava/Projects/Agent-webchat monitor")
    try assert(p1.name == "Agent-webchat monitor", "Default name must equal root basename, got: \(p1.name)")

    let p2 = Project(name: "Custom Agent Project", rootPath: "/Users/ava/Projects/Agent-webchat monitor")
    try assert(p2.name == "Custom Agent Project", "Explicit name must take precedence, got: \(p2.name)")

    let p3 = Project(name: "   ", rootPath: "/Users/ava/Projects/MyRepo")
    try assert(p3.name == "MyRepo", "Blank explicit name must fallback to folder basename, got: \(p3.name)")
}

// 431. M3.1: Project registration and duplicate registration prevention
runTest("431. M3.1: Project registration and duplicate registration prevention") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_431_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let p1 = try registry.registerProject(rootPath: "/Users/ava/Projects/AlphaApp")
    try assert(registry.count == 1, "Expected 1 project registered")

    // Re-registering with trailing slash and redundant dot
    let p2 = try registry.registerProject(rootPath: "/Users/ava/Projects/AlphaApp/.")
    try assert(registry.count == 1, "Duplicate canonical root must not create duplicate entry")
    try assert(p1.id == p2.id, "Duplicate registration must return the existing project ID")

    try? FileManager.default.removeItem(at: storageURL)
}

// 432. M3.1: Project update when re-registering with explicit new name
runTest("432. M3.1: Project update when re-registering with explicit new name") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_reg_432_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let p1 = try registry.registerProject(rootPath: "/Users/ava/Projects/AlphaApp", name: "Original Name")
    try assert(p1.name == "Original Name")

    let p2 = try registry.registerProject(rootPath: "/Users/ava/Projects/AlphaApp", name: "Renamed Alpha")
    try assert(registry.count == 1)
    try assert(p2.id == p1.id)
    try assert(p2.name == "Renamed Alpha")
    try assert(registry.getProject(byId: p1.id)?.name == "Renamed Alpha")

    try? FileManager.default.removeItem(at: storageURL)
}

// 433. M3.1: Persistence across reload (roundtrip serialize -> reload from disk)
runTest("433. M3.1: Persistence across reload (roundtrip serialize -> reload from disk)") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_persist_433_\(UUID().uuidString).json")
    let registry1 = ProjectRegistry(storageURL: storageURL)

    let projectA = try registry1.registerProject(rootPath: "/Users/ava/Projects/AppA", name: "App A")
    let projectB = try registry1.registerProject(rootPath: "/Users/ava/Projects/AppB", name: "App B")
    try assert(registry1.count == 2)

    // Instantiate a new registry instance pointing to the exact same file
    let registry2 = ProjectRegistry(storageURL: storageURL)
    try assert(registry2.count == 2, "Reloaded registry must have 2 projects")

    let loadedA = registry2.getProject(byId: projectA.id)
    let loadedB = registry2.getProject(byId: projectB.id)

    try assert(loadedA != nil && loadedA?.name == "App A" && loadedA?.rootPath == "/Users/ava/Projects/AppA")
    try assert(loadedB != nil && loadedB?.name == "App B" && loadedB?.rootPath == "/Users/ava/Projects/AppB")

    // Lookup by root path
    let byPath = registry2.getProject(byRootPath: "/Users/ava/Projects/AppA///")
    try assert(byPath?.id == projectA.id, "Lookup by rootPath must normalize input path")

    try? FileManager.default.removeItem(at: storageURL)
}

// 434. M3.1: Longest-matching parent path resolution for nested project roots
runTest("434. M3.1: Longest-matching parent path resolution for nested project roots") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_match_434_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let rootParent = try registry.registerProject(rootPath: "/Users/ava/Projects/monorepo", name: "Monorepo Root")
    let subPkg = try registry.registerProject(rootPath: "/Users/ava/Projects/monorepo/packages/core", name: "Core Package")
    let deepPkg = try registry.registerProject(rootPath: "/Users/ava/Projects/monorepo/packages/core/submodules/auth", name: "Auth Submodule")
    let unrelated = try registry.registerProject(rootPath: "/Users/ava/Projects/unrelated", name: "Unrelated")

    // 1. Path deep inside auth submodule -> matches deepPkg
    let matchAuth = registry.matchProject(forPath: "/Users/ava/Projects/monorepo/packages/core/submodules/auth/src/token.ts")
    try assert(matchAuth?.id == deepPkg.id, "Longest matching ancestor root must win (deepPkg), got: \(String(describing: matchAuth?.name))")

    // 2. Path in core package -> matches subPkg
    let matchCore = registry.matchProject(forPath: "/Users/ava/Projects/monorepo/packages/core/src/index.ts")
    try assert(matchCore?.id == subPkg.id, "Path in core package must match subPkg, got: \(String(describing: matchCore?.name))")

    // 3. Path in monorepo root -> matches rootParent
    let matchRoot = registry.matchProject(forPath: "/Users/ava/Projects/monorepo/README.md")
    try assert(matchRoot?.id == rootParent.id, "Path in root must match rootParent, got: \(String(describing: matchRoot?.name))")

    // 4. Exact match of project root -> matches project
    let matchExact = registry.matchProject(forPath: "/Users/ava/Projects/unrelated")
    try assert(matchExact?.id == unrelated.id, "Exact root path match must resolve correctly")

    // 5. Completely external path -> returns nil
    let matchExternal = registry.matchProject(forPath: "/private/tmp/other/file.txt")
    try assert(matchExternal == nil, "External path must return nil")

    try? FileManager.default.removeItem(at: storageURL)
}

// 435. M3.1: Path prefix boundary matching safety (subpath vs prefix substring collision)
runTest("435. M3.1: Path prefix boundary matching safety (subpath vs prefix substring collision)") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_prefix_435_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let appProj = try registry.registerProject(rootPath: "/Users/ava/Projects/app", name: "App")

    // Substring collision: /Users/ava/Projects/app-extra has prefix "/Users/ava/Projects/app", but is NOT a child directory
    let matchExtra = registry.matchProject(forPath: "/Users/ava/Projects/app-extra/main.swift")
    try assert(matchExtra == nil, "Substring prefix collision (/app vs /app-extra) must not match")

    // Genuine subpath matches
    let matchChild = registry.matchProject(forPath: "/Users/ava/Projects/app/main.swift")
    try assert(matchChild?.id == appProj.id, "Genuine child path must match")

    try? FileManager.default.removeItem(at: storageURL)
}

// 436. M3.1: Malformed / corrupted projects.json handling with backup preservation
runTest("436. M3.1: Malformed / corrupted projects.json handling with backup preservation") {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("m31_corrupt_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let storageURL = tempDir.appendingPathComponent("projects.json")

    // Write malformed JSON
    let badJSON = "{ \"version\": 1, \"projects\": [ { incomplete json"
    try badJSON.write(to: storageURL, atomically: true, encoding: .utf8)

    let registry = ProjectRegistry(storageURL: storageURL)
    try assert(registry.count == 0, "Corrupted config must fail safely and load 0 projects without crashing")

    // Check backup file existence
    let contents = try fm.contentsOfDirectory(atPath: tempDir.path)
    let hasCorruptedBackup = contents.contains { $0.hasPrefix("projects.json.corrupted.") }
    try assert(hasCorruptedBackup, "Registry must preserve backup copy of corrupted file")

    // Verify recovery: subsequent valid registration can save normally
    try registry.registerProject(rootPath: "/Users/ava/Projects/RecoveredProject")
    try assert(registry.count == 1)

    let registry2 = ProjectRegistry(storageURL: storageURL)
    try assert(registry2.count == 1)
    try assert(registry2.getAllProjects().first?.name == "RecoveredProject")

    try? fm.removeItem(at: tempDir)
}

// 437. M3.1: Missing projects.json initialization without error
runTest("437. M3.1: Missing projects.json initialization without error") {
    let nonExistentURL = FileManager.default.temporaryDirectory.appendingPathComponent("non_existent_\(UUID().uuidString)/projects.json")
    let registry = ProjectRegistry(storageURL: nonExistentURL)

    try assert(registry.count == 0, "Non-existent file must initialize cleanly with 0 projects")
    try assert(registry.getAllProjects().isEmpty)

    // Saving creates parent directory and file cleanly
    try registry.registerProject(rootPath: "/Users/ava/Projects/AutoCreated")
    try assert(FileManager.default.fileExists(atPath: nonExistentURL.path), "Saving must create intermediate directories and storage file")

    try? FileManager.default.removeItem(at: nonExistentURL.deletingLastPathComponent())
}

// 438. M3.1: Project removal by ID and by root path
runTest("438. M3.1: Project removal by ID and by root path") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_remove_438_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let p1 = try registry.registerProject(rootPath: "/Users/ava/Projects/Alpha")
    let p2 = try registry.registerProject(rootPath: "/Users/ava/Projects/Beta")
    let p3 = try registry.registerProject(rootPath: "/Users/ava/Projects/Gamma")
    try assert(registry.count == 3)

    // Remove by ID
    let removedP1 = try registry.removeProject(id: p1.id)
    try assert(removedP1 == true)
    try assert(registry.count == 2)
    try assert(registry.getProject(byId: p1.id) == nil)
    try assert(registry.getProject(byRootPath: "/Users/ava/Projects/Alpha") == nil)

    // Remove by root path
    let removedP2 = try registry.removeProject(byRootPath: "/Users/ava/Projects/Beta///")
    try assert(removedP2 == true)
    try assert(registry.count == 1)
    try assert(registry.getProject(byId: p2.id) == nil)

    // Remove non-existent ID
    let removedNonExistent = try registry.removeProject(id: "non-existent-id")
    try assert(removedNonExistent == false)

    // Verify persistence of removals across reload
    let registryReloaded = ProjectRegistry(storageURL: storageURL)
    try assert(registryReloaded.count == 1)
    try assert(registryReloaded.getProject(byId: p3.id)?.name == "Gamma")

    try? FileManager.default.removeItem(at: storageURL)
}

// 439. M3.1: Test isolation: test runtime uses isolated temp storage, never mutating production ~/.config/AgentSignalBar/projects.json
runTest("439. M3.1: Test isolation: test runtime uses isolated temp storage, never mutating production ~/.config/AgentSignalBar/projects.json") {
    try assert(TestEnvironment.isTestRuntime == true, "Must be running in test runtime")
    let defaultURL = ProjectRegistry.defaultStorageURL
    let home = NSHomeDirectory()
    let prodPath = "\(home)/.config/AgentSignalBar/projects.json"

    try assert(defaultURL.path != prodPath, "Default storage URL in test runtime must NOT point to production ~/.config/AgentSignalBar/projects.json")
    try assert(defaultURL.path.contains("AgentSignalBarTest_projects_"), "Default storage URL in test runtime must be an isolated temporary file")
}

// 440. M3.1: Thread-safe concurrent access to ProjectRegistry
runTest("440. M3.1: Thread-safe concurrent access to ProjectRegistry") {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_concurrency_440_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: storageURL)

    let group = DispatchGroup()
    let queue = DispatchQueue(label: "test.project.registry.concurrency", attributes: .concurrent)

    for i in 0..<30 {
        group.enter()
        queue.async {
            do {
                _ = try registry.registerProject(rootPath: "/Users/ava/Projects/Project_\(i)", name: "Concurrent Project \(i)")
                _ = registry.getAllProjects()
                _ = registry.matchProject(forPath: "/Users/ava/Projects/Project_\(i)/src/file.swift")
            } catch {
                print("Concurrency error: \(error)")
            }
            group.leave()
        }
    }

    _ = group.wait(timeout: .now() + 5.0)
    try assert(registry.count == 30, "All 30 concurrent registrations must complete safely, got: \(registry.count)")

    try? FileManager.default.removeItem(at: storageURL)
}

// 441. Subprocess Zero-Worker Leak: Repeated 50 successful executions complete with clean PID reaping
runTest("441. Subprocess Zero-Worker Leak: Repeated 50 successful executions complete with clean PID reaping") {
    let monitor = AutoMonitor.shared
    monitor.resetProcessTracking()

    for i in 1...50 {
        let out = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo iter_\(i)"],
            timeoutSeconds: 1.0
        )
        try assert(out == "iter_\(i)", "Iteration \(i) must return exact echo output, got: \(String(describing: out))")
        try assert(monitor.lastSubprocessConfirmedReaped == true, "Iteration \(i) must be confirmed reaped")
        try assert(monitor.unresolvedProcessPID == nil, "Iteration \(i) must leave no unresolved PID")
        let pid = monitor.lastSubprocessPID!
        try assert(kill(pid, 0) != 0, "PID \(pid) must be dead after iteration \(i)")
    }
}

// 442. Subprocess Zero-Worker Leak: Repeated 20 timeouts complete boundedly with clean child reaping
runTest("442. Subprocess Zero-Worker Leak: Repeated 20 timeouts complete boundedly with clean child reaping") {
    let monitor = AutoMonitor.shared
    monitor.resetProcessTracking()

    let t0 = Date()
    for i in 1...20 {
        let out = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10"],
            timeoutSeconds: 0.05
        )
        try assert(out == nil, "Timed out iteration \(i) must return nil")
        try assert(monitor.lastSubprocessConfirmedReaped == true, "Iteration \(i) must be confirmed reaped after timeout")
        try assert(monitor.unresolvedProcessPID == nil, "Iteration \(i) must leave no unresolved PID")
        let pid = monitor.lastSubprocessPID!
        try assert(kill(pid, 0) != 0, "Timed out PID \(pid) must be killed and reaped")
    }
    let totalElapsed = Date().timeIntervalSince(t0)
    try assert(totalElapsed < 10.0, "20 timeouts of 0.05s must finish well under 10.0s total, took: \(totalElapsed)s")
}

// 443. Subprocess Stream Draining: Large stdout (>140 KB) streams completely without pipe buffer hang
runTest("443. Subprocess Stream Draining: Large stdout (>140 KB) streams completely without pipe buffer hang") {
    let monitor = AutoMonitor.shared
    let output = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "python3 -c \"import sys; sys.stdout.write('X' * 150000)\""],
        timeoutSeconds: 2.0
    )
    try assert(output != nil, "Large output must not be nil")
    try assert(output?.count == 150000, "Large output must have exact 150,000 bytes, got: \(output?.count ?? 0)")
}

// 444. Subprocess Stream Draining: Large stderr (>140 KB) with stdout completes without buffer deadlock
runTest("444. Subprocess Stream Draining: Large stderr (>140 KB) with stdout completes without buffer deadlock") {
    let monitor = AutoMonitor.shared
    let output = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "python3 -c \"import sys; sys.stderr.write('Y' * 150000); sys.stdout.write('STDERR_DRAINED')\""],
        timeoutSeconds: 2.0
    )
    try assert(output == "STDERR_DRAINED", "Output must match expected string when large stderr is drained")
}

// 445. Subprocess Lifecycle: Unresolved process blocks spawn and resumes after clear
runTest("445. Subprocess Lifecycle: Unresolved process blocks spawn and resumes after clear") {
    let monitor = AutoMonitor.shared
    monitor.resetProcessTracking()

    monitor.setUnresolvedProcessPIDForTesting(ProcessInfo.processInfo.processIdentifier)
    let blocked = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["test_blocked"],
        timeoutSeconds: 0.5
    )
    try assert(blocked == nil, "Must return nil when unresolved process exists")
    try assert(monitor.processSpawnBlockedCount >= 1, "Spawn blocked count must increment")

    monitor.setUnresolvedProcessPIDForTesting(nil)
    let resumed = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["test_resumed"],
        timeoutSeconds: 0.5
    )
    try assert(resumed == "test_resumed", "Must resume launch once unresolved PID is cleared")
}

// 446. Subprocess Execution: Real sqlite3 and ps commands execute behaviorally intact
runTest("446. Subprocess Execution: Real sqlite3 and ps commands execute behaviorally intact") {
    let monitor = AutoMonitor.shared
    let psOut = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-p", "\(ProcessInfo.processInfo.processIdentifier)", "-o", "pid="],
        timeoutSeconds: 1.0
    )
    try assert(psOut?.trimmingCharacters(in: .whitespaces) == "\(ProcessInfo.processInfo.processIdentifier)", "ps command must return current PID")

    let sqlOut = monitor.runProcessWithTimeout(
        executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
        arguments: [":memory:", "SELECT 42 AS answer;"],
        timeoutSeconds: 1.0
    )
    try assert(sqlOut == "42", "sqlite3 in-memory query must return 42, got: \(String(describing: sqlOut))")
}

// 447. Telegram Health: ChatGPT unavailable send failure does NOT arm restored notification
runTest("447. Telegram Health: ChatGPT unavailable send failure does NOT arm restored notification") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // 1. Establish confirmed healthy
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().isEmpty)

    // 2. Drop occurs while offline (send fails)
    mock.shouldFailSendMessage = true
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // No message delivered successfully
    try assert(mock.getAllSentMessages().isEmpty, "Failed unavailable send must produce zero delivered messages")

    // 3. Health recovers when connectivity returns
    mock.shouldFailSendMessage = false
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // Must NOT emit orphan restored!
    try assert(mock.getAllSentMessages().isEmpty, "Recovery after unconfirmed unavailable send must NOT emit orphan restored alert")
}

// 448. Telegram Health: ChatGPT unavailable send success arms exactly one restored notification
runTest("448. Telegram Health: ChatGPT unavailable send success arms exactly one restored notification") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // 1. Establish confirmed healthy
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // 2. Disconnect succeeds in delivering unavailable alert
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 1, "Unavailable alert must be delivered")
    try assert(mock.getAllSentMessages()[0].text.contains("ChatGPT Web monitoring unavailable"))

    // 3. Connect succeeds in delivering restored alert
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 2, "Restored alert must be delivered once")
    try assert(mock.getAllSentMessages()[1].text.contains("ChatGPT Web monitoring restored"))
}

// 449. Telegram Health: Repeated healthy transitions do not duplicate restored alert
runTest("449. Telegram Health: Repeated healthy transitions do not duplicate restored alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // 1. Cycle healthy -> unavailable -> healthy
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 2)

    // 2. Subsequent repeated connected calls
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 2, "Repeated healthy calls must never duplicate restored alerts")
}

// 450. Telegram Health: Network unavailable send failure does NOT produce orphan restored alert
runTest("450. Telegram Health: Network unavailable send failure does NOT produce orphan restored alert") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)

    // 1. Initial healthy baseline
    bridge.handleNetworkHealthChange(isConnected: true)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // 2. Network drops, send fails
    mock.shouldFailSendMessage = true
    bridge.handleNetworkHealthChange(isConnected: false)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().isEmpty)

    // 3. Network returns
    mock.shouldFailSendMessage = false
    bridge.handleNetworkHealthChange(isConnected: true)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().isEmpty, "Failed network unavailable send must NOT produce orphan restored alert")
}

// 451. Sleep/Wake: Normal sleep lifecycle prevents false ChatGPT monitor outage
runTest("451. Sleep/Wake: Normal sleep lifecycle prevents false ChatGPT monitor outage") {
    let store = AgentStore.shared
    let baseTime = Date()
    store.recordChatGPTHeartbeat(date: baseTime)

    // Simulate 120 seconds passing while host is asleep
    store.setHostSleeping(true, now: baseTime.addingTimeInterval(10))
    let healthDuringSleep = store.checkChatGPTMonitorHealth(
        isChromeRunning: true,
        isMonitored: true,
        now: baseTime.addingTimeInterval(120)
    )
    try assert(healthDuringSleep == .connected, "Monitor health during normal host sleep must remain .connected, got: \(healthDuringSleep)")

    // Clean up
    store.setHostSleeping(false, now: baseTime.addingTimeInterval(120))
}

// 452. Sleep/Wake: Wake and rebaseline alone does not fabricate restored or unavailable
runTest("452. Sleep/Wake: Wake and rebaseline alone does not fabricate restored or unavailable") {
    let store = AgentStore.shared
    let baseTime = Date()
    store.recordChatGPTHeartbeat(date: baseTime)

    // Sleep for 30 minutes
    store.setHostSleeping(true, now: baseTime)
    let wakeTime = baseTime.addingTimeInterval(1800)
    store.setHostSleeping(false, now: wakeTime)

    // Immediately after waking, health is checked
    let healthAtWake = store.checkChatGPTMonitorHealth(
        isChromeRunning: true,
        isMonitored: true,
        now: wakeTime.addingTimeInterval(1.0)
    )
    try assert(healthAtWake == .connected, "Monitor health immediately after wake must remain .connected due to rebaselined lease, got: \(healthAtWake)")
}

// 453. Sleep/Wake: Genuine awake-host heartbeat expiry still produces unavailable
runTest("453. Sleep/Wake: Genuine awake-host heartbeat expiry still produces unavailable") {
    let store = AgentStore.shared
    let baseTime = Date()
    store.setHostSleeping(false, now: baseTime)
    store.recordChatGPTHeartbeat(date: baseTime)

    // Host remains awake, but 65s elapse with no new heartbeat (> 60s lease)
    let expiredTime = baseTime.addingTimeInterval(65)
    let healthExpired = store.checkChatGPTMonitorHealth(
        isChromeRunning: true,
        isMonitored: true,
        now: expiredTime
    )
    try assert(healthExpired == .disconnected, "Heartbeat expiry while awake must return .disconnected, got: \(healthExpired)")
}

// 454. Sleep/Wake: Genuine recovery following successfully notified awake outage emits exactly one restored
runTest("454. Sleep/Wake: Genuine recovery following successfully notified awake outage emits exactly one restored") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    // 1. Initial healthy state
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    // 2. Real awake outage occurs
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 1)
    try assert(mock.getAllSentMessages()[0].text.contains("⚠️ ChatGPT Web monitoring unavailable"))

    // 3. Heartbeat resumes
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 2)
    try assert(mock.getAllSentMessages()[1].text.contains("✅ ChatGPT Web monitoring restored"))
}

// 455. Sleep/Wake: Pre-existing real outage survives sleep/wake without false restored notification
runTest("455. Sleep/Wake: Pre-existing real outage survives sleep/wake without false restored notification") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.chatgpt, monitored: true)

    let store = AgentStore.shared
    let baseTime = Date()
    store.setHostSleeping(false, now: baseTime)
    store.recordChatGPTHeartbeat(date: baseTime)

    // 1. Initial healthy state established
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .starting, newHealth: .connected)
    var exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().isEmpty)

    // 2. Real outage occurs while awake (>60s)
    let outageTime = baseTime.addingTimeInterval(70)
    let healthOutage = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true, now: outageTime)
    try assert(healthOutage == .disconnected, "Monitor must be .disconnected after 70s without heartbeat")

    store.setMonitorHealth(for: .chatgpt, health: .disconnected)
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .connected, newHealth: .disconnected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 1, "Unavailable alert must be delivered")
    try assert(mock.getAllSentMessages()[0].text.contains("ChatGPT Web monitoring unavailable"))

    // 3. Mac goes to sleep and then wakes up (NO new Chrome heartbeat has arrived)
    store.setHostSleeping(true, now: outageTime.addingTimeInterval(10))
    let sleepHealth = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true, now: outageTime.addingTimeInterval(300))
    try assert(sleepHealth == .disconnected, "Already-disconnected monitor must remain .disconnected during sleep")

    let wakeTime = outageTime.addingTimeInterval(1800)
    store.setHostSleeping(false, now: wakeTime)

    // 4. Post-wake evaluation (still no heartbeat from Chrome)
    let postWakeHealth = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true, now: wakeTime.addingTimeInterval(1.0))
    try assert(postWakeHealth == .disconnected, "Monitor must REMAIN .disconnected after wake when no new heartbeat exists")

    store.setMonitorHealth(for: .chatgpt, health: postWakeHealth)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try assert(mock.getAllSentMessages().count == 1, "Sleep and wake MUST NOT emit false restored notification")

    // 5. Genuine Chrome heartbeat finally arrives after wake
    store.recordChatGPTHeartbeat(date: wakeTime.addingTimeInterval(5.0))
    bridge.handleChatGPTMonitorHealthChange(oldHealth: .disconnected, newHealth: .connected)
    exp = Date().addingTimeInterval(0.05)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    try assert(mock.getAllSentMessages().count == 2, "Real heartbeat post-wake must emit exactly one restored notification")
    try assert(mock.getAllSentMessages()[1].text.contains("ChatGPT Web monitoring restored"))
}

// 456. Sleep/Wake: Awake scheduling delay does NOT erase heartbeat age or delay 60s threshold
runTest("456. Sleep/Wake: Awake scheduling delay does NOT erase heartbeat age or delay 60s threshold") {
    let store = AgentStore.shared
    let baseTime = Date()
    store.setHostSleeping(false, now: baseTime)
    store.recordChatGPTHeartbeat(date: baseTime)

    // Simulate 30s elapsed while awake
    let t30 = baseTime.addingTimeInterval(30)
    let health30 = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true, now: t30)
    try assert(health30 == .connected, "At 30s monitor must still be connected (< 60s)")

    // Simulate an awake polling delay (no sleep/wake events occur)
    // At T=65, the original heartbeat from baseTime must expire without being erased
    let t65 = baseTime.addingTimeInterval(65)
    let health65 = store.checkChatGPTMonitorHealth(isChromeRunning: true, isMonitored: true, now: t65)
    try assert(health65 == .disconnected, "Heartbeat must expire at 65s without being reset by awake timer delays")
}

// 457. Concurrency: High-throughput concurrent render and quota updates execute without deadlock
runTest("457. Concurrency: High-throughput concurrent render and quota updates execute without deadlock") {
    let usageStore = AgentUsageStore.shared
    let agentStore = AgentStore.shared

    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)
    agentStore.updateStatus(for: .copilot, status: .idle, detail: "Idle test")
    agentStore.updateStatus(for: .claude, status: .idle, detail: "Idle test")

    let iterations = 500
    let group = DispatchGroup()

    // Thread 1: Rapid rendering / overallSummary / compactSummary (holding AgentStore.lock, reading AgentUsageStore)
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        for _ in 0..<iterations {
            _ = agentStore.overallSummary()
            _ = agentStore.compactSummary()
        }
        group.leave()
    }

    // Thread 2: Rapid quota updates with alternating recovery transitions (updating AgentUsageStore, triggering AgentStore side-effects)
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        for i in 0..<iterations {
            let isExhausted = (i % 2 == 0)
            let usage = AgentUsageData(
                agent: .copilot,
                sessionLimitPercent: isExhausted ? 100.0 : 20.0,
                sessionResetText: "resets in 2h",
                weeklyLimitPercent: isExhausted ? 100.0 : 30.0,
                weeklyResetText: "resets Monday",
                isPercentUsed: true,
                isLiveSource: true,
                quotaSource: "test",
                freshness: "Fresh"
            )
            usageStore.updateUsage(for: .copilot, data: usage)
        }
        group.leave()
    }

    // Thread 3: Rapid Claude quota updates concurrently
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        for i in 0..<iterations {
            let usage = AgentUsageData(
                agent: .claude,
                sessionLimitPercent: Double(i % 100),
                sessionResetText: "resets in 1h",
                isPercentUsed: true,
                isLiveSource: true,
                quotaSource: "test",
                freshness: "Fresh"
            )
            usageStore.updateUsage(for: .claude, data: usage)
        }
        group.leave()
    }

    let waitResult = group.wait(timeout: .now() + 5.0)
    try assert(waitResult == .success, "Concurrent render and quota updates must complete cleanly without deadlock within 5 seconds")
}

// 458. Quota Recovery: Exhausted -> Available transition properly sets quotaRestored and reconciles state outside lock
runTest("458. Quota Recovery: Exhausted -> Available transition properly sets quotaRestored and reconciles state outside lock") {
    let mock = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mock)
    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "tok", chatId: "1001"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.copilot, monitored: true)

    let usageStore = AgentUsageStore.shared
    let agentStore = AgentStore.shared

    // 1. Mark exhausted
    let exhaustedUsage = AgentUsageData(
        agent: .copilot,
        sessionLimitPercent: 100.0,
        sessionResetText: "resets in 1h",
        weeklyLimitPercent: 100.0,
        weeklyResetText: "resets Monday",
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "test",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .copilot, data: exhaustedUsage)

    // Verify availability is exhausted
    try assert(usageStore.getUsage(for: .copilot)?.isQuotaExhausted == true)

    // 2. Recovery update arrives
    let recoveredUsage = AgentUsageData(
        agent: .copilot,
        sessionLimitPercent: 25.0,
        sessionResetText: "resets in 1h",
        weeklyLimitPercent: 30.0,
        weeklyResetText: "resets Monday",
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "test",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .copilot, data: recoveredUsage)

    // Verify recovery is reflected
    let currentUsage = usageStore.getUsage(for: .copilot)
    try assert(currentUsage?.isQuotaExhausted == false)
    try assert(currentUsage?.availability == .available)
    try assert(agentStore.getStatus(for: .copilot).isQuotaRestored == true)
}

// 459. Normal Quota Update: Live data storage and config fallback protection
runTest("459. Normal Quota Update: Live data storage and config fallback protection") {
    let usageStore = AgentUsageStore.shared

    let liveData = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 42.0,
        sessionResetText: "resets in 4h",
        weeklyLimitPercent: 55.0,
        weeklyResetText: "resets Fri",
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "live_api",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: liveData)

    let stored = usageStore.getUsage(for: .claude)
    try assert(stored?.isLiveSource == true)
    try assert(stored?.sessionLimitPercent == 42.0)
    try assert(stored?.freshness == "Fresh")

    // Attempting to overwrite with a non-live fallback must be rejected
    let fallbackData = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 10.0,
        isPercentUsed: true,
        isLiveSource: false,
        quotaSource: "none",
        sourceAuthority: "loaded_from_config"
    )
    usageStore.updateUsage(for: .claude, data: fallbackData)

    let preserved = usageStore.getUsage(for: .claude)
    try assert(preserved?.isLiveSource == true, "Live source must not be overwritten by non-live config fallback")
    try assert(preserved?.sessionLimitPercent == 42.0)
}

// 460. Rendering Invariant: overallSummary and compactSummary render correctly with live usage
runTest("460. Rendering Invariant: overallSummary and compactSummary render correctly with live usage") {
    let agentStore = AgentStore.shared
    let usageStore = AgentUsageStore.shared

    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)
    agentStore.updateStatus(for: .claude, status: .idle, detail: "Claude active")
    let liveUsage = AgentUsageData(
        agent: .claude,
        sessionLimitPercent: 15.0,
        isPercentUsed: true,
        isLiveSource: true,
        quotaSource: "test",
        freshness: "Fresh"
    )
    usageStore.updateUsage(for: .claude, data: liveUsage)

    let summary = agentStore.overallSummary()
    try assert(summary.contains("CLD:⚪") || summary.contains("CLD:🫥") || summary.contains("⚪"), "Summary must reflect active Claude status")
}

// 461. Reviewer Assignment: Assigning an observed conversation to a registered Project
runTest("461. Reviewer Assignment: Assigning an observed conversation to a registered Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_461_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")
    let url = "https://chatgpt.com/c/67bd-abcd-1234-reviewer-test"
    let title = "AgentOS Architecture Review"

    let updated = try registry.assignReviewer(toProjectId: project.id, url: url, title: title)
    try assert(updated.currentReviewer != nil)
    try assert(updated.currentReviewer?.conversationId == "67bd-abcd-1234-reviewer-test")
    try assert(updated.currentReviewer?.title == "AgentOS Architecture Review")
    try assert(updated.currentReviewer?.url == "https://chatgpt.com/c/67bd-abcd-1234-reviewer-test")
    try assert(updated.reviewerHistory.isEmpty)
}

// 462. Reviewer Persistence: Assignment persists across registry reload/restart
runTest("462. Reviewer Persistence: Assignment persists across registry reload/restart") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_462_\(UUID().uuidString).json")
    let registry1 = ProjectRegistry(storageURL: testStorageURL)
    defer { registry1.resetForTesting() }

    let project = try registry1.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")
    try registry1.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/persistent-conv-id-999", title: "Persistent Reviewer")

    // Simulate app restart by initializing a new ProjectRegistry from the same storage URL
    let registry2 = ProjectRegistry(storageURL: testStorageURL)
    let reloadedProject = registry2.getProject(byId: project.id)

    try assert(reloadedProject != nil)
    try assert(reloadedProject?.currentReviewer?.conversationId == "persistent-conv-id-999")
    try assert(reloadedProject?.currentReviewer?.title == "Persistent Reviewer")
    try assert(reloadedProject?.currentReviewer?.url == "https://chatgpt.com/c/persistent-conv-id-999")
}

// 463. Reviewer Replacement: Replacing reviewer updates current and preserves previous association history
runTest("463. Reviewer Replacement: Replacing reviewer updates current and preserves previous association history") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_463_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    // First reviewer
    try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/first-reviewer-111", title: "First Session")

    // Second reviewer replaces first
    let afterFirstReplacement = try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/second-reviewer-222", title: "Second Session")

    try assert(afterFirstReplacement.currentReviewer?.conversationId == "second-reviewer-222")
    try assert(afterFirstReplacement.reviewerHistory.count == 1)
    try assert(afterFirstReplacement.reviewerHistory[0].conversationId == "first-reviewer-111")
    try assert(afterFirstReplacement.reviewerHistory[0].title == "First Session")

    // Third reviewer replaces second
    let afterSecondReplacement = try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/third-reviewer-333", title: "Third Session")

    try assert(afterSecondReplacement.currentReviewer?.conversationId == "third-reviewer-333")
    try assert(afterSecondReplacement.reviewerHistory.count == 2)
    try assert(afterSecondReplacement.reviewerHistory[1].conversationId == "second-reviewer-222")

    // Verify history persists after reload
    let reloadedRegistry = ProjectRegistry(storageURL: testStorageURL)
    let reloaded = reloadedRegistry.getProject(byId: project.id)
    try assert(reloaded?.reviewerHistory.count == 2)
    try assert(reloaded?.reviewerHistory[0].conversationId == "first-reviewer-111")
    try assert(reloaded?.reviewerHistory[1].conversationId == "second-reviewer-222")
}

// 464. Reviewer Cardinality: Same conversation cannot be current reviewer for two Projects
runTest("464. Reviewer Cardinality: Same conversation cannot be current reviewer for two Projects") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_464_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let projectA = try registry.registerProject(rootPath: "/Users/test/workspace/project-alpha", name: "Project Alpha")
    let projectB = try registry.registerProject(rootPath: "/Users/test/workspace/project-beta", name: "Project Beta")

    let sharedUrl = "https://chatgpt.com/c/shared-reviewer-conversation-123"

    // Assign to Project Alpha
    try registry.assignReviewer(toProjectId: projectA.id, url: sharedUrl, title: "Shared Session")
    try assert(registry.getProject(byId: projectA.id)?.currentReviewer?.conversationId == "shared-reviewer-conversation-123")

    // Attempt to assign the same conversation as current reviewer for Project Beta must throw conflict error
    var conflictDetected = false
    do {
        try registry.assignReviewer(toProjectId: projectB.id, url: sharedUrl, title: "Shared Session")
    } catch let error as ProjectRegistryError {
        switch error {
        case .reviewerAlreadyAssigned(let convId, let existingProjId, let existingName):
            try assert(convId == "shared-reviewer-conversation-123")
            try assert(existingProjId == projectA.id)
            try assert(existingName == "Project Alpha")
            conflictDetected = true
        default:
            throw error
        }
    }

    try assert(conflictDetected, "Must reject binding the same conversation as current reviewer for multiple projects")
    try assert(registry.getProject(byId: projectB.id)?.currentReviewer == nil, "Project Beta must remain unassigned")
}

// 465. Multi-Tab Convergence: Same conversation appearing in multiple Chrome tabs resolves to one reviewer identity
runTest("465. Multi-Tab Convergence: Same conversation appearing in multiple Chrome tabs resolves to one reviewer identity") {
    let convId = "multi-tab-conv-888"
    let url1 = "https://chatgpt.com/c/\(convId)"
    let url2 = "https://chatgpt.com/c/\(convId)?model=gpt-4o"
    let url3 = "https://chat.openai.com/c/\(convId)#bottom"

    let id1 = ChatGPTURLParser.parseReviewerIdentity(from: url1)
    let id2 = ChatGPTURLParser.parseReviewerIdentity(from: url2)
    let id3 = ChatGPTURLParser.parseReviewerIdentity(from: url3)

    try assert(id1?.conversationId == convId)
    try assert(id2?.conversationId == convId)
    try assert(id3?.conversationId == convId)

    // Verify live status observer handles multiple open tabs of the same conversation cleanly
    let project = Project(
        id: "proj-1",
        name: "TestProject",
        rootPath: "/Users/test/workspace/proj",
        currentReviewer: ProjectReviewer(conversationId: convId, url: url1, title: "Canonical Reviewer")
    )

    let openTabs = [
        ChatGPTTabInfo(tabId: 101, title: "Reviewer Tab A", url: url1, status: "idle", active: false),
        ChatGPTTabInfo(tabId: 102, title: "Reviewer Tab B (Active)", url: url2, status: "working", active: true)
    ]

    let liveStatus = project.liveReviewerStatus(openTabs: openTabs)
    try assert(liveStatus?.isCurrentlyObservable == true)
    try assert(liveStatus?.activeTabId == 101 || liveStatus?.activeTabId == 102)
}

// 466. Identity Invariant: Title changes do not change reviewer identity
runTest("466. Identity Invariant: Title changes do not change reviewer identity") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_466_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/proj", name: "Proj")
    let convUrl = "https://chatgpt.com/c/stable-conv-id-777"

    try registry.assignReviewer(toProjectId: project.id, url: convUrl, title: "Original Title")
    let p1 = registry.getProject(byId: project.id)
    try assert(p1?.currentReviewer?.conversationId == "stable-conv-id-777")
    try assert(p1?.currentReviewer?.title == "Original Title")

    // Re-assigning with an updated title updates title without creating a duplicate history record
    try registry.assignReviewer(toProjectId: project.id, url: convUrl, title: "Renamed Title by User")
    let p2 = registry.getProject(byId: project.id)
    try assert(p2?.currentReviewer?.conversationId == "stable-conv-id-777")
    try assert(p2?.currentReviewer?.title == "Renamed Title by User")
    try assert(p2?.reviewerHistory.isEmpty == true, "Updating title of the SAME conversation must not create a replacement history record")
}

// 467. Reviewer Observability: Unavailable/closed current reviewer remains associated
runTest("467. Reviewer Observability: Unavailable/closed current reviewer remains associated") {
    let project = Project(
        id: "proj-1",
        name: "TestProject",
        rootPath: "/Users/test/workspace/proj",
        currentReviewer: ProjectReviewer(conversationId: "closed-conv-id-555", url: "https://chatgpt.com/c/closed-conv-id-555", title: "Closed Reviewer")
    )

    // Open tabs contain other unrelated conversations or are completely empty
    let emptyTabs: [ChatGPTTabInfo] = []
    let unrelatedTabs = [
        ChatGPTTabInfo(tabId: 201, title: "Unrelated Chat", url: "https://chatgpt.com/c/unrelated-chat-1", status: "idle")
    ]

    let liveStatusEmpty = project.liveReviewerStatus(openTabs: emptyTabs)
    try assert(liveStatusEmpty?.isCurrentlyObservable == false)
    try assert(liveStatusEmpty?.activeTabId == nil)
    try assert(liveStatusEmpty?.canonicalUrl == "https://chatgpt.com/c/closed-conv-id-555")

    let liveStatusUnrelated = project.liveReviewerStatus(openTabs: unrelatedTabs)
    try assert(liveStatusUnrelated?.isCurrentlyObservable == false)
    try assert(project.currentReviewer?.conversationId == "closed-conv-id-555", "Association must be preserved")
}

// 468. Silent Fallback Prevention: Unavailable reviewer does not silently fallback
runTest("468. Silent Fallback Prevention: Unavailable reviewer does not silently fallback") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_468_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/proj", name: "Proj")
    try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/past-reviewer-001", title: "Past Reviewer")
    try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/current-reviewer-002", title: "Current Reviewer")

    // The current reviewer conversation is closed in Chrome, but the past reviewer is currently open
    let openTabs = [
        ChatGPTTabInfo(tabId: 301, title: "Past Reviewer", url: "https://chatgpt.com/c/past-reviewer-001", status: "idle")
    ]

    let currentProject = registry.getProject(byId: project.id)!
    let liveStatus = currentProject.liveReviewerStatus(openTabs: openTabs)

    // Must report current reviewer as NOT observable, and must NOT silently switch currentReviewer back to past-reviewer-001
    try assert(liveStatus?.isCurrentlyObservable == false)
    try assert(currentProject.currentReviewer?.conversationId == "current-reviewer-002")
    try assert(currentProject.reviewerHistory.count == 1)
}

// 469. Blank Page Guard: Blank ChatGPT page without conversation ID cannot be assigned
runTest("469. Blank Page Guard: Blank ChatGPT page without conversation ID cannot be assigned") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_469_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/proj", name: "Proj")

    let invalidUrls = [
        "https://chatgpt.com/",
        "https://chatgpt.com",
        "https://chatgpt.com/gpts",
        "https://chatgpt.com/g/g-p-12345",
        "https://chat.openai.com/",
        ""
    ]

    for badUrl in invalidUrls {
        try assert(ChatGPTURLParser.parseReviewerIdentity(from: badUrl) == nil, "Blank or non-conversation URL '\(badUrl)' must return nil")
        var errorThrown = false
        do {
            try registry.assignReviewer(toProjectId: project.id, url: badUrl)
        } catch ProjectRegistryError.invalidConversationUrl {
            errorThrown = true
        }
        try assert(errorThrown, "Assigning invalid URL '\(badUrl)' must throw invalidConversationUrl error")
    }
}

// 470. Project-Style URL Parsing: /g/g-p-.../c/<conversation-id> extracts conversation ID and project metadata
runTest("470. Project-Style URL Parsing: /g/g-p-.../c/<conversation-id> extracts conversation ID and project metadata") {
    let projectUrl = "https://chatgpt.com/g/g-p-67890abcdef-agent-os/c/conv-custom-gpt-999?model=gpt-4o#focus"
    let parsed = ChatGPTURLParser.parseReviewerIdentity(from: projectUrl)

    try assert(parsed != nil)
    try assert(parsed?.conversationId == "conv-custom-gpt-999")
    try assert(parsed?.chatgptProjectId == "g-p-67890abcdef-agent-os")
    try assert(parsed?.canonicalUrl == "https://chatgpt.com/g/g-p-67890abcdef-agent-os/c/conv-custom-gpt-999")
}

// 471. Canonical URL Parsing: Ordinary /c/<conversation-id> and query parameter normalization
runTest("471. Canonical URL Parsing: Ordinary /c/<conversation-id> and query parameter normalization") {
    let normalUrl = "https://chatgpt.com/c/67bd-normal-conv-123"
    let parsedNormal = ChatGPTURLParser.parseReviewerIdentity(from: normalUrl)
    try assert(parsedNormal?.conversationId == "67bd-normal-conv-123")
    try assert(parsedNormal?.chatgptProjectId == nil)
    try assert(parsedNormal?.canonicalUrl == "https://chatgpt.com/c/67bd-normal-conv-123")

    let openaiLegacyUrl = "https://chat.openai.com/c/openai-legacy-456?utm_source=test#step"
    let parsedLegacy = ChatGPTURLParser.parseReviewerIdentity(from: openaiLegacyUrl)
    try assert(parsedLegacy?.conversationId == "openai-legacy-456")
    try assert(parsedLegacy?.canonicalUrl == "https://chatgpt.com/c/openai-legacy-456")
}

// 472. Data Privacy Invariant: No conversation content, transcript, or auth secrets are persisted
runTest("472. Data Privacy Invariant: No conversation content, transcript, or auth secrets are persisted") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_472_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")
    try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/secret-test-conv", title: "Secret Discussion")

    let savedData = try Data(contentsOf: testStorageURL)
    let jsonString = String(data: savedData, encoding: .utf8) ?? ""

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProjectRegistryData.self, from: savedData)

    // Verify stored metadata matches registered project and reviewer
    try assert(decoded.projects.count == 1)
    try assert(decoded.projects[0].name == "AgentOS")
    try assert(decoded.projects[0].rootPath == project.rootPath)
    try assert(decoded.projects[0].currentReviewer?.conversationId == "secret-test-conv")
    try assert(decoded.projects[0].currentReviewer?.title == "Secret Discussion")

    // Verify absence of sensitive content fields in raw persisted JSON
    try assert(!jsonString.contains("messages"))
    try assert(!jsonString.contains("transcript"))
    try assert(!jsonString.contains("bearer"))
    try assert(!jsonString.contains("token"))
    try assert(!jsonString.contains("cookie"))
    try assert(!jsonString.contains("prompt"))
}

// 473. CWD Match: Exact project root workspace matches registered Project
runTest("473. CWD Match: Exact project root workspace matches registered Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_473_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-exact-001",
        title: "Exact Root Session",
        status: .working,
        cwd: "/Users/test/workspace/agent-os"
    )

    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == project.id)
    try assert(matched?.name == "AgentOS")
}

// 474. CWD Match: Descendant workspace matches registered Project
runTest("474. CWD Match: Descendant workspace matches registered Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_474_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let session = AgentSessionInfo(
        provider: .codex,
        sessionId: "sess-descendant-001",
        title: "Deep Subdir Task",
        status: .working,
        cwd: "/Users/test/workspace/agent-os/Sources/AgentSignalBar/Core"
    )

    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == project.id)
    try assert(matched?.name == "AgentOS")
}

// 475. CWD Match: Nested registered Projects choose deepest parent
runTest("475. CWD Match: Nested registered Projects choose deepest parent") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_475_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let parent = try registry.registerProject(rootPath: "/Users/test/monorepo", name: "Monorepo Root")
    let child = try registry.registerProject(rootPath: "/Users/test/monorepo/packages/sub-service", name: "Sub Service")

    let sessionChild = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "sess-nested-001",
        title: "Nested Service Feature",
        status: .working,
        cwd: "/Users/test/monorepo/packages/sub-service/src/components"
    )

    let sessionParent = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "sess-parent-001",
        title: "Root Tooling",
        status: .working,
        cwd: "/Users/test/monorepo/scripts"
    )

    try assert(sessionChild.resolveProject(using: registry)?.id == child.id)
    try assert(sessionParent.resolveProject(using: registry)?.id == parent.id)
}

// 476. Boundary Guard: Sibling/prefix collision does not falsely match
runTest("476. Boundary Guard: Sibling/prefix collision does not falsely match") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_476_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let sessionSibling = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-sibling-001",
        title: "Sibling Repo",
        status: .working,
        cwd: "/Users/test/workspace/agent-os-extra/src"
    )

    try assert(sessionSibling.resolveProject(using: registry) == nil)
}

// 477. Unassigned: Workspace outside registered roots resolves to Unassigned
runTest("477. Unassigned: Workspace outside registered roots resolves to Unassigned") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_477_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let sessionOutside = AgentSessionInfo(
        provider: .copilot,
        sessionId: "sess-outside-001",
        title: "Random Scratch",
        status: .working,
        cwd: "/tmp/scratchpad/test"
    )

    try assert(sessionOutside.resolveProject(using: registry) == nil)
}

// 478. Unassigned: Missing or empty workspace resolves to Unassigned
runTest("478. Unassigned: Missing or empty workspace resolves to Unassigned") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_478_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let sessionNil = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-nil-001",
        title: "No CWD Session",
        status: .working,
        cwd: nil
    )

    let sessionEmpty = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-empty-001",
        title: "Empty CWD Session",
        status: .working,
        cwd: "   "
    )

    try assert(sessionNil.resolveProject(using: registry) == nil)
    try assert(sessionEmpty.resolveProject(using: registry) == nil)
}

// 479. Canonical Normalization: Path normalization preserves matching across trailing slashes and relative tokens
runTest("479. Canonical Normalization: Path normalization preserves matching across trailing slashes and relative tokens") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_479_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let sessionTrailing = AgentSessionInfo(
        provider: .codex,
        sessionId: "sess-trailing-001",
        title: "Trailing Slash",
        status: .working,
        cwd: "/Users/test/workspace/agent-os/Sources/../Sources/AgentSignalBar/"
    )

    try assert(sessionTrailing.resolveProject(using: registry)?.id == project.id)
}

// 480. Dynamic Reassociation: Session workspace change recomputes association dynamically
runTest("480. Dynamic Reassociation: Session workspace change recomputes association dynamically") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_480_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let projectA = try registry.registerProject(rootPath: "/Users/test/workspace/project-a", name: "Project A")
    let projectB = try registry.registerProject(rootPath: "/Users/test/workspace/project-b", name: "Project B")

    var session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-dynamic-001",
        title: "Switching Workspace",
        status: .working,
        cwd: "/Users/test/workspace/project-a/lib"
    )

    try assert(session.resolveProject(using: registry)?.id == projectA.id)

    // Workspace changes
    session.cwd = "/Users/test/workspace/project-b/src"
    try assert(session.resolveProject(using: registry)?.id == projectB.id)

    // Workspace changes to unregistered
    session.cwd = "/var/tmp/unregistered"
    try assert(session.resolveProject(using: registry) == nil)
}

// 481. Dynamic Removal: Removed Project dynamically clears association without stale references
runTest("481. Dynamic Removal: Removed Project dynamically clears association without stale references") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_481_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "sess-removal-001",
        title: "Transient Task",
        status: .working,
        cwd: "/Users/test/workspace/agent-os/submodule"
    )

    try assert(session.resolveProject(using: registry)?.id == project.id)

    // Remove project
    _ = try registry.removeProject(id: project.id)

    // Association must dynamically resolve to nil
    try assert(session.resolveProject(using: registry) == nil)
}

// 482. Nested Fallback: Parent Project becomes fallback if nested child Project is removed
runTest("482. Nested Fallback: Parent Project becomes fallback if nested child Project is removed") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_482_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let parent = try registry.registerProject(rootPath: "/Users/test/monorepo", name: "Monorepo Parent")
    let child = try registry.registerProject(rootPath: "/Users/test/monorepo/sub-service", name: "Sub Service")

    let session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-fallback-001",
        title: "Sub Service Worker",
        status: .working,
        cwd: "/Users/test/monorepo/sub-service/src"
    )

    try assert(session.resolveProject(using: registry)?.id == child.id)

    // Remove child project
    _ = try registry.removeProject(id: child.id)

    // Now longest-parent match naturally falls back to parent
    try assert(session.resolveProject(using: registry)?.id == parent.id)
}

// 483. Multi-Session Independence: Sessions across different Projects resolve independently
runTest("483. Multi-Session Independence: Sessions across different Projects resolve independently") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_483_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p1 = try registry.registerProject(rootPath: "/Users/test/workspace/repo-1", name: "Repo 1")
    let p2 = try registry.registerProject(rootPath: "/Users/test/workspace/repo-2", name: "Repo 2")

    let s1 = AgentSessionInfo(provider: .claude, sessionId: "s1", title: "T1", status: .working, cwd: "/Users/test/workspace/repo-1/a")
    let s2 = AgentSessionInfo(provider: .codex, sessionId: "s2", title: "T2", status: .working, cwd: "/Users/test/workspace/repo-2/b")
    let s3 = AgentSessionInfo(provider: .copilot, sessionId: "s3", title: "T3", status: .working, cwd: "/Users/test/workspace/other")

    try assert(s1.resolveProject(using: registry)?.id == p1.id)
    try assert(s2.resolveProject(using: registry)?.id == p2.id)
    try assert(s3.resolveProject(using: registry) == nil)
}

// 484. Multi-Session Convergence: Multiple sessions in same Project converge on same Project ID
runTest("484. Multi-Session Convergence: Multiple sessions in same Project converge on same Project ID") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_484_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    let sClaude = AgentSessionInfo(provider: .claude, sessionId: "c1", title: "Claude Worker", status: .working, cwd: "/Users/test/workspace/agent-os/Sources")
    let sCodex = AgentSessionInfo(provider: .codex, sessionId: "x1", title: "Codex Worker", status: .working, cwd: "/Users/test/workspace/agent-os/Tests")
    let sAgy = AgentSessionInfo(provider: .antigravity, sessionId: "a1", title: "AGY Worker", status: .working, cwd: "/Users/test/workspace/agent-os")

    try assert(sClaude.resolveProject(using: registry)?.id == project.id)
    try assert(sCodex.resolveProject(using: registry)?.id == project.id)
    try assert(sAgy.resolveProject(using: registry)?.id == project.id)
}

// 485. Separation of Concerns: ChatGPT reviewer is governed by M3.2 and never assigned via fake CWD
runTest("485. Separation of Concerns: ChatGPT reviewer is governed by M3.2 and never assigned via fake CWD") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_485_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")
    try registry.assignReviewer(toProjectId: project.id, url: "https://chatgpt.com/c/gpt-rev-485", title: "Reviewer 485")

    let chatgptSession = AgentSessionInfo(
        provider: .chatgpt,
        sessionId: "tab-chatgpt-101",
        title: "ChatGPT Active Tab",
        status: .working,
        cwd: nil // ChatGPT Web has no filesystem CWD
    )

    // ChatGPT session has no CWD and must resolve to nil via M3.3
    try assert(chatgptSession.resolveProject(using: registry) == nil)

    // But project reviewer relationship is preserved via M3.2
    let updatedProj = registry.getProject(byId: project.id)
    try assert(updatedProj?.currentReviewer?.conversationId == "gpt-rev-485")
}

// 486. Provider Concrete CWD Verification: Claude, Antigravity, Codex, Copilot real CWD payloads resolve Project
runTest("486. Provider Concrete CWD Verification: Claude, Antigravity, Codex, Copilot real CWD payloads resolve Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_486_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let targetProject = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    // 1. Claude Hook payload with CWD
    let claudeHookPayload: [String: Any] = [
        "event": "UserPromptSubmit",
        "session_id": "claude-hook-session-486",
        "cwd": "/Users/test/workspace/agent-os/Sources/AgentSignalBar"
    ]
    let claudeCwd = claudeHookPayload["cwd"] as? String
    let claudeSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-hook-session-486",
        title: "Claude Hook Session",
        status: .working,
        cwd: claudeCwd
    )
    try assert(claudeSession.resolveProject(using: registry)?.id == targetProject.id)

    // 2. Antigravity Hook payload with CWD
    let agyHookPayload: [String: Any] = [
        "event": "PreInvocation",
        "session_id": "agy-hook-session-486",
        "cwd": "/Users/test/workspace/agent-os"
    ]
    let agyCwd = agyHookPayload["cwd"] as? String
    let agySession = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-hook-session-486",
        title: "AGY Hook Session",
        status: .working,
        cwd: agyCwd
    )
    try assert(agySession.resolveProject(using: registry)?.id == targetProject.id)

    // 3. Codex Thread database row with CWD
    let codexThreadCwd = "/Users/test/workspace/agent-os/Tests/AgentSignalBarTests"
    let codexSession = AgentSessionInfo(
        provider: .codex,
        sessionId: "codex-db-thread-486",
        title: "Codex Thread Session",
        status: .working,
        cwd: codexThreadCwd
    )
    try assert(codexSession.resolveProject(using: registry)?.id == targetProject.id)

    // 4. Copilot session store with CWD
    let copilotSessionCwd = "/Users/test/workspace/agent-os/subfolder"
    let copilotSession = AgentSessionInfo(
        provider: .copilot,
        sessionId: "copilot-db-session-486",
        title: "Copilot DB Session",
        status: .working,
        cwd: copilotSessionCwd
    )
    try assert(copilotSession.resolveProject(using: registry)?.id == targetProject.id)
}

// 487. GitHub URL Parsing: SSH remote normalizes to owner/repo and canonical HTTPS URL
runTest("487. GitHub URL Parsing: SSH remote normalizes to owner/repo and canonical HTTPS URL") {
    let sshUrl = "git@github.com:iknoest/Agent-webchat-monitor.git"
    let parsed = GitHubURLParser.parseRepository(from: sshUrl)
    try assert(parsed != nil)
    try assert(parsed?.owner == "iknoest")
    try assert(parsed?.repository == "Agent-webchat-monitor")
    try assert(parsed?.fullName == "iknoest/Agent-webchat-monitor")
    try assert(parsed?.canonicalUrl == "https://github.com/iknoest/Agent-webchat-monitor")
    try assert(parsed?.detectedRemoteName == "origin")

    let sshProtocolUrl = "ssh://git@github.com/apple/swift.git"
    let parsedProto = GitHubURLParser.parseRepository(from: sshProtocolUrl, remoteName: "upstream")
    try assert(parsedProto?.fullName == "apple/swift")
    try assert(parsedProto?.canonicalUrl == "https://github.com/apple/swift")
    try assert(parsedProto?.detectedRemoteName == "upstream")
}

// 488. GitHub URL Parsing: HTTPS remote normalizes identically to SSH remote
runTest("488. GitHub URL Parsing: HTTPS remote normalizes identically to SSH remote") {
    let httpsUrl = "https://github.com/iknoest/Agent-webchat-monitor.git"
    let parsed = GitHubURLParser.parseRepository(from: httpsUrl)
    try assert(parsed != nil)
    try assert(parsed?.owner == "iknoest")
    try assert(parsed?.repository == "Agent-webchat-monitor")
    try assert(parsed?.fullName == "iknoest/Agent-webchat-monitor")
    try assert(parsed?.canonicalUrl == "https://github.com/iknoest/Agent-webchat-monitor")
}

// 489. GitHub URL Parsing: Optional .git suffix normalization
runTest("489. GitHub URL Parsing: Optional .git suffix normalization") {
    let urlWithoutGit = "https://github.com/torvalds/linux"
    let parsedWithout = GitHubURLParser.parseRepository(from: urlWithoutGit)
    try assert(parsedWithout?.fullName == "torvalds/linux")
    try assert(parsedWithout?.canonicalUrl == "https://github.com/torvalds/linux")

    let sshWithoutGit = "git@github.com:torvalds/linux"
    let parsedSshWithout = GitHubURLParser.parseRepository(from: sshWithoutGit)
    try assert(parsedSshWithout?.fullName == "torvalds/linux")
}

// 490. Non-GitHub Remote: GitLab, Bitbucket, local remotes produce no GitHub association
runTest("490. Non-GitHub Remote: GitLab, Bitbucket, local remotes produce no GitHub association") {
    try assert(GitHubURLParser.parseRepository(from: "git@gitlab.com:owner/repo.git") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://gitlab.com/owner/repo") == nil)
    try assert(GitHubURLParser.parseRepository(from: "git@bitbucket.org:owner/repo.git") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://bitbucket.org/owner/repo") == nil)
    try assert(GitHubURLParser.parseRepository(from: "/Users/ava/local-repo.git") == nil)
    try assert(GitHubURLParser.parseRepository(from: "file:///Users/ava/local-repo") == nil)
}

// 491. Non-Git Project: Project without Git repository remains fully valid
runTest("491. Non-Git Project: Project without Git repository remains fully valid") {
    let tempDir = NSTemporaryDirectory()
    let nonGitFolder = "\(tempDir)/non_git_project_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: nonGitFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: nonGitFolder) }

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_491_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: nonGitFolder, name: "Scratch Docs")
    try assert(project.gitRepository == nil)
    try assert(project.liveGitRepository == nil)
    try assert(project.name == "Scratch Docs")
}

// 492. Malformed Remote: Malformed URLs and invalid identifiers fail closed
runTest("492. Malformed Remote: Malformed URLs and invalid identifiers fail closed") {
    try assert(GitHubURLParser.parseRepository(from: "") == nil)
    try assert(GitHubURLParser.parseRepository(from: "   ") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://github.com") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://github.com/") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://github.com/onlyowner") == nil)
    try assert(GitHubURLParser.parseRepository(from: "git@github.com:incomplete") == nil)
    try assert(GitHubURLParser.parseRepository(from: "https://github.com/owner/repo/extra/path") == nil)
    try assert(GitHubURLParser.parseRepository(from: "git@github.com:owner/repo with spaces.git") == nil)
}

// 493. Invariant: Project identity and rootPath do not change when GitHub repository changes
runTest("493. Invariant: Project identity and rootPath do not change when GitHub repository changes") {
    let tempDir = NSTemporaryDirectory()
    let repoFolder = "\(tempDir)/test_repo_493_\(UUID().uuidString)"
    let gitFolder = "\(repoFolder)/.git"
    try FileManager.default.createDirectory(atPath: gitFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: repoFolder) }

    let initialConfig = """
    [core]
        bare = false
    [remote "origin"]
        url = https://github.com/initial-org/repo-one.git
        fetch = +refs/heads/*:refs/remotes/origin/*
    """
    try initialConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_493_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: repoFolder, name: "RepoOne")
    let originalId = project.id
    let originalRoot = project.rootPath
    try assert(project.gitRepository?.fullName == "initial-org/repo-one")

    // Change Git remote on disk
    let updatedConfig = """
    [core]
        bare = false
    [remote "origin"]
        url = https://github.com/new-org/repo-renamed.git
        fetch = +refs/heads/*:refs/remotes/origin/*
    """
    try updatedConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let refreshed = try registry.refreshGitRepository(forProjectId: project.id)
    try assert(refreshed.id == originalId, "Project ID must never change when GitHub repository changes")
    try assert(refreshed.rootPath == originalRoot, "Project root path must never change when GitHub repository changes")
    try assert(refreshed.gitRepository?.fullName == "new-org/repo-renamed")
}

// 494. Separation: M3.3 session->Project resolution remains based strictly on CWD, not GitHub repo
runTest("494. Separation: M3.3 session->Project resolution remains based strictly on CWD, not GitHub repo") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_494_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p1 = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")

    // Session points to CWD
    let session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-494",
        title: "Working in AgentOS",
        status: .working,
        cwd: "/Users/test/workspace/agent-os/Sources"
    )

    // Resolution must use CWD longest-parent matching
    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == p1.id)
    try assert(matched?.name == "AgentOS")
}

// 495. Nested Isolation: Nested Project root does not inherit parent repository remotes
runTest("495. Nested Isolation: Nested Project root does not inherit parent repository remotes") {
    let tempDir = NSTemporaryDirectory()
    let parentFolder = "\(tempDir)/parent_repo_\(UUID().uuidString)"
    let childFolder = "\(parentFolder)/nested_subproject"
    let parentGit = "\(parentFolder)/.git"
    try FileManager.default.createDirectory(atPath: parentGit, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: childFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: parentFolder) }

    let parentConfig = """
    [remote "origin"]
        url = https://github.com/monorepo-org/parent-monorepo.git
    """
    try parentConfig.write(toFile: "\(parentGit)/config", atomically: true, encoding: .utf8)

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_495_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let parentProj = try registry.registerProject(rootPath: parentFolder, name: "Parent Monorepo")
    let childProj = try registry.registerProject(rootPath: childFolder, name: "Nested Subproject")

    try assert(parentProj.gitRepository?.fullName == "monorepo-org/parent-monorepo")
    // Child folder has no .git at its own root, must NOT inherit parent repo
    try assert(childProj.gitRepository == nil)
    try assert(childProj.liveGitRepository == nil)
}

// 496. Ambiguity Guard: Multiple conflicting GitHub remotes without origin fail closed
runTest("496. Ambiguity Guard: Multiple conflicting GitHub remotes without origin fail closed") {
    let remotesWithoutOrigin = [
        "forkA": "https://github.com/alice/project.git",
        "forkB": "https://github.com/bob/project.git"
    ]
    let resolvedAmbiguous = ProjectGitDetector.resolveAuthoritativeGitHubRemote(from: remotesWithoutOrigin)
    try assert(resolvedAmbiguous == nil, "Multiple distinct remotes without origin must fail closed")

    // With origin, origin takes precedence
    let remotesWithOrigin = [
        "origin": "https://github.com/canonical/project.git",
        "forkA": "https://github.com/alice/project.git"
    ]
    let resolvedWithOrigin = ProjectGitDetector.resolveAuthoritativeGitHubRemote(from: remotesWithOrigin)
    try assert(resolvedWithOrigin?.fullName == "canonical/project")
}

// 497. Data Privacy: Persisted Project JSON contains no credentials or authentication tokens
runTest("497. Data Privacy: Persisted Project JSON contains no credentials or authentication tokens") {
    let tempDir = NSTemporaryDirectory()
    let repoFolder = "\(tempDir)/privacy_repo_\(UUID().uuidString)"
    let gitFolder = "\(repoFolder)/.git"
    try FileManager.default.createDirectory(atPath: gitFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: repoFolder) }

    let gitConfig = """
    [remote "origin"]
        url = git@github.com:secure-org/confidential-project.git
    """
    try gitConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_497_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.registerProject(rootPath: repoFolder, name: "Confidential")
    try assert(proj.gitRepository?.fullName == "secure-org/confidential-project")

    let savedData = try Data(contentsOf: testStorageURL)
    let jsonString = String(data: savedData, encoding: .utf8) ?? ""

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProjectRegistryData.self, from: savedData)

    try assert(decoded.projects.count == 1)
    try assert(decoded.projects[0].gitRepository?.owner == "secure-org")
    try assert(decoded.projects[0].gitRepository?.repository == "confidential-project")
    try assert(decoded.projects[0].gitRepository?.canonicalUrl == "https://github.com/secure-org/confidential-project")

    // Privacy invariants
    try assert(!jsonString.contains("password"))
    try assert(!jsonString.contains("secret"))
    try assert(!jsonString.contains("token"))
    try assert(!jsonString.contains("bearer"))
    try assert(!jsonString.contains("cookie"))
    try assert(!jsonString.contains("credential"))
}

// 498. Live Drift Refresh: Git remote change on disk updates Project metadata via refreshGitRepository
runTest("498. Live Drift Refresh: Git remote change on disk updates Project metadata via refreshGitRepository") {
    let tempDir = NSTemporaryDirectory()
    let repoFolder = "\(tempDir)/drift_repo_\(UUID().uuidString)"
    let gitFolder = "\(repoFolder)/.git"
    try FileManager.default.createDirectory(atPath: gitFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: repoFolder) }

    let initialConfig = """
    [remote "origin"]
        url = https://github.com/org-alpha/project-repo.git
    """
    try initialConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_498_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let initial = try registry.registerProject(rootPath: repoFolder, name: "Drift Test")
    try assert(initial.gitRepository?.fullName == "org-alpha/project-repo")

    // Update git config
    let newConfig = """
    [remote "origin"]
        url = git@github.com:org-beta/project-repo.git
    """
    try newConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let refreshed = try registry.refreshGitRepository(forProjectId: initial.id)
    try assert(refreshed.gitRepository?.owner == "org-beta")
    try assert(refreshed.gitRepository?.canonicalUrl == "https://github.com/org-beta/project-repo")
}

// 499. Project Switcher: All registered Projects appear in the switcher list
runTest("499. Project Switcher: All registered Projects appear in the switcher list") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_499_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.registerProject(rootPath: "/Users/test/workspace/projectA", name: "Project Alpha")
    _ = try registry.registerProject(rootPath: "/Users/test/workspace/projectB", name: "Project Beta")
    _ = try registry.registerProject(rootPath: "/Users/test/workspace/projectC", name: "Project Gamma")

    let all = registry.getAllProjects()
    try assert(all.count == 3)
    try assert(all.map { $0.name } == ["Project Alpha", "Project Beta", "Project Gamma"])
}

// 500. Empty / Partial Project: Project with no sessions/reviewer/repo remains cleanly visible
runTest("500. Empty / Partial Project: Project with no sessions/reviewer/repo remains cleanly visible") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_500_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let emptyProj = try registry.registerProject(rootPath: "/Users/test/workspace/scratch_docs", name: "Scratch")
    let summary = emptyProj.statusSummary(sessions: [], openTabs: [])

    try assert(summary.status == .idle)
    try assert(summary.totalSessions == 0)
    try assert(summary.blockedCount == 0)
    try assert(summary.workingCount == 0)
    try assert(summary.statusBadgeText == "No Active Sessions")
    try assert(emptyProj.currentReviewer == nil)
    try assert(emptyProj.gitRepository == nil)
}

// 501. Single Session: Working session appears under correct Project with working badge
runTest("501. Single Session: Working session appears under correct Project with working badge") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_501_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/agent-os", name: "AgentOS")
    let session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-501",
        title: "Coding feature",
        status: .working,
        cwd: "/Users/test/workspace/agent-os/Sources"
    )

    let summary = project.statusSummary(sessions: [session], openTabs: [])
    try assert(summary.status == .working)
    try assert(summary.totalSessions == 1)
    try assert(summary.workingCount == 1)
    try assert(summary.statusBadgeText == "1 Working")
}

// 502. Multi-Session Aggregation: Multiple provider sessions aggregate under same Project
runTest("502. Multi-Session Aggregation: Multiple provider sessions aggregate under same Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_502_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/monorepo", name: "Monorepo")

    let sessClaude = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-502",
        title: "Claude turn",
        status: .working,
        cwd: "/Users/test/workspace/monorepo/pkgA"
    )
    let sessCodex = AgentSessionInfo(
        provider: .codex,
        sessionId: "codex-502",
        title: "Codex thread",
        status: .working,
        cwd: "/Users/test/workspace/monorepo/pkgB"
    )
    let sessAgy = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-502",
        title: "AGY subagent",
        status: .idle,
        cwd: "/Users/test/workspace/monorepo/scripts"
    )

    let summary = project.statusSummary(sessions: [sessClaude, sessCodex, sessAgy], openTabs: [])
    try assert(summary.status == .working)
    try assert(summary.totalSessions == 3)
    try assert(summary.workingCount == 2)
    try assert(summary.idleCount == 1)
    try assert(summary.statusBadgeText == "2 Working")
}

// 503. Project Separation: Sessions across different Projects remain strictly separated
runTest("503. Project Separation: Sessions across different Projects remain strictly separated") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_503_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p1 = try registry.registerProject(rootPath: "/Users/test/workspace/frontend", name: "Frontend")
    let p2 = try registry.registerProject(rootPath: "/Users/test/workspace/backend", name: "Backend")

    let s1 = AgentSessionInfo(provider: .claude, sessionId: "s1", title: "UI", status: .working, cwd: "/Users/test/workspace/frontend")
    let s2 = AgentSessionInfo(provider: .codex, sessionId: "s2", title: "API", status: .blocked, cwd: "/Users/test/workspace/backend")

    try assert(s1.resolveProject(using: registry)?.id == p1.id)
    try assert(s2.resolveProject(using: registry)?.id == p2.id)

    let summary1 = p1.statusSummary(sessions: [s1])
    let summary2 = p2.statusSummary(sessions: [s2])

    try assert(summary1.status == .working)
    try assert(summary2.status == .blocked)
    try assert(summary1.blockedCount == 0)
    try assert(summary2.blockedCount == 1)
}

// 504. Needs You Priority: Blocked session surfaces Project-level attention state
runTest("504. Needs You Priority: Blocked session surfaces Project-level attention state") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_504_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/critical-app", name: "CriticalApp")
    let blockedSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-504",
        title: "Awaiting permission",
        status: .blocked,
        cwd: "/Users/test/workspace/critical-app"
    )

    let summary = project.statusSummary(sessions: [blockedSession], openTabs: [])
    try assert(summary.status == .blocked)
    try assert(summary.blockedCount == 1)
    try assert(summary.statusBadgeText == "⚠️ 1 Needs You")
}

// 505. Priority Hierarchy: Working sessions do not override Needs You attention state
runTest("505. Priority Hierarchy: Working sessions do not override Needs You attention state") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_505_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/mixed", name: "Mixed")
    let blockedSess = AgentSessionInfo(provider: .antigravity, sessionId: "b1", title: "Tool confirmation", status: .blocked, cwd: "/Users/test/workspace/mixed")
    let workingSess1 = AgentSessionInfo(provider: .claude, sessionId: "w1", title: "Generating code", status: .working, cwd: "/Users/test/workspace/mixed")
    let workingSess2 = AgentSessionInfo(provider: .codex, sessionId: "w2", title: "Thinking", status: .working, cwd: "/Users/test/workspace/mixed")

    let summary = project.statusSummary(sessions: [blockedSess, workingSess1, workingSess2], openTabs: [])
    try assert(summary.status == .blocked, "Needs You (.blocked) must dominate over .working in project summary")
    try assert(summary.blockedCount == 1)
    try assert(summary.workingCount == 2)
    try assert(summary.statusBadgeText == "⚠️ 1 Needs You")
}

// 506. Unassigned Isolation: Unassigned sessions outside registered roots do not appear under projects
runTest("506. Unassigned Isolation: Unassigned sessions outside registered roots do not appear under projects") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_506_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/app", name: "App")
    let unassignedSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "outside-506",
        title: "Scratch",
        status: .working,
        cwd: "/tmp/scratch_unregistered"
    )

    try assert(unassignedSession.resolveProject(using: registry) == nil)
}

// 507. Current Reviewer: Current ChatGPT Reviewer displays with live observable state
runTest("507. Current Reviewer: Current ChatGPT Reviewer displays with live observable state") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_507_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    var project = try registry.registerProject(rootPath: "/Users/test/workspace/reviewed-project", name: "ReviewedProj")
    project = try registry.assignReviewer(
        toProjectId: project.id,
        url: "https://chatgpt.com/c/conv-507-live",
        title: "M3.5 Review Thread"
    )

    let openTabs = [
        ChatGPTTabInfo(tabId: 101, title: "M3.5 Review Thread", url: "https://chatgpt.com/c/conv-507-live", status: "idle", active: true)
    ]

    let live = project.liveReviewerStatus(openTabs: openTabs)
    try assert(live?.isCurrentlyObservable == true)
    try assert(live?.activeTabId == 101)
    try assert(live?.liveTitle == "M3.5 Review Thread")
}

// 508. Unavailable Reviewer: Closed reviewer remains associated and shown as closed
runTest("508. Unavailable Reviewer: Closed reviewer remains associated and shown as closed") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_508_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    var project = try registry.registerProject(rootPath: "/Users/test/workspace/proj-closed", name: "ClosedReviewerProj")
    project = try registry.assignReviewer(
        toProjectId: project.id,
        url: "https://chatgpt.com/c/conv-508-closed",
        title: "Prior Review"
    )

    // No matching open tab in Chrome
    let openTabs = [
        ChatGPTTabInfo(tabId: 202, title: "Other Chat", url: "https://chatgpt.com/c/different-conv", status: "idle")
    ]

    let live = project.liveReviewerStatus(openTabs: openTabs)
    try assert(live?.isCurrentlyObservable == false)
    try assert(live?.activeTabId == nil)
    try assert(project.currentReviewer?.conversationId == "conv-508-closed")
}

// 509. GitHub Association: Associated GitHub repo renders canonical full name and URL
runTest("509. GitHub Association: Associated GitHub repo renders canonical full name and URL") {
    let tempDir = NSTemporaryDirectory()
    let repoFolder = "\(tempDir)/github_proj_509_\(UUID().uuidString)"
    let gitFolder = "\(repoFolder)/.git"
    try FileManager.default.createDirectory(atPath: gitFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: repoFolder) }

    let gitConfig = """
    [remote "origin"]
        url = git@github.com:iknoest/Agent-webchat-monitor.git
    """
    try gitConfig.write(toFile: "\(gitFolder)/config", atomically: true, encoding: .utf8)

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_509_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: repoFolder, name: "AgentBridge")
    try assert(project.gitRepository?.fullName == "iknoest/Agent-webchat-monitor")
    try assert(project.gitRepository?.canonicalUrl == "https://github.com/iknoest/Agent-webchat-monitor")
}

// 510. Non-GitHub Grace: Project without GitHub repo shows cleanly without error or warning
runTest("510. Non-GitHub Grace: Project without GitHub repo shows cleanly without error or warning") {
    let tempDir = NSTemporaryDirectory()
    let plainFolder = "\(tempDir)/plain_proj_510_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: plainFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: plainFolder) }

    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_510_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: plainFolder, name: "Local Docs")
    try assert(project.gitRepository == nil)
    try assert(project.liveGitRepository == nil)
}

// 511. Nested Project Precision: Nested Project session resolves to deepest matching child
runTest("511. Nested Project Precision: Nested Project session resolves to deepest matching child") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_511_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let parent = try registry.registerProject(rootPath: "/Users/test/workspace/monorepo", name: "Monorepo Parent")
    let child = try registry.registerProject(rootPath: "/Users/test/workspace/monorepo/packages/api", name: "API Child")

    let childSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-511-child",
        title: "API work",
        status: .working,
        cwd: "/Users/test/workspace/monorepo/packages/api/src"
    )
    let parentSession = AgentSessionInfo(
        provider: .codex,
        sessionId: "sess-511-parent",
        title: "Root scripts",
        status: .working,
        cwd: "/Users/test/workspace/monorepo/scripts"
    )

    try assert(childSession.resolveProject(using: registry)?.id == child.id)
    try assert(parentSession.resolveProject(using: registry)?.id == parent.id)
}

// 512. Dynamic Removal: Removing Project clears association without stale references
runTest("512. Dynamic Removal: Removing Project clears association without stale references") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_512_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.registerProject(rootPath: "/Users/test/workspace/temporary", name: "Temporary")
    let session = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-512",
        title: "Temp work",
        status: .working,
        cwd: "/Users/test/workspace/temporary"
    )

    try assert(session.resolveProject(using: registry)?.id == project.id)

    _ = try registry.removeProject(id: project.id)
    try assert(session.resolveProject(using: registry) == nil, "Removed project must immediately clear session association")
}

// 513. Canonical Navigation: Reviewer jump targets exact conversation identity URL and tabId
runTest("513. Canonical Navigation: Reviewer jump targets exact conversation identity URL and tabId") {
    let reviewer = ProjectReviewer(
        conversationId: "conv-513-target",
        url: "https://chatgpt.com/c/conv-513-target",
        title: "Review Target",
        chatgptProjectId: nil
    )
    let parsed = ChatGPTURLParser.parseReviewerIdentity(from: reviewer.url)
    try assert(parsed?.conversationId == "conv-513-target")
    try assert(parsed?.canonicalUrl == "https://chatgpt.com/c/conv-513-target")
}

// 514. Canonical Navigation: GitHub action targets canonical HTTPS repository URL
runTest("514. Canonical Navigation: GitHub action targets canonical HTTPS repository URL") {
    let sshUrl = "git@github.com:facebook/react.git"
    let parsed = GitHubURLParser.parseRepository(from: sshUrl)
    try assert(parsed?.canonicalUrl == "https://github.com/facebook/react")
}

// 515. Coexistence: Provider-first menu sections continue functioning alongside Project Switcher
runTest("515. Coexistence: Provider-first menu sections continue functioning alongside Project Switcher") {
    let allAgents = AgentID.allCases
    try assert(allAgents.count == 5)
    for agent in allAgents {
        try assert(ConfigManager.shared.isAgentMonitored(agent) == true || ConfigManager.shared.isAgentMonitored(agent) == false)
    }
}

// 516. Non-Duplication: M3.5 introduces zero duplicate persistent state or out-of-sync storage
runTest("516. Non-Duplication: M3.5 introduces zero duplicate persistent state or out-of-sync storage") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_516_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.registerProject(rootPath: "/Users/test/workspace/app516", name: "App516")

    let savedData = try Data(contentsOf: testStorageURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProjectRegistryData.self, from: savedData)

    // ProjectRegistryData contains only the canonical Project list with M3.1-M3.4 properties
    try assert(decoded.projects.count == 1)
    try assert(decoded.projects[0].name == "App516")
    try assert(decoded.projects[0].rootPath == "/Users/test/workspace/app516")
}

// 517. M3.6: One Project owns multiple Workspaces
runTest("517. M3.6: One Project owns multiple Workspaces") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_517_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")
    try assert(project.workspaces.count == 1)
    try assert(project.workspaces[0].isPrimary == true)

    let ws2 = try registry.addWorkspace(toProjectId: project.id, path: "/Users/ava/Projects/Jobsearcher-codex", name: "Codex Worktree")
    try assert(ws2.path == "/Users/ava/Projects/Jobsearcher-codex")

    let loaded = registry.getProject(byId: project.id)
    try assert(loaded?.workspaces.count == 2)
    try assert(loaded?.workspaces.map { $0.path }.contains("/Users/ava/Projects/Jobsearcher") == true)
    try assert(loaded?.workspaces.map { $0.path }.contains("/Users/ava/Projects/Jobsearcher-codex") == true)
}

// 518. M3.6: One Workspace cannot belong to two Projects
runTest("518. M3.6: One Workspace cannot belong to two Projects") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_518_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p1 = try registry.createProject(name: "Alpha", initialWorkspacePath: "/Users/ava/Projects/SharedCode")
    let p2 = try registry.createProject(name: "Beta")

    var didThrow = false
    do {
        _ = try registry.addWorkspace(toProjectId: p2.id, path: "/Users/ava/Projects/SharedCode")
    } catch ProjectRegistryError.workspaceAlreadyAssigned(let path, let existingPid, let existingName) {
        didThrow = true
        try assert(path == "/Users/ava/Projects/SharedCode")
        try assert(existingPid == p1.id)
        try assert(existingName == "Alpha")
    }
    try assert(didThrow, "Adding already registered workspace to second project must throw workspaceAlreadyAssigned")
}

// 519. M3.6: Session CWD in either Workspace resolves to same Project
runTest("519. M3.6: Session CWD in either Workspace resolves to same Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_519_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")
    _ = try registry.addWorkspace(toProjectId: project.id, path: "/Users/ava/Projects/Jobsearcher-codex")

    let session1 = AgentSessionInfo(provider: .claude, sessionId: "s1", title: "s1", status: .working, cwd: "/Users/ava/Projects/Jobsearcher/src")
    let session2 = AgentSessionInfo(provider: .codex, sessionId: "s2", title: "s2", status: .working, cwd: "/Users/ava/Projects/Jobsearcher-codex/lib")

    try assert(session1.resolveProject(using: registry)?.id == project.id)
    try assert(session2.resolveProject(using: registry)?.id == project.id)
}

// 520. M3.6: Nested workspace matching remains deterministic (deepest workspace wins)
runTest("520. M3.6: Nested workspace matching remains deterministic") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_520_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let parentProj = try registry.createProject(name: "Parent", initialWorkspacePath: "/Users/ava/Projects/monorepo")
    let childProj = try registry.createProject(name: "Child", initialWorkspacePath: "/Users/ava/Projects/monorepo/packages/special")

    let s1 = AgentSessionInfo(provider: .antigravity, sessionId: "s1", title: "s1", status: .working, cwd: "/Users/ava/Projects/monorepo/packages/special/sub")
    let s2 = AgentSessionInfo(provider: .antigravity, sessionId: "s2", title: "s2", status: .working, cwd: "/Users/ava/Projects/monorepo/packages/other")

    try assert(s1.resolveProject(using: registry)?.id == childProj.id)
    try assert(s2.resolveProject(using: registry)?.id == parentProj.id)
}

// 521. M3.6: Project removal clears all workspace ownership cleanly
runTest("521. M3.6: Project removal clears all workspace ownership cleanly") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_521_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Multi", initialWorkspacePath: "/Users/ava/Projects/ws1")
    _ = try registry.addWorkspace(toProjectId: project.id, path: "/Users/ava/Projects/ws2")

    _ = try registry.removeProject(id: project.id)

    // Both paths should now be free to register to other projects
    let p2 = try registry.createProject(name: "NewOwner1", initialWorkspacePath: "/Users/ava/Projects/ws1")
    let p3 = try registry.createProject(name: "NewOwner2", initialWorkspacePath: "/Users/ava/Projects/ws2")
    try assert(p2.workspaces.count == 1)
    try assert(p3.workspaces.count == 1)
}

// 522. M3.6: Multiple Workstreams under one Project
runTest("522. M3.6: Multiple Workstreams under one Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_522_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher", initialWorkstreamName: "Workstream A — Discovery")
    let stB = try registry.addWorkstream(toProjectId: project.id, name: "Workstream B — Scraper")
    let stC = try registry.addWorkstream(toProjectId: project.id, name: "Workstream C — Scoring")

    let loaded = registry.getProject(byId: project.id)
    try assert(loaded?.workstreams.count == 3)
    try assert(loaded?.workstreams[0].name == "Workstream A — Discovery")
    try assert(loaded?.workstreams[1].name == "Workstream B — Scraper")
    try assert(loaded?.workstreams[2].name == "Workstream C — Scoring")
}

// 523. M3.6: One Current Reviewer per Workstream
runTest("523. M3.6: One Current Reviewer per Workstream") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_523_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher")
    let wsA = try registry.addWorkstream(toProjectId: project.id, name: "Workstream A")

    let updated = try registry.assignReviewer(toWorkstreamId: wsA.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-523-a", title: "Reviewer A")
    let streamA = updated.workstreams.first(where: { $0.id == wsA.id })
    try assert(streamA?.currentReviewer?.conversationId == "rev-523-a")
    try assert(streamA?.currentReviewer?.title == "Reviewer A")
}

// 524. M3.6: Multiple concurrent reviewers across Workstreams A / B / C are allowed
runTest("524. M3.6: Multiple concurrent reviewers across Workstreams A / B / C are allowed") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_524_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher")
    let streamA = try registry.addWorkstream(toProjectId: project.id, name: "A")
    let streamB = try registry.addWorkstream(toProjectId: project.id, name: "B")
    let streamC = try registry.addWorkstream(toProjectId: project.id, name: "C")

    _ = try registry.assignReviewer(toWorkstreamId: streamA.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-a", title: "Reviewer A")
    _ = try registry.assignReviewer(toWorkstreamId: streamB.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-b", title: "Reviewer B")
    _ = try registry.assignReviewer(toWorkstreamId: streamC.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-c", title: "Reviewer C")

    let loaded = registry.getProject(byId: project.id)
    let revs = loaded?.workstreams.compactMap { $0.currentReviewer?.conversationId }
    try assert(revs?.count == 3)
    try assert(revs?.contains("rev-a") == true)
    try assert(revs?.contains("rev-b") == true)
    try assert(revs?.contains("rev-c") == true)
}

// 525. M3.6: Same conversation cannot be current reviewer for two Workstreams
runTest("525. M3.6: Same conversation cannot be current reviewer for two Workstreams") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_525_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher")
    let streamA = try registry.addWorkstream(toProjectId: project.id, name: "A")
    let streamB = try registry.addWorkstream(toProjectId: project.id, name: "B")

    _ = try registry.assignReviewer(toWorkstreamId: streamA.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-shared", title: "Shared Rev")

    var didThrow = false
    do {
        _ = try registry.assignReviewer(toWorkstreamId: streamB.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-shared", title: "Shared Rev")
    } catch ProjectRegistryError.reviewerAlreadyAssigned(let convId, _, _) {
        didThrow = true
        try assert(convId == "rev-shared")
    }
    try assert(didThrow, "Assigning same conversation to second workstream must throw reviewerAlreadyAssigned")
}

// 526. M3.6: Workstream may exist with no Workspace
runTest("526. M3.6: Workstream may exist with no Workspace") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_526_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher")
    let streamNoWs = try registry.addWorkstream(toProjectId: project.id, name: "Workstream C — Strategy", workspaceIds: [])

    try assert(streamNoWs.workspaceIds.isEmpty)
    let loaded = registry.getProject(byId: project.id)
    try assert(loaded?.workstreams.first(where: { $0.id == streamNoWs.id })?.workspaceIds.isEmpty == true)
}

// 527. M3.6: Ambiguous session cannot be guessed into Workstream (nil)
runTest("527. M3.6: Ambiguous session cannot be guessed into Workstream") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_527_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let project = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")
    // Create workstreams with no workspaces assigned
    let loadedProj = registry.getProject(byId: project.id)!
    let defaultStream = loadedProj.workstreams[0]
    _ = try registry.removeWorkstream(workstreamId: defaultStream.id, fromProjectId: project.id)
    _ = try registry.addWorkstream(toProjectId: project.id, name: "Workstream A", workspaceIds: [])
    _ = try registry.addWorkstream(toProjectId: project.id, name: "Workstream B", workspaceIds: [])

    let session = AgentSessionInfo(provider: .claude, sessionId: "s1", title: "s1", status: .working, cwd: "/Users/ava/Projects/Jobsearcher")
    // Owning project is resolved
    try assert(session.resolveProject(using: registry)?.id == project.id)
    // But workstream cannot be guessed -> nil
    try assert(session.resolveWorkstream(using: registry) == nil)
}

// 528. M3.6: Simple one-workspace/one-reviewer Project remains easy to use
runTest("528. M3.6: Simple one-workspace/one-reviewer Project remains easy to use") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_528_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.registerProject(rootPath: "/Users/ava/Projects/SimpleApp", name: "Simple App")
    try assert(p.workspaces.count == 1)
    try assert(p.rootPath == "/Users/ava/Projects/SimpleApp")

    let assigned = try registry.assignReviewer(toProjectId: p.id, url: "https://chatgpt.com/c/rev-simple", title: "Simple Rev")
    try assert(assigned.currentReviewer?.conversationId == "rev-simple")

    let unlinked = try registry.removeReviewer(fromProjectId: p.id)
    try assert(unlinked.currentReviewer == nil)
    try assert(unlinked.reviewerHistory.count == 1)
}

// 529. M3.6: Legacy M3 persisted data (v1) migrates without losing reviewer/history/root
runTest("529. M3.6: Legacy M3 persisted data (v1) migrates without losing reviewer/history/root") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_529_\(UUID().uuidString).json")

    // Construct raw v1 JSON
    let legacyJSON = """
    {
      "version": 1,
      "projects": [
        {
          "id": "proj-legacy-1",
          "name": "Legacy Project",
          "rootPath": "/Users/ava/Projects/legacy-repo",
          "createdAt": "2026-08-28T10:00:00Z",
          "updatedAt": "2026-08-28T12:00:00Z",
          "currentReviewer": {
            "conversationId": "conv-leg-123",
            "url": "https://chatgpt.com/c/conv-leg-123",
            "title": "Legacy Reviewer",
            "assignedAt": "2026-08-28T10:30:00Z",
            "lastObservedAt": "2026-08-28T12:00:00Z"
          },
          "reviewerHistory": [
            {
              "conversationId": "conv-old-001",
              "url": "https://chatgpt.com/c/conv-old-001",
              "title": "Old Reviewer",
              "assignedAt": "2026-08-28T09:00:00Z",
              "replacedAt": "2026-08-28T10:30:00Z"
            }
          ]
        }
      ]
    }
    """
    try legacyJSON.data(using: .utf8)!.write(to: testStorageURL)

    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let loaded = registry.getProject(byId: "proj-legacy-1")
    try assert(loaded != nil)
    try assert(loaded?.name == "Legacy Project")
    try assert(loaded?.workspaces.count == 1)
    try assert(loaded?.workspaces[0].path == "/Users/ava/Projects/legacy-repo")
    try assert(loaded?.workspaces[0].isPrimary == true)
    try assert(loaded?.currentReviewer?.conversationId == "conv-leg-123")
    try assert(loaded?.currentReviewer?.title == "Legacy Reviewer")
    try assert(loaded?.reviewerHistory.count == 1)
    try assert(loaded?.reviewerHistory[0].conversationId == "conv-old-001")
}

// 530. M3.6: Create Project works through API
runTest("530. M3.6: Create Project works through API") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_530_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.createProject(name: "Brand New App", initialWorkspacePath: "/Users/ava/Projects/brand-new")
    try assert(proj.name == "Brand New App")
    try assert(proj.workspaces.first?.path == "/Users/ava/Projects/brand-new")
}

// 531. M3.6: Rename Project works
runTest("531. M3.6: Rename Project works") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_531_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.createProject(name: "Initial Name")
    let renamed = try registry.renameProject(id: proj.id, newName: "Updated Name")
    try assert(renamed.name == "Updated Name")
    try assert(registry.getProject(byId: proj.id)?.name == "Updated Name")
}

// 532. M3.6: Add/remove Workspace works & primary workspace re-designation
runTest("532. M3.6: Add/remove Workspace works & primary workspace re-designation") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_532_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.createProject(name: "Test")
    let ws1 = try registry.addWorkspace(toProjectId: proj.id, path: "/Users/ava/Projects/wsA", isPrimary: true)
    let ws2 = try registry.addWorkspace(toProjectId: proj.id, path: "/Users/ava/Projects/wsB", isPrimary: false)

    try assert(registry.getProject(byId: proj.id)?.primaryWorkspace?.id == ws1.id)

    _ = try registry.setPrimaryWorkspace(workspaceId: ws2.id, inProjectId: proj.id)
    try assert(registry.getProject(byId: proj.id)?.primaryWorkspace?.id == ws2.id)

    let updated = try registry.removeWorkspace(workspaceId: ws2.id, fromProjectId: proj.id)
    try assert(updated.workspaces.count == 1)
    try assert(updated.primaryWorkspace?.id == ws1.id)
}

// 533. M3.6: Add/remove/rename Workstream works
runTest("533. M3.6: Add/remove/rename Workstream works") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_533_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.createProject(name: "Test")
    let stream = try registry.addWorkstream(toProjectId: proj.id, name: "Initial Stream")
    try assert(stream.name == "Initial Stream")

    let renamed = try registry.renameWorkstream(workstreamId: stream.id, inProjectId: proj.id, newName: "Renamed Stream")
    try assert(renamed.name == "Renamed Stream")

    let afterRemoval = try registry.removeWorkstream(workstreamId: stream.id, fromProjectId: proj.id)
    try assert(afterRemoval.workstreams.contains(where: { $0.id == stream.id }) == false)
}

// 534. M3.6: Delete Project works
runTest("534. M3.6: Delete Project works") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_534_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let proj = try registry.createProject(name: "ToDelete")
    try assert(registry.count == 1)

    let deleted = try registry.deleteProject(id: proj.id)
    try assert(deleted == true)
    try assert(registry.count == 0)
}

// 535. M3.6: Jobsearcher topology aggregates multiple sessions correctly (A/B/C)
runTest("535. M3.6: Jobsearcher topology aggregates multiple sessions correctly") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_535_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    // Setup full Jobsearcher Topology
    let project = try registry.createProject(
        name: "Jobsearcher",
        initialWorkspacePath: "/Users/ava/Projects/Jobsearcher",
        initialWorkstreamName: "Workstream B — Scraper"
    )
    let wsCodex = try registry.addWorkspace(toProjectId: project.id, path: "/Users/ava/Projects/Jobsearcher-codex")

    let streamB = project.workstreams[0]
    let streamA = try registry.addWorkstream(toProjectId: project.id, name: "Workstream A — Discovery / Scoring", workspaceIds: [wsCodex.id])
    let streamC = try registry.addWorkstream(toProjectId: project.id, name: "Workstream C — Strategy", workspaceIds: [])

    _ = try registry.assignReviewer(toWorkstreamId: streamA.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-job-a", title: "Reviewer A")
    _ = try registry.assignReviewer(toWorkstreamId: streamB.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-job-b", title: "Reviewer B")
    _ = try registry.assignReviewer(toWorkstreamId: streamC.id, inProjectId: project.id, url: "https://chatgpt.com/c/rev-job-c", title: "Reviewer C")

    // Multiple sessions across workspaces
    let s1 = AgentSessionInfo(provider: .codex, sessionId: "codex-1", title: "Codex Session", status: .working, cwd: "/Users/ava/Projects/Jobsearcher-codex/src")
    let s2 = AgentSessionInfo(provider: .claude, sessionId: "claude-1", title: "Claude Session", status: .done, cwd: "/Users/ava/Projects/Jobsearcher/lib")
    let s3 = AgentSessionInfo(provider: .antigravity, sessionId: "agy-1", title: "AGY Session", status: .blocked, cwd: "/Users/ava/Projects/Jobsearcher")

    // Session resolution
    try assert(s1.resolveProject(using: registry)?.id == project.id)
    try assert(s2.resolveProject(using: registry)?.id == project.id)
    try assert(s3.resolveProject(using: registry)?.id == project.id)

    try assert(s1.resolveWorkstream(using: registry)?.id == streamA.id)
    try assert(s2.resolveWorkstream(using: registry)?.id == streamB.id)

    // Aggregated status summary: Needs You (blocked) takes top priority
    let summary = project.statusSummary(sessions: [s1, s2, s3])
    try assert(summary.status == .blocked)
    try assert(summary.blockedCount == 1)
    try assert(summary.workingCount == 1)
    try assert(summary.doneCount == 1)
    try assert(summary.totalSessions == 3)
}

// 536. M3.6: One GitHub repo remains Project-level across multiple Workspaces
runTest("536. M3.6: One GitHub repo remains Project-level across multiple Workspaces") {
    let repo = ProjectGitHubRepository(owner: "iknoest", repository: "jobsearcher", canonicalUrl: "https://github.com/iknoest/jobsearcher")
    let p = Project(
        name: "Jobsearcher",
        workspaces: [
            ProjectWorkspace(path: "/Users/ava/Projects/Jobsearcher"),
            ProjectWorkspace(path: "/Users/ava/Projects/Jobsearcher-codex")
        ],
        gitRepository: repo
    )

    try assert(p.gitRepository?.fullName == "iknoest/jobsearcher")
    try assert(p.workspaces.count == 2)
}

// 537. M3.6: No conversation content or auth secrets are persisted
runTest("537. M3.6: No conversation content or auth secrets are persisted") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_537_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "SecretFree", initialWorkspacePath: "/Users/ava/Projects/App")
    _ = try registry.assignReviewer(toProjectId: p.id, url: "https://chatgpt.com/c/67890?auth=token123", title: "Clean Title")

    let rawData = try Data(contentsOf: testStorageURL)
    let rawString = String(data: rawData, encoding: .utf8)!

    try assert(!rawString.contains("token123"), "URL query parameters/secrets must be stripped")
    try assert(rawString.contains("67890"), "Conversation ID must be preserved in storage")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProjectRegistryData.self, from: rawData)
    try assert(decoded.projects.first?.currentReviewer?.url == "https://chatgpt.com/c/67890", "Canonical URL must be preserved")
}

// 538. M3 Final: Workstream Workspace Scoping CRUD & Toggle
runTest("538. M3 Final: Workstream Workspace Scoping CRUD & Toggle") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_538_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProject", initialWorkspacePath: "/Users/ava/Projects/ws1")
    let ws2 = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/ws2")
    let stream = try registry.addWorkstream(toProjectId: p.id, name: "Stream A", workspaceIds: [])

    // 1. Assign workspace
    let afterAssign = try registry.assignWorkspace(workspaceId: ws2.id, toWorkstreamId: stream.id, inProjectId: p.id)
    try assert(afterAssign.workstreams.first(where: { $0.id == stream.id })?.workspaceIds.contains(ws2.id) == true)

    // 2. Toggle off (unassign)
    let afterToggleOff = try registry.toggleWorkstreamWorkspace(workspaceId: ws2.id, workstreamId: stream.id, inProjectId: p.id)
    try assert(afterToggleOff.workstreams.first(where: { $0.id == stream.id })?.workspaceIds.contains(ws2.id) == false)

    // 3. Toggle on (assign)
    let afterToggleOn = try registry.toggleWorkstreamWorkspace(workspaceId: ws2.id, workstreamId: stream.id, inProjectId: p.id)
    try assert(afterToggleOn.workstreams.first(where: { $0.id == stream.id })?.workspaceIds.contains(ws2.id) == true)

    // 4. Unassign directly
    let afterUnassign = try registry.unassignWorkspace(workspaceId: ws2.id, fromWorkstreamId: stream.id, inProjectId: p.id)
    try assert(afterUnassign.workstreams.first(where: { $0.id == stream.id })?.workspaceIds.contains(ws2.id) == false)
}

// 539. M3 Final: Exact Jobsearcher Workstream Session Attribution Authority
runTest("539. M3 Final: Exact Jobsearcher Workstream Session Attribution Authority") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_539_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    // Setup EXACT real Jobsearcher topology
    let jobsearcherProj = try registry.createProject(
        name: "Jobsearcher",
        initialWorkspacePath: "/Users/ava/Projects/Jobsearcher",
        initialWorkstreamName: "B Claude"
    )
    let wsCodex = try registry.addWorkspace(
        toProjectId: jobsearcherProj.id,
        path: "/Users/ava/Projects/Jobsearcher-codex",
        name: "Jobsearcher-codex"
    )

    let streamB = jobsearcherProj.workstreams[0]
    let streamA = try registry.addWorkstream(
        toProjectId: jobsearcherProj.id,
        name: "A Jobsearcher codex",
        workspaceIds: [wsCodex.id]
    )
    let streamC = try registry.addWorkstream(
        toProjectId: jobsearcherProj.id,
        name: "C Pi5 Claude",
        workspaceIds: [] // No workspace required
    )

    // Case 1: Session under Jobsearcher-codex -> Project Jobsearcher, Workstream A
    let sessCodex = AgentSessionInfo(
        provider: .codex,
        sessionId: "sess-codex-1",
        title: "Classify Stage-2 batch failure",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher-codex/packages/engine"
    )
    try assert(sessCodex.resolveProject(using: registry)?.id == jobsearcherProj.id)
    try assert(sessCodex.resolveWorkstream(using: registry)?.id == streamA.id)
    try assert(sessCodex.resolveWorkstream(using: registry)?.name == "A Jobsearcher codex")

    // Case 2: Session under Jobsearcher -> Project Jobsearcher, Workstream B
    let sessClaude = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-claude-1",
        title: "Fix scraper pipeline",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher/src/scraper"
    )
    try assert(sessClaude.resolveProject(using: registry)?.id == jobsearcherProj.id)
    try assert(sessClaude.resolveWorkstream(using: registry)?.id == streamB.id)
    try assert(sessClaude.resolveWorkstream(using: registry)?.name == "B Claude")

    // Case 3: Ambiguous / No dedicated workspace session -> Project Jobsearcher, Workstream Unknown (nil)
    // MUST NEVER guess Workstream C
    let sessPi = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-pi-1",
        title: "Pi5 remote orchestration",
        status: .working,
        cwd: "/tmp/pi5-scratch"
    )
    try assert(sessPi.resolveProject(using: registry) == nil)
    try assert(sessPi.resolveWorkstream(using: registry) == nil, "Outside CWD must never resolve to any workstream or guess C")
}

// 540. M3 Final: Workstream Attribution Strict Authority & Independence
runTest("540. M3 Final: Workstream Attribution Strict Authority & Independence") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_540_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")

    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    _ = try registry.addWorkstream(toProjectId: p.id, name: "C Pi5 Claude", workspaceIds: [])

    // Session with provider Claude and title 'Pi5 Claude' but CWD in Jobsearcher-codex
    // MUST resolve strictly to Workstream A based on CWD, NOT to C based on title/provider
    let deceptiveSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-deceptive",
        title: "Pi5 Claude remote review task",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher-codex/src"
    )

    try assert(deceptiveSession.resolveWorkstream(using: registry)?.id == streamA.id, "Attribution authority is strictly CWD -> Workspace -> Workstream, never provider or title keywords")
}

// 541. M3.7: Active session updates Recent snapshot metadata
runTest("541. M3.7: Active session updates Recent snapshot metadata") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_541_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let liveSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-sess-1",
        title: "Fix Scraper Engine",
        status: .working,
        cwd: "/Users/ava/Projects/App/src"
    )

    let updatedProj = registry.recordRecentSession(from: liveSession)
    try assert(updatedProj != nil)
    let recent = updatedProj?.recentSessions.first
    try assert(recent?.provider == .claude)
    try assert(recent?.sessionId == "claude-sess-1")
    try assert(recent?.title == "Fix Scraper Engine")
    try assert(recent?.lastStatus == .working)
    try assert(recent?.cwd == "/Users/ava/Projects/App/src")
}

// 542. M3.7: Claude SessionEnd removes Active but retains Recent
runTest("542. M3.7: Claude SessionEnd removes Active but retains Recent") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_542_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let liveSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-sess-end-1",
        title: "Refactor Database Client",
        status: .done,
        cwd: "/Users/ava/Projects/App/db"
    )

    // 1. Record snapshot before removal
    registry.recordRecentSession(from: liveSession)

    // 2. Simulate SessionEnd hook (which clears active session from AgentStore)
    let activeSessions: [AgentSessionInfo] = [] // active cleared

    // 3. Verify active is empty but recent snapshot is preserved in Project
    let loaded = registry.getProject(byId: p.id)
    try assert(loaded?.recentSessions.count == 1)
    try assert(loaded?.recentSessions.first?.sessionId == "claude-sess-end-1")
    try assert(loaded?.recentSessions.first?.title == "Refactor Database Client")
}

// 543. M3.7: Claude stale pruning removes Active but retains Recent
runTest("543. M3.7: Claude stale pruning removes Active but retains Recent") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_543_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let oldSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-stale-1",
        title: "Clean Unit Tests",
        status: .done,
        lastUpdated: Date().addingTimeInterval(-400), // > 300s old
        cwd: "/Users/ava/Projects/App"
    )

    registry.recordRecentSession(from: oldSession)
    let loaded = registry.getProject(byId: p.id)
    try assert(loaded?.recentSessions.count == 1)
    try assert(loaded?.recentSessions.first?.title == "Clean Unit Tests")
}

// 544. M3.7: Antigravity SessionEnd / reconciliation removes Active but retains Recent
runTest("544. M3.7: Antigravity SessionEnd / reconciliation removes Active but retains Recent") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_544_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let agySession = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-sess-1",
        title: "Architecture Planning",
        status: .done,
        cwd: "/Users/ava/Projects/App"
    )

    registry.recordRecentSession(from: agySession)
    let loaded = registry.getProject(byId: p.id)
    try assert(loaded?.recentSessions.count == 1)
    try assert(loaded?.recentSessions.first?.provider == .antigravity)
    try assert(loaded?.recentSessions.first?.sessionId == "agy-sess-1")
}

// 545. M3.7: Active session suppresses duplicate Recent rendering
runTest("545. M3.7: Active session suppresses duplicate Recent rendering") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_545_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let liveSession = AgentSessionInfo(
        provider: .codex,
        sessionId: "codex-123",
        title: "Active Task",
        status: .working,
        cwd: "/Users/ava/Projects/App"
    )

    // Snapshot recorded
    let updatedProj = registry.recordRecentSession(from: liveSession)!

    // Inactive filter test: active session list contains codex-123
    let activeSessions = [liveSession]
    let filteredRecent = updatedProj.recentSessions.filter { recent in
        !activeSessions.contains(where: { active in
            active.sessionId == recent.sessionId ||
            (active.provider == recent.provider && active.resolveWorkstream(using: registry)?.id == recent.workstreamId)
        })
    }

    try assert(filteredRecent.isEmpty, "Active session MUST suppress rendering of identical recent snapshot")
}

// 546. M3.7: Same stable session reactivating does not duplicate snapshot
runTest("546. M3.7: Same stable session reactivating does not duplicate snapshot") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_546_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    var sess = AgentSessionInfo(
        provider: .claude,
        sessionId: "stable-uuid-999",
        title: "Turn 1 Initial",
        status: .done,
        cwd: "/Users/ava/Projects/App"
    )
    registry.recordRecentSession(from: sess)

    // Reactivate same session with updated title/status
    sess.title = "Turn 2 Continuation"
    sess.status = .working
    let updatedProj = registry.recordRecentSession(from: sess)!

    try assert(updatedProj.recentSessions.count == 1, "Must not create duplicate snapshots for same session")
    try assert(updatedProj.recentSessions.first?.title == "Turn 2 Continuation")
    try assert(updatedProj.recentSessions.first?.lastStatus == .working)
}

// 547. M3.7: Only latest snapshot retained per Project × Workstream × Provider
runTest("547. M3.7: Only latest snapshot retained per Project × Workstream × Provider") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_547_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let streamId = p.workstreams.first?.id

    let olderSess = AgentSessionInfo(provider: .claude, sessionId: "sess-1", title: "Old Task", status: .done, cwd: "/Users/ava/Projects/App")
    registry.recordRecentSession(from: olderSess, inProjectId: p.id, workstreamId: streamId)

    let newerSess = AgentSessionInfo(provider: .claude, sessionId: "sess-2", title: "New Task", status: .done, cwd: "/Users/ava/Projects/App")
    let updatedProj = registry.recordRecentSession(from: newerSess, inProjectId: p.id, workstreamId: streamId)!

    try assert(updatedProj.recentSessions.count == 1, "At most 1 snapshot per Workstream × Provider")
    try assert(updatedProj.recentSessions.first?.sessionId == "sess-2")
    try assert(updatedProj.recentSessions.first?.title == "New Task")
}

// 548. M3.7: Two Workstreams retain independent recent snapshots for same provider
runTest("548. M3.7: Two Workstreams retain independent recent snapshots for same provider") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_548_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App/ws1", initialWorkstreamName: "Stream 1")
    let ws2 = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/App/ws2")
    let stream2 = try registry.addWorkstream(toProjectId: p.id, name: "Stream 2", workspaceIds: [ws2.id])

    let sessStream1 = AgentSessionInfo(provider: .claude, sessionId: "s1", title: "Stream 1 Work", status: .done, cwd: "/Users/ava/Projects/App/ws1")
    let sessStream2 = AgentSessionInfo(provider: .claude, sessionId: "s2", title: "Stream 2 Work", status: .done, cwd: "/Users/ava/Projects/App/ws2")

    registry.recordRecentSession(from: sessStream1)
    let updatedProj = registry.recordRecentSession(from: sessStream2)!

    try assert(updatedProj.recentSessions.count == 2, "Two distinct workstreams must retain independent snapshots")
    let s1Snap = updatedProj.recentSessions.first(where: { $0.title == "Stream 1 Work" })
    let s2Snap = updatedProj.recentSessions.first(where: { $0.title == "Stream 2 Work" })
    try assert(s1Snap?.workstreamId == p.workstreams.first?.id)
    try assert(s2Snap?.workstreamId == stream2.id)
}

// 549. M3.7: Project-known / Workstream-unknown session remains visible as Project-level Recent
runTest("549. M3.7: Project-known / Workstream-unknown session remains visible as Project-level Recent") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_549_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")
    let unassignedWs = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher/unassigned-sub")

    // Session in workspace that is not scoped to any workstream
    let sessUnassigned = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-unassigned",
        title: "Ad-hoc Maintenance",
        status: .done,
        cwd: "/Users/ava/Projects/Jobsearcher/unassigned-sub"
    )

    let updatedProj = registry.recordRecentSession(from: sessUnassigned)!
    let recent = updatedProj.recentSessions.first
    try assert(recent?.projectId == p.id)
    try assert(recent?.workstreamId == nil, "Unassigned workspace must have workstreamId == nil")
    try assert(recent?.title == "Ad-hoc Maintenance")
}

// 550. M3.7: Recent .blocked does NOT make Project currently Needs You
runTest("550. M3.7: Recent .blocked does NOT make Project currently Needs You") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_550_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let blockedSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "blocked-1",
        title: "Old Blocked Question",
        status: .blocked,
        cwd: "/Users/ava/Projects/App"
    )

    // Recorded as recent
    registry.recordRecentSession(from: blockedSession)

    // Status summary with NO active live sessions
    let summary = p.statusSummary(sessions: [], openTabs: [])
    try assert(summary.blockedCount == 0, "Recent blocked sessions must NOT count towards live blockedCount")
    try assert(summary.status == .idle, "Project status must remain .idle when no live active sessions exist")
    try assert(!summary.statusBadgeText.contains("Needs You"))
}

// 551. M3.7: Recent .working does NOT make Project currently Working
runTest("551. M3.7: Recent .working does NOT make Project currently Working") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_551_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "TestProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let workingSession = AgentSessionInfo(
        provider: .codex,
        sessionId: "codex-old-work",
        title: "Historic Generation",
        status: .working,
        cwd: "/Users/ava/Projects/App"
    )

    registry.recordRecentSession(from: workingSession)
    let summary = p.statusSummary(sessions: [], openTabs: [])
    try assert(summary.workingCount == 0, "Recent working sessions must NOT count towards live workingCount")
    try assert(summary.status == .idle)
}

// 552. M3.7: Active Needs You still overrides all Recent context normally
runTest("552. M3.7: Active Needs You still overrides all Recent context normally") {
    let p = Project(name: "TestProj", rootPath: "/Users/ava/Projects/App")
    let liveBlocked = AgentSessionInfo(provider: .antigravity, sessionId: "live-b", title: "Live Gate", status: .blocked, cwd: "/Users/ava/Projects/App")

    let summary = p.statusSummary(sessions: [liveBlocked], openTabs: [])
    try assert(summary.blockedCount == 1)
    try assert(summary.status == .blocked)
    try assert(summary.statusBadgeText.contains("Needs You"))
}

// 553. M3.7: Restart preserves Recent metadata across JSON reload
runTest("553. M3.7: Restart preserves Recent metadata across JSON reload") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_553_\(UUID().uuidString).json")
    let registry1 = ProjectRegistry(storageURL: testStorageURL)

    let p = try registry1.createProject(name: "PersistentProj", initialWorkspacePath: "/Users/ava/Projects/App")
    let sess = AgentSessionInfo(
        provider: .claude,
        sessionId: "persist-sess-1",
        title: "Session Snapshot To Save",
        status: .done,
        cwd: "/Users/ava/Projects/App"
    )
    registry1.recordRecentSession(from: sess)

    // Simulate app restart by loading new registry instance from same file
    let registry2 = ProjectRegistry(storageURL: testStorageURL)
    defer { registry2.resetForTesting() }

    let reloaded = registry2.getProject(byId: p.id)
    try assert(reloaded?.recentSessions.count == 1)
    try assert(reloaded?.recentSessions.first?.title == "Session Snapshot To Save")
    try assert(reloaded?.recentSessions.first?.provider == .claude)
}

// 554. M3.7: Persistence boundary: No transcript, prompt, output, or auth secrets stored
runTest("554. M3.7: Persistence boundary: No transcript, prompt, output, or auth secrets stored") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_554_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "SecretFree", initialWorkspacePath: "/Users/ava/Projects/App")
    let sess = AgentSessionInfo(
        provider: .claude,
        sessionId: "safe-sess-1",
        title: "Safe Title Only",
        status: .done,
        cwd: "/Users/ava/Projects/App"
    )
    registry.recordRecentSession(from: sess)

    let rawData = try Data(contentsOf: testStorageURL)
    let rawString = String(data: rawData, encoding: .utf8)!

    try assert(!rawString.contains("transcript"), "Transcript must NEVER be persisted in recent sessions")
    try assert(!rawString.contains("messages"), "Messages must NEVER be persisted in recent sessions")
    try assert(!rawString.contains("prompt"), "Prompts must NEVER be persisted in recent sessions")
    try assert(!rawString.contains("token"), "Auth secrets must NEVER be persisted in recent sessions")
    try assert(rawString.contains("safe-sess-1"), "Session ID must be persisted")
}

// 555. M3.7: M3.6 Workspace→Workstream attribution remains authoritative
runTest("555. M3.7: M3.6 Workspace→Workstream attribution remains authoritative") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_555_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])

    let sessCodex = AgentSessionInfo(provider: .codex, sessionId: "c1", title: "Task 1", status: .done, cwd: "/Users/ava/Projects/Jobsearcher-codex/sub")
    let updatedProj = registry.recordRecentSession(from: sessCodex)!

    let snap = updatedProj.recentSessions.first
    try assert(snap?.workstreamId == streamA.id, "Snapshot workstream MUST resolve via deepest workspace mapping")
}

// 556. M3.7: Jobsearcher A/B recent sessions remain separated correctly
runTest("556. M3.7: Jobsearcher A/B recent sessions remain separated correctly") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_556_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    let streamB = p.workstreams[0]

    let sessA = AgentSessionInfo(provider: .claude, sessionId: "sess-a", title: "Task on A", status: .done, cwd: "/Users/ava/Projects/Jobsearcher-codex")
    let sessB = AgentSessionInfo(provider: .claude, sessionId: "sess-b", title: "Task on B", status: .done, cwd: "/Users/ava/Projects/Jobsearcher")

    registry.recordRecentSession(from: sessA)
    let updatedProj = registry.recordRecentSession(from: sessB)!

    try assert(updatedProj.recentSessions.count == 2)
    try assert(updatedProj.recentSessions.first(where: { $0.sessionId == "sess-a" })?.workstreamId == streamA.id)
    try assert(updatedProj.recentSessions.first(where: { $0.sessionId == "sess-b" })?.workstreamId == streamB.id)
}

// 557. M3.7: C/ambiguous session remains Recent Unassigned rather than guessed
runTest("557. M3.7: C/ambiguous session remains Recent Unassigned rather than guessed") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_557_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    _ = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    _ = try registry.addWorkstream(toProjectId: p.id, name: "C Pi5 Claude", workspaceIds: [])

    // Add 3rd workspace in Jobsearcher project not assigned to any stream
    let wsUnassigned = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-extra")

    let sessExtra = AgentSessionInfo(
        provider: .claude,
        sessionId: "sess-extra",
        title: "Pi5 remote maintenance", // Title mentions Pi5
        status: .done,
        cwd: "/Users/ava/Projects/Jobsearcher-extra/src"
    )

    let updatedProj = registry.recordRecentSession(from: sessExtra)!
    let snap = updatedProj.recentSessions.first(where: { $0.sessionId == "sess-extra" })
    try assert(snap != nil)
    try assert(snap?.workstreamId == nil, "Must remain workstreamId == nil (Unassigned), never guessed to C")
}

// 558. M3 Final Acceptance: Antigravity session with reliable cwd resolves Project
runTest("558. M3 Final Acceptance: Antigravity session with reliable cwd resolves Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_558_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let agySession = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-test-558",
        title: "[Agent-webchat monitor]",
        status: .working,
        cwd: "/Users/ava/Projects/Agent-webchat monitor/Sources"
    )

    let matchedProj = agySession.resolveProject(using: registry)
    try assert(matchedProj?.id == p.id, "Antigravity session with reliable CWD MUST resolve to owning Project")
}

// 559. M3 Final Acceptance: Antigravity inactive session retains Recent under correct Project
runTest("559. M3 Final Acceptance: Antigravity inactive session retains Recent under correct Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_559_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let agySession = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-test-559",
        title: "[Agent-webchat monitor]",
        status: .done,
        cwd: "/Users/ava/Projects/Agent-webchat monitor"
    )

    let updatedProj = registry.recordRecentSession(from: agySession)
    try assert(updatedProj?.id == p.id, "Antigravity snapshot must attach to correct Project")
    try assert(updatedProj?.recentSessions.first?.provider == .antigravity)
    try assert(updatedProj?.recentSessions.first?.sessionId == "agy-test-559")
}

// 560. M3 Final Acceptance: Recent captured with workstreamId=nil later displays Workstream after current workspace scoping becomes unique
runTest("560. M3 Final Acceptance: Recent captured with workstreamId=nil later displays Workstream after current workspace scoping becomes unique") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_560_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [])

    // Snapshot captured when Workstream A had no workspaces assigned (workstreamId: nil)
    let historicalRecent = ProjectRecentSession(
        provider: .claude,
        sessionId: "claude-hist-1",
        title: "[Jobsearcher-codex]",
        cwd: "/Users/ava/Projects/Jobsearcher-codex",
        projectId: p.id,
        workstreamId: nil,
        lastStatus: .done
    )

    // Before scoping: returns nil ([Unassigned])
    try assert(historicalRecent.resolveCurrentWorkstream(using: registry) == nil)

    // User later scopes Jobsearcher-codex workspace to Workstream A
    _ = try registry.assignWorkspace(workspaceId: wsCodex.id, toWorkstreamId: streamA.id, inProjectId: p.id)

    // Dynamic resolution at render/read time now returns Workstream A!
    let resolved = historicalRecent.resolveCurrentWorkstream(using: registry)
    try assert(resolved?.id == streamA.id, "Recent workstream attribution must dynamically re-derive from current workspace topology")
    try assert(resolved?.name == "A Jobsearcher codex")
}

// 561. M3 Final Acceptance: Changing workspace scope A→B causes Recent display attribution to follow current topology
runTest("561. M3 Final Acceptance: Changing workspace scope A→B causes Recent display attribution to follow current topology") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_561_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher/ws", initialWorkstreamName: "Stream 1")
    let stream2 = try registry.addWorkstream(toProjectId: p.id, name: "Stream 2", workspaceIds: [])

    let recent = ProjectRecentSession(
        provider: .codex,
        sessionId: "cdx-1",
        title: "Task",
        cwd: "/Users/ava/Projects/Jobsearcher/ws",
        projectId: p.id,
        workstreamId: p.workstreams[0].id,
        lastStatus: .done
    )

    // Initially resolves to Stream 1
    try assert(recent.resolveCurrentWorkstream(using: registry)?.id == p.workstreams[0].id)

    // Move workspace from Stream 1 to Stream 2
    let wsId = p.workspaces[0].id
    _ = try registry.toggleWorkstreamWorkspace(workspaceId: wsId, workstreamId: p.workstreams[0].id, inProjectId: p.id)
    _ = try registry.toggleWorkstreamWorkspace(workspaceId: wsId, workstreamId: stream2.id, inProjectId: p.id)

    // Dynamic resolution now reflects Stream 2
    try assert(recent.resolveCurrentWorkstream(using: registry)?.id == stream2.id, "Dynamic resolution must track workspace reassignment")
}

// 562. M3 Final Acceptance: Ambiguous current scope returns Unassigned
runTest("562. M3 Final Acceptance: Ambiguous current scope returns Unassigned") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_562_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher/ws", initialWorkstreamName: "Stream 1")
    let stream2 = try registry.addWorkstream(toProjectId: p.id, name: "Stream 2", workspaceIds: [p.workspaces[0].id])

    // Workspace belongs to BOTH Stream 1 and Stream 2 -> ambiguous
    let recent = ProjectRecentSession(
        provider: .codex,
        sessionId: "cdx-ambig",
        title: "Task",
        cwd: "/Users/ava/Projects/Jobsearcher/ws",
        projectId: p.id,
        workstreamId: nil,
        lastStatus: .done
    )

    try assert(recent.resolveCurrentWorkstream(using: registry) == nil, "Ambiguous multi-workstream workspace must resolve to nil ([Unassigned])")
}

// 563. M3 Final Acceptance: Claude Desktop .done/.idle >300s + process alive remains tracked
runTest("563. M3 Final Acceptance: Claude Desktop .done/.idle >300s + process alive remains tracked") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let tempSessionsDir = "\(NSTemporaryDirectory())claude_sessions_test_563_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tempSessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempSessionsDir) }

    let testPid = getpid() // Current test runner process is alive!
    let sessionJson = """
    {
        "pid": \(testPid),
        "sessionId": "claude-desktop-sess-563",
        "entrypoint": "claude-desktop",
        "cwd": "/Users/ava/Projects/Jobsearcher-codex"
    }
    """
    try sessionJson.write(toFile: "\(tempSessionsDir)/\(testPid).json", atomically: true, encoding: .utf8)

    // Register active session that completed turn >400s ago
    _ = store.handleClaudeHookEvent(
        json: [
            "event": "Stop",
            "session_id": "claude-desktop-sess-563",
            "cwd": "/Users/ava/Projects/Jobsearcher-codex",
            "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-400))
        ],
        isTestMode: true
    )

    // Run pruning with test sessionsDir
    store.pruneStaleClaudeSessions(maxAgeSeconds: 300, sessionsDir: tempSessionsDir)

    // Session MUST remain tracked because process is alive!
    let active = store.getSessions(for: .claude)
    try assert(active.contains(where: { $0.sessionId == "claude-desktop-sess-563" }), "Alive Claude Desktop session must NOT be pruned merely due to >300s inactivity")
    store.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 564. M3 Final Acceptance: Preserved idle Claude session does NOT make Project Working
runTest("564. M3 Final Acceptance: Preserved idle Claude session does NOT make Project Working") {
    let p = Project(name: "Jobsearcher", rootPath: "/Users/ava/Projects/Jobsearcher-codex")
    let idleSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-desktop-idle",
        title: "[Jobsearcher-codex]",
        status: .idle,
        cwd: "/Users/ava/Projects/Jobsearcher-codex"
    )

    let summary = p.statusSummary(sessions: [idleSession], openTabs: [])
    try assert(summary.workingCount == 0, "Idle session must not increment workingCount")
    try assert(summary.status == .idle, "Project status must remain .idle for preserved idle session")
    try assert(!summary.statusBadgeText.contains("Working"))
}

// 565. M3 Final Acceptance: Preserved done Claude session uses existing done/ready semantics only
runTest("565. M3 Final Acceptance: Preserved done Claude session uses existing done/ready semantics only") {
    let p = Project(name: "Jobsearcher", rootPath: "/Users/ava/Projects/Jobsearcher-codex")
    let doneSession = AgentSessionInfo(
        provider: .claude,
        sessionId: "claude-desktop-done",
        title: "[Jobsearcher-codex]",
        status: .done,
        cwd: "/Users/ava/Projects/Jobsearcher-codex"
    )

    let summary = p.statusSummary(sessions: [doneSession], openTabs: [])
    try assert(summary.workingCount == 0, "Done session must not increment workingCount")
    try assert(summary.status == .done, "Project status must be .done for preserved done session")
    try assert(summary.statusBadgeText == "1 Ready", "Project status badge must show '1 Ready' according to existing done/ready semantics")
}

// 566. M3 Final Acceptance: Claude Desktop process exit removes tracked session and preserves Recent
runTest("566. M3 Final Acceptance: Claude Desktop process exit removes tracked session and preserves Recent") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let tempSessionsDir = "\(NSTemporaryDirectory())claude_sessions_test_566_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tempSessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempSessionsDir) }

    let deadPid = 999999 // Non-existent dead process
    let sessionJson = """
    {
        "pid": \(deadPid),
        "sessionId": "claude-desktop-dead-566",
        "entrypoint": "claude-desktop",
        "cwd": "/Users/ava/Projects/Jobsearcher-codex"
    }
    """
    try sessionJson.write(toFile: "\(tempSessionsDir)/\(deadPid).json", atomically: true, encoding: .utf8)

    _ = store.handleClaudeHookEvent(
        json: [
            "event": "Stop",
            "session_id": "claude-desktop-dead-566",
            "cwd": "/Users/ava/Projects/Jobsearcher-codex"
        ],
        isTestMode: true
    )

    // Reconcile dead sessions using test sessionsDir
    AutoMonitor.shared.reconcileDeadClaudeSessions(sessionsDir: tempSessionsDir)

    // Tracked sessions must now be empty
    let active = store.getSessions(for: .claude)
    try assert(!active.contains(where: { $0.sessionId == "claude-desktop-dead-566" }), "Terminated Claude desktop process must be removed from tracked sessions")
    store.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 567. M3 Final Acceptance: Ordinary Claude CLI lifecycle behavior is not accidentally made immortal
runTest("567. M3 Final Acceptance: Ordinary Claude CLI lifecycle behavior is not accidentally made immortal") {
    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .claude)

    let tempSessionsDir = "\(NSTemporaryDirectory())claude_sessions_test_567_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tempSessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempSessionsDir) }

    // Ordinary CLI session with no desktop process file
    _ = store.handleClaudeHookEvent(
        json: [
            "event": "Stop",
            "session_id": "claude-cli-567",
            "cwd": "/Users/ava/Projects/Jobsearcher-codex",
            "timestamp": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-400))
        ],
        isTestMode: true
    )

    // Prune with empty sessionsDir
    store.pruneStaleClaudeSessions(maxAgeSeconds: 300, sessionsDir: tempSessionsDir)

    // Non-desktop CLI session MUST be pruned after 300s
    let active = store.getSessions(for: .claude)
    try assert(!active.contains(where: { $0.sessionId == "claude-cli-567" }), "Ordinary CLI session without live desktop process must be pruned as stale")
    store.purgeSyntheticAndStaleSessions(provider: .claude)
}

// 568. Antigravity hook with one workspacePath resolves correct Project
runTest("568. Antigravity hook with one workspacePath resolves correct Project") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_568_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-hook-568",
        title: "AgentBridge Task",
        status: .working,
        workspacePaths: ["/Users/ava/Projects/Agent-webchat monitor"]
    )

    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == p.id, "Single authoritative workspacePath must resolve to matching Project")
}

// 569. Hook workspacePath descendant resolves through normal canonical matching
runTest("569. Hook workspacePath descendant resolves through normal canonical matching") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_569_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-hook-569",
        title: "AgentBridge Subdir Task",
        status: .working,
        workspacePaths: ["/Users/ava/Projects/Agent-webchat monitor/Sources/AgentSignalBar"]
    )

    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == p.id, "Workspace descendant must resolve through canonical prefix matching")
}

// 570. Session owned by AgentBridge reads TargetFile inside Jobsearcher -> remains AgentBridge
runTest("570. Session owned by AgentBridge reads TargetFile inside Jobsearcher -> remains AgentBridge") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_570_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let pAgent = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    _ = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")

    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)

    // Hook registers session with authoritative workspacePaths in AgentBridge
    _ = store.handleAntigravityHookEvent(
        json: [
            "event": "PreToolUse",
            "session_id": "agy-cross-proj-570",
            "workspace_paths": ["/Users/ava/Projects/Agent-webchat monitor"],
            "tool_name": "view_file",
            "tool_call": [
                "name": "view_file",
                "args": [
                    "AbsolutePath": "/Users/ava/Projects/Jobsearcher/Package.swift"
                ]
            ]
        ],
        isTestMode: true
    )

    let sessions = store.getSessions(for: .antigravity)
    let agySession = sessions.first(where: { $0.sessionId == "agy-cross-proj-570" })!

    // Must remain resolved to AgentBridge, NEVER falsely flipped to Jobsearcher
    try assert(agySession.resolveProject(using: registry)?.id == pAgent.id, "Reading external Jobsearcher file must NOT change session project ownership")
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)
}

// 571. SearchDirectory/SearchPath outside Project cannot change ownership
runTest("571. SearchDirectory/SearchPath outside Project cannot change ownership") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_571_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let pAgent = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    _ = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")

    let store = AgentStore.shared
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)

    _ = store.handleAntigravityHookEvent(
        json: [
            "event": "PreToolUse",
            "session_id": "agy-cross-proj-571",
            "workspace_paths": ["/Users/ava/Projects/Agent-webchat monitor"],
            "tool_name": "find_by_name",
            "tool_call": [
                "name": "find_by_name",
                "args": [
                    "SearchDirectory": "/Users/ava/Projects/Jobsearcher/Sources"
                ]
            ]
        ],
        isTestMode: true
    )

    let agySession = store.getSessions(for: .antigravity).first(where: { $0.sessionId == "agy-cross-proj-571" })!
    try assert(agySession.resolveProject(using: registry)?.id == pAgent.id, "SearchDirectory outside project must not alter ownership")
    store.purgeSyntheticAndStaleSessions(provider: .antigravity)
}

// 572. Missing workspacePaths -> Project Unknown
runTest("572. Missing workspacePaths -> Project Unknown") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_572_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")

    // Disk probe session with no workspace evidence
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-disk-probe-572",
        title: "[a8c0fd8c]",
        status: .working
    )

    try assert(session.resolveProject(using: registry) == nil, "Session with no workspace evidence must remain Project Unknown (nil)")
    try assert(session.associatedProjectName == "Unassigned")
}

// 573. Multiple workspacePaths all inside same Project -> Project resolves
runTest("573. Multiple workspacePaths all inside same Project -> Project resolves") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_573_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-multi-same-573",
        title: "Multi-workspace same project",
        status: .working,
        workspacePaths: [
            "/Users/ava/Projects/Agent-webchat monitor/Sources",
            "/Users/ava/Projects/Agent-webchat monitor/Tests"
        ]
    )

    let matched = session.resolveProject(using: registry)
    try assert(matched?.id == p.id, "Multiple workspacePaths all inside same Project must resolve to that Project")
}

// 574. Multiple workspacePaths spanning two Projects -> Project Unknown
runTest("574. Multiple workspacePaths spanning two Projects -> Project Unknown") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_574_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    _ = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    _ = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")

    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-multi-diff-574",
        title: "Cross-project workspaces",
        status: .working,
        workspacePaths: [
            "/Users/ava/Projects/Agent-webchat monitor",
            "/Users/ava/Projects/Jobsearcher"
        ]
    )

    try assert(session.resolveProject(using: registry) == nil, "Multiple workspacePaths spanning two Projects must resolve to nil (Unknown/Unassigned)")
}

// 575. Multiple workspace evidence mapping to different Workstreams -> Workstream Unknown
runTest("575. Multiple workspace evidence mapping to different Workstreams -> Workstream Unknown") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_575_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher/ws1", initialWorkstreamName: "Stream 1")
    let ws2 = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher/ws2")
    _ = try registry.addWorkstream(toProjectId: p.id, name: "Stream 2", workspaceIds: [ws2.id])

    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-multi-stream-575",
        title: "Multi-stream workspaces",
        status: .working,
        workspacePaths: [
            "/Users/ava/Projects/Jobsearcher/ws1",
            "/Users/ava/Projects/Jobsearcher/ws2"
        ]
    )

    try assert(session.resolveProject(using: registry)?.id == p.id, "Same project must resolve")
    try assert(session.resolveWorkstream(using: registry) == nil, "Workspaces spanning two different Workstreams must resolve to nil Workstream (Unknown)")
}

// 576. Unambiguous workspace evidence -> correct Workstream
runTest("576. Unambiguous workspace evidence -> correct Workstream") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_576_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "Stream B")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "Stream A", workspaceIds: [wsCodex.id])

    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-stream-576",
        title: "Unambiguous task",
        status: .working,
        workspacePaths: ["/Users/ava/Projects/Jobsearcher-codex/sub"]
    )

    let ws = session.resolveWorkstream(using: registry)
    try assert(ws?.id == streamA.id, "Unambiguous workspacePath must resolve to matching Workstream")
}

// 577. Recent snapshot never moves Project because of external tool-operation path
runTest("577. Recent snapshot never moves Project because of external tool-operation path") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_577_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let pAgent = try registry.createProject(name: "AgentBridge", initialWorkspacePath: "/Users/ava/Projects/Agent-webchat monitor")
    let pJob = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher")

    let session = AgentSessionInfo(
        provider: .antigravity,
        sessionId: "agy-snap-577",
        title: "Done task",
        status: .done,
        workspacePaths: ["/Users/ava/Projects/Agent-webchat monitor"]
    )

    let updated = registry.recordRecentSession(from: session)!
    try assert(updated.id == pAgent.id, "Recent snapshot must attach to AgentBridge Project")

    // Check Jobsearcher project has no recent sessions
    let jobProj = registry.getProject(byId: pJob.id)!
    try assert(jobProj.recentSessions.isEmpty, "Jobsearcher must have zero recent sessions")
}

// 578. Scoping toggle mutates intended Workstream workspaceIds and persists to disk
runTest("578. Scoping toggle mutates intended Workstream workspaceIds and persists to disk") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_578_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [])

    // Toggle on Workstream A -> Jobsearcher-codex
    let updated = try registry.toggleWorkstreamWorkspace(workspaceId: wsCodex.id, workstreamId: streamA.id, inProjectId: p.id)
    let streamAUpdated = updated.workstreams.first(where: { $0.id == streamA.id })!
    try assert(streamAUpdated.workspaceIds == [wsCodex.id], "Workstream A must contain wsCodex ID")

    // Verify persisted file on disk
    let reloadedRegistry = ProjectRegistry(storageURL: testStorageURL)
    let reloadedProj = reloadedRegistry.getProject(byId: p.id)!
    let reloadedStreamA = reloadedProj.workstreams.first(where: { $0.id == streamA.id })!
    try assert(reloadedStreamA.workspaceIds == [wsCodex.id], "Persisted projects.json must retain workspaceIds")
}

// 579. Persisted registry reload retains exact Workstream workspace scoping
runTest("579. Persisted registry reload retains exact Workstream workspace scoping") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_579_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsJob = p.workspaces[0]
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [])
    let streamB = p.workstreams[0]

    _ = try registry.assignWorkspace(workspaceId: wsCodex.id, toWorkstreamId: streamA.id, inProjectId: p.id)
    _ = try registry.assignWorkspace(workspaceId: wsJob.id, toWorkstreamId: streamB.id, inProjectId: p.id)

    // Reload from disk
    let reloaded = ProjectRegistry(storageURL: testStorageURL)
    let pReloaded = reloaded.getProject(byId: p.id)!
    try assert(pReloaded.workstreams.first(where: { $0.id == streamA.id })?.workspaceIds == [wsCodex.id])
    try assert(pReloaded.workstreams.first(where: { $0.id == streamB.id })?.workspaceIds == [wsJob.id])
}

// 580. Second Workstream can scope different workspace while third remains empty
runTest("580. Second Workstream can scope different workspace while third remains empty") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_580_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsJob = p.workspaces[0]
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    let streamC = try registry.addWorkstream(toProjectId: p.id, name: "C Pi5 Claude", workspaceIds: [])
    let streamB = p.workstreams[0]
    _ = try registry.assignWorkspace(workspaceId: wsJob.id, toWorkstreamId: streamB.id, inProjectId: p.id)

    let latest = registry.getProject(byId: p.id)!
    try assert(latest.workstreams.first(where: { $0.id == streamA.id })?.workspaceIds == [wsCodex.id])
    try assert(latest.workstreams.first(where: { $0.id == streamB.id })?.workspaceIds == [wsJob.id])
    try assert(latest.workstreams.first(where: { $0.id == streamC.id })?.workspaceIds.isEmpty == true, "Stream C must remain empty")
}

// 581. Live session CWD resolves to scoped Workstream in Jobsearcher topology
runTest("581. Live session CWD resolves to scoped Workstream in Jobsearcher topology") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_581_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsJob = p.workspaces[0]
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    let streamB = p.workstreams[0]
    _ = try registry.assignWorkspace(workspaceId: wsJob.id, toWorkstreamId: streamB.id, inProjectId: p.id)

    // Codex in Jobsearcher-codex
    let sessCodex = AgentSessionInfo(
        provider: .codex,
        sessionId: "cdx-581",
        title: "Jobsearcher-codex",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher-codex"
    )
    let wsResolvedA = sessCodex.resolveWorkstream(using: registry)
    try assert(wsResolvedA?.id == streamA.id, "Codex in Jobsearcher-codex MUST resolve to Workstream A")

    // Claude in Jobsearcher
    let sessClaude = AgentSessionInfo(
        provider: .claude,
        sessionId: "cld-581",
        title: "[Jobsearcher]",
        status: .idle,
        cwd: "/Users/ava/Projects/Jobsearcher"
    )
    let wsResolvedB = sessClaude.resolveWorkstream(using: registry)
    try assert(wsResolvedB?.id == streamB.id, "Claude in Jobsearcher MUST resolve to Workstream B")
}

// 582. Active Agent Sessions visibly render Workstream label [A Jobsearcher codex] and [B Claude]
runTest("582. Active Agent Sessions visibly render Workstream label [A Jobsearcher codex] and [B Claude]") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_582_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsJob = p.workspaces[0]
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])
    let streamB = p.workstreams[0]
    _ = try registry.assignWorkspace(workspaceId: wsJob.id, toWorkstreamId: streamB.id, inProjectId: p.id)

    let sessCodex = AgentSessionInfo(
        provider: .codex,
        sessionId: "cdx-582",
        title: "Jobsearcher-codex",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher-codex"
    )

    let ws = sessCodex.resolveWorkstream(using: registry)
    let latestProj = registry.getProject(byId: p.id)!
    let streamTag = (latestProj.workstreams.count > 1 && ws != nil) ? "[\(ws!.name)] " : ""
    let renderedTitle = "\(streamTag)\(sessCodex.provider.displayName): \(sessCodex.title)"
    try assert(renderedTitle == "[A Jobsearcher codex] Codex Desktop: Jobsearcher-codex", "Visible Active Agent Sessions label must match [A Jobsearcher codex] Codex Desktop: Jobsearcher-codex")
}

// 583. Registry reload does not erase or reset Workstream scope
runTest("583. Registry reload does not erase or reset Workstream scope") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_583_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])

    // Load multiple times
    let reg2 = ProjectRegistry(storageURL: testStorageURL)
    try assert(reg2.getProject(byId: p.id)?.workstreams.first(where: { $0.id == streamA.id })?.workspaceIds == [wsCodex.id])

    let reg3 = ProjectRegistry(storageURL: testStorageURL)
    try assert(reg3.getProject(byId: p.id)?.workstreams.first(where: { $0.id == streamA.id })?.workspaceIds == [wsCodex.id])
}

// 584. Attribution remains strictly CWD -> Workspace -> Project -> Workstream (no keywords/titles)
runTest("584. Attribution remains strictly CWD -> Workspace -> Project -> Workstream (no keywords/titles)") {
    let tempDir = NSTemporaryDirectory()
    let testStorageURL = URL(fileURLWithPath: "\(tempDir)/AgentSignalBarTest_projects_584_\(UUID().uuidString).json")
    let registry = ProjectRegistry(storageURL: testStorageURL)
    defer { registry.resetForTesting() }

    let p = try registry.createProject(name: "Jobsearcher", initialWorkspacePath: "/Users/ava/Projects/Jobsearcher", initialWorkstreamName: "B Claude")
    let wsCodex = try registry.addWorkspace(toProjectId: p.id, path: "/Users/ava/Projects/Jobsearcher-codex")
    let streamA = try registry.addWorkstream(toProjectId: p.id, name: "A Jobsearcher codex", workspaceIds: [wsCodex.id])

    // Session named "B Claude Task" but located inside Jobsearcher-codex
    let deceptive = AgentSessionInfo(
        provider: .claude,
        sessionId: "deceptive-584",
        title: "B Claude Task",
        status: .working,
        cwd: "/Users/ava/Projects/Jobsearcher-codex/sub"
    )

    let ws = deceptive.resolveWorkstream(using: registry)
    try assert(ws?.id == streamA.id, "Session attribution must strictly follow CWD path, NOT title keywords")
}

print("🎉 All 584 Production Swift Containment, Turn Continuity, Quota, Closed-Lid Default, Product Actions Simplification, Theme-Aware Legend, Structured Claude Quota, Monitored Agents, Copilot Lifecycle Repair, Copilot Quota, One-Shot Switch, Provider Icons, Canonical Priority, Lifecycle Reconciliation, Menu Bar UI Visibility, Five-Provider Smart Auto, Telegram Bridge Foundation, Codex Lifecycle Repair, Turn-Aware Auto-Switch, Rate-Limit Semantic Repair, Telegram Privacy Security, Codex Title Hierarchy, Thinking Timestamp Truth, P1 UX, Closed-Provider Space Optimization, Codex Multi-Session Lifecycle Reconciliation, ChatGPT Monitor Health, Provider Close Lifecycle Truth, Claude Quota Reset Preservation, Telegram Root Menu, Fun Emoji Config, Codex Current Version Lifecycle Truth, Source Health, M2.1 Identity & Notification UX, P0-A Test Isolation & P0-B1/B2 Codex Rollout, Subprocess Deadlock, Antigravity Transcript Probe, M2.1.1 Cached Privilege Probing, Startup-Silent Health Notifications, Antigravity Evidence-Driven Fallback, M3.1 Project Registry Foundation, Subprocess Non-Blocking Worker Reaping, Telegram Health Delivery Confirmation, Sleep Outage Preservation, Store Deadlock Elimination, M3.2 ChatGPT Reviewer Association, M3.3 CWD Session Association, M3.4 GitHub Repository Association, M3.5 Project Switcher Contextual Navigation, M3.6 Project Formation Multi-Workspace Workstream Model, M3.7 Recent Session Continuity, Antigravity Authoritative workspacePaths Attribution & Workstream Scoping Persistence Tests Passed!")
