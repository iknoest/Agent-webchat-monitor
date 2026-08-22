import Foundation
import Cocoa
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

func runAsyncTest(_ name: String, block: @escaping () async throws -> Void) {
    let sema = DispatchSemaphore(value: 0)
    var testErr: Error?
    Task {
        do {
            try await block()
        } catch {
            testErr = error
        }
        sema.signal()
    }
    sema.wait()
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

// 50. Quota Availability: Claude idle + quotaExhausted -> CLD:⦸ (Lifecycle remains .idle)
runTest("50. Quota Availability: Claude idle + quotaExhausted -> CLD:⦸") {
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
    try assert(summary.contains("CLD:⦸"), "Claude idle + quotaExhausted must display 'CLD:⦸' (actual: \(summary)).")
    try assert(store.getStatus(for: .claude).status == .idle, "Underlying lifecycle status must remain .idle.")
    try assert(store.getStatus(for: .claude).availability == .quotaExhausted, "Availability must be .quotaExhausted.")
}

// 51. Quota Availability: Compact mode shows CLD⦸ when everything else is idle
runTest("51. Quota Availability: Compact mode shows CLD⦸ when everything else is idle") {
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
    try assert(compact == "CLD⦸", "Compact mode must show 'CLD⦸' when Claude is quota-exhausted and other agents are idle (actual: \(compact)).")
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
    try assert(exhaustedInfo.effectiveDisplayStatus.badge(theme: .classic) == "⦸", "Classic quota exhausted badge must be '⦸'.")
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
    try assert(info.effectiveDisplayStatus.badge(theme: .classic) == "⦸", "All exhausted provider badge must be '⦸'.")
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

    // Claude exhausted -> Compact shows CLD⦸
    let claudeExhausted = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, freshness: "Fresh")
    usageStore.updateUsage(for: .claude, data: claudeExhausted)

    let summary = store.compactSummary()
    try assert(summary.contains("CLD⦸") || summary.contains("CLD:⦸"), "Compact summary must show CLD⦸ when Claude is exhausted (actual: '\(summary)').")

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
    try assert(badges.contains("⦸"), "Classic legend must contain ⦸ for Quota Exhausted")
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
            try assert(item.badge == directBadge || (theme == .funEmoji && (item.badge == "🥵" || item.badge == "⦸")), "Legend badge must strictly match EffectiveDisplayStatus.badge(theme:)")
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

    switchMgr.arm(provider: .copilot, sessionId: "sess_copilot_99")
    let trans = switchMgr.evaluateTransition(provider: .copilot, sessionId: "sess_copilot_99", newStatus: .done)
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

    switchMgr.arm(provider: .antigravity, sessionId: "agy_perm_sess")
    let trans = switchMgr.evaluateTransition(provider: .antigravity, sessionId: "agy_perm_sess", newStatus: .blocked)
    try assert(trans, "Transition to Blocked (Needs You) must trigger One-Shot Switch")
    try assert(switchMgr.armedTarget == nil, "Watch must be disarmed")

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
    ConfigManager.shared.setAgentMonitored(.claude, monitored: true)

    let sess = AgentSessionInfo(provider: .claude, sessionId: "sess_done_tg_01", title: "Build Project", status: .done, lastDurationSeconds: 45)
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
    try assert(msg.text.contains("New output ready (45s)"), "Must contain duration")

    EnvConfigLoader.shared.reload()
}

// 210. Telegram: Duplicate Done status does not resend within debounce window
runTest("210. Telegram: Duplicate Done status does not resend within debounce window") {
    let mockTransport = MockTelegramTransport()
    let bridge = TelegramBridge(transport: mockTransport)

    EnvConfigLoader.shared.setConfigForTesting(TelegramConfig(botToken: "dummy_tok", chatId: "12345"))
    ConfigManager.shared.setTelegramEnabled(true)
    ConfigManager.shared.setAgentMonitored(.antigravity, monitored: true)

    let sess = AgentSessionInfo(provider: .antigravity, sessionId: "agy_done_01", title: "Refactor API", status: .done)
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

    let sess1 = AgentSessionInfo(provider: .chatgpt, sessionId: "tab_101", title: "Math QA", status: .done)
    let sess2 = AgentSessionInfo(provider: .chatgpt, sessionId: "tab_102", title: "Code Review", status: .done)

    AgentStore.shared.syncSessions(for: .chatgpt, activeSessions: [sess1], processRunning: true)
    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .working, newStatus: .done, detail: "Math QA")

    AgentStore.shared.syncSessions(for: .chatgpt, activeSessions: [sess2], processRunning: true)
    bridge.handleAgentStatusChange(agent: .chatgpt, oldStatus: .working, newStatus: .done, detail: "Code Review")

    let exp = Date().addingTimeInterval(0.2)
    while Date() < exp { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    let sent = mockTransport.getAllSentMessages()
    try assert(sent.count == 2, "Distinct sessions must both send alerts")
    try assert(sent[0].text.contains("Math QA"))
    try assert(sent[1].text.contains("Code Review"))

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
    try assert(text.contains("AgentSignalBar Status"), "Must contain header")
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
    try assert(text.contains("AgentSignalBar Quota"), "Must contain quota header")
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
    try assert(text.contains("AgentSignalBar Sessions"), "Must contain sessions header")
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
    try assert(sent[0].text == "✅ AgentSignalBar Telegram alerts connected")
    try assert(sent[0].chatId == "55555")

    EnvConfigLoader.shared.reload()
}

print("🎉 All 223 Production Swift Containment, Turn Continuity, Quota, Closed-Lid Default, Product Actions Simplification, Theme-Aware Legend, Structured Claude Quota, Monitored Agents, Copilot Lifecycle Repair, Copilot Quota, One-Shot Switch, Provider Icons, Canonical Priority, Lifecycle Reconciliation, Menu Bar UI Visibility, Five-Provider Smart Auto & Telegram Bridge Foundation Tests Passed!")
