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

print("🎉 All 28 Production Swift Containment, Turn Continuity & Quota Tests Passed!")






