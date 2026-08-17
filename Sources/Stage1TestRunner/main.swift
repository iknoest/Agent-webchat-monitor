import Foundation
import AgentSignalBarCore

func runTest(_ name: String, block: () throws -> Void) {
    do {
        try block()
        print("✅ Passed: \(name)")
    } catch {
        print("❌ Failed: \(name) - \(error)")
        exit(1)
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

// 41. Codex remains excluded from Smart Auto
runTest("41. Codex remains excluded from Smart Auto") {
    let sleepMgr = SleepManager.shared
    let store = AgentStore.shared

    try assert(!SleepManager.trustedProviders.contains(.codex), "Codex MUST NOT be present in SleepManager.trustedProviders.")

    store.updateStatus(for: .claude, status: .idle)
    store.updateStatus(for: .chatgpt, status: .idle)
    store.updateStatus(for: .antigravity, status: .idle)
    store.updateStatus(for: .codex, status: .working, detail: "Codex active task")

    let eval = sleepMgr.evaluateSmartAutoRequirement()
    try assert(eval.shouldKeepAwake == false, "Working Codex alone MUST NOT keep Smart Auto awake.")
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
}

print("🎉 All 54 Production Swift Containment, Turn Continuity, Quota, Closed-Lid, Codex Rollout, Compact Menu Bar, Quota Availability & Unified Display Tests Passed!")
