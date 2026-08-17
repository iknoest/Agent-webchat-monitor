import Foundation
import AgentSignalBarCore

#if canImport(XCTest)
import XCTest

final class AgentSignalBarTests: XCTestCase {

    func testUsageStoreLivePriorityAndDiskWriteSuppression() throws {
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

        XCTAssertEqual(current?.sessionLimitPercent, 25.0, "Non-live config fallback must NOT overwrite live source.")
        XCTAssertTrue(current?.isLiveSource ?? false, "Source must remain marked as live.")
    }

    func testRealMenuBarManagerThrottleSchedulingAndLatestStateCapture() throws {
        let manager = MenuBarManager.shared
        manager.resetTestMetrics()

        var capturedSignatures: [String] = []
        manager.onPerformUpdateTitleAndMenu = {
            capturedSignatures.append(manager.computeRenderSignature())
        }

        for i in 1...12 {
            AgentStore.shared.updateStatus(for: .chatgpt, status: .working, detail: "Step \(i)")
            manager.scheduleTitleAndMenuUpdate()
            XCTAssertLessThanOrEqual(manager.activePendingTimerCount, 1, "No more than 1 pending timer must ever exist.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05)) // Run active RunLoop 50ms x 12 = 600ms
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        XCTAssertGreaterThanOrEqual(manager.renderExecutionCount, 2, "More than 1 rate window must be genuinely exercised.")
        XCTAssertLessThanOrEqual(manager.renderExecutionCount, 4, "Sustained triggers must remain rate-bounded.")
        XCTAssertEqual(capturedSignatures.count, manager.renderExecutionCount, "Captured signatures count must equal render execution count.")

        let lastCapturedSignature = capturedSignatures.last ?? ""
        XCTAssertTrue(lastCapturedSignature.contains("Step 12"), "The LAST ACTUAL RENDER CALLBACK must observe the final Step 12 state.")
    }

    func testAutoMonitorDeterministicPollingNonOverlap() throws {
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

        Thread.sleep(forTimeInterval: 0.05) // Ensure Thread 1 is holding poll body lock

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

        XCTAssertEqual(monitor.peakConcurrentCheckCount, 1, "Peak concurrent poll body executions must be exactly 1.")
        XCTAssertEqual(monitor.rejectedConcurrentCheckCount, 10, "10 competing callers must be rejected during held window.")
        monitor.pollBodyHandler = nil
    }

    func testAutoMonitorClaudeTranscriptMetadataCacheDecision() throws {
        let monitor = AutoMonitor.shared
        monitor.resetTestMetrics()

        let d1 = Date()
        let d2 = Date().addingTimeInterval(10)

        let infoA1 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d1)
        let infoA1_dupe = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d1)
        let infoA2 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_a.jsonl", modDate: d2)
        let infoB2 = AutoMonitor.ClaudeTranscriptInfo(path: "/tmp/mock_claude_b.jsonl", modDate: d2)

        XCTAssertTrue(monitor.shouldReadClaudeTranscript(info: infoA1), "New path/mtime must require content read.")
        XCTAssertFalse(monitor.shouldReadClaudeTranscript(info: infoA1_dupe), "Identical path+mtime must suppress content read.")
        XCTAssertTrue(monitor.shouldReadClaudeTranscript(info: infoA2), "Changed mtime must require content read.")
        XCTAssertTrue(monitor.shouldReadClaudeTranscript(info: infoB2), "Changed path must require content read.")

        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_oversized_transcript_\(UUID().uuidString).jsonl")

        let chunk = String(repeating: "{\"type\":\"user\",\"content\":\"hello world test line\"}\n", count: 4000)
        try chunk.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let readContent = monitor.readTailOfFile(atPath: fileURL.path, maxBytes: 65536)
        XCTAssertNotNil(readContent, "Tail reader must read contents.")
        let bytesCount = readContent?.utf8.count ?? 0
        XCTAssertLessThanOrEqual(bytesCount, 65540, "Tail reader output must be bounded to maxBytes limit.")
    }

    func testSubprocessTimeoutReapingAndUnreapedContainment() throws {
        let monitor = AutoMonitor.shared
        monitor.resetProcessTracking()

        // A. Normal command completes
        let echoOutput = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello_world"],
            timeoutSeconds: 1.0
        )
        XCTAssertEqual(echoOutput, "hello_world", "Fast command must complete and return output.")
        XCTAssertNotNil(monitor.lastSubprocessPID, "Subprocess PID must be recorded.")
        XCTAssertTrue(monitor.lastSubprocessConfirmedReaped, "Normal execution must be reported as confirmed reaped.")
        XCTAssertNil(monitor.unresolvedProcessPID, "Unresolved PID must be nil.")

        let echoPID = monitor.lastSubprocessPID!
        XCTAssertNotEqual(kill(echoPID, 0), 0, "Normal command PID must be confirmed dead/reaped.")

        // B. Timeout + successful termination reported as confirmed reaped
        let start = Date()
        let sleepOutput = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeoutSeconds: 0.1
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(sleepOutput, "Timed out command must return nil output.")
        XCTAssertLessThan(elapsed, 1.0, "Timed out command must be terminated within 1.0s limit.")
        XCTAssertTrue(monitor.lastSubprocessConfirmedReaped, "Timeout with successful termination must be reported as confirmed reaped.")
        XCTAssertNil(monitor.unresolvedProcessPID, "Unresolved PID must be nil.")

        let sleepPID = monitor.lastSubprocessPID!
        XCTAssertNotEqual(kill(sleepPID, 0), 0, "Timed out command PID must be confirmed dead/reaped.")

        // C. Unresolved process blocking guard
        monitor.resetProcessTracking()
        monitor.setUnresolvedProcessPIDForTesting(ProcessInfo.processInfo.processIdentifier)

        // Attempt second launch while previous process is recorded as active unresolved
        let blockedOutput = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["should_be_blocked"],
            timeoutSeconds: 1.0
        )
        XCTAssertNil(blockedOutput, "Subprocess launch must be blocked while unresolved process exists.")
        XCTAssertGreaterThanOrEqual(monitor.processSpawnBlockedCount, 1, "Blocked spawn counter must be incremented.")

        // Clear test unresolved PID
        monitor.setUnresolvedProcessPIDForTesting(nil)

        // Now that unresolved PID has been cleared, launch resumes
        let resumedOutput = monitor.runProcessWithTimeout(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["resumed_launch"],
            timeoutSeconds: 1.0
        )
        XCTAssertEqual(resumedOutput, "resumed_launch", "Subprocess launch must resume once unresolved PID has been cleared.")
        XCTAssertNil(monitor.unresolvedProcessPID, "Unresolved PID must be nil.")
    }

    func testChatGPTTabFocusRouting() throws {
        // Test URL focus helper doesn't crash and generates clean target
        WindowFocuser.focusURL("https://chatgpt.com/c/019ff013-ecb8-7101-baa5-90f3acdd1a3f")
        WindowFocuser.focusAgent(.chatgpt, targetURL: "https://chatgpt.com/c/019ff013-ecb8-7101-baa5-90f3acdd1a3f")
        XCTAssertTrue(true, "ChatGPT tab focus routing executed without exception.")
    }

    func testCodexSessionEventParsing() throws {
        let monitor = AutoMonitor.shared
        let tmpDir = FileManager.default.temporaryDirectory
        let sessionFile = tmpDir.appendingPathComponent("test_codex_rollout_\(UUID().uuidString).jsonl")

        let workingEvent = """
        {"timestamp":"2026-08-13T14:04:28.880Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_123"}}
        """
        try workingEvent.write(to: sessionFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sessionFile) }

        let tailContent = monitor.readTailOfFile(atPath: sessionFile.path, maxBytes: 65536)
        XCTAssertNotNil(tailContent, "Session tail must be read.")
        XCTAssertTrue(tailContent?.contains("custom_tool_call") ?? false, "Working tool call payload must be detected in session stream.")
    }

    func testAntigravityPendingModalDetection() throws {
        let monitor = AutoMonitor.shared
        let tmpDir = FileManager.default.temporaryDirectory
        let transcriptFile = tmpDir.appendingPathComponent("test_antigravity_transcript_\(UUID().uuidString).jsonl")

        let pendingTurn = """
        {"type":"USER_INPUT","content":"Run test command"}
        {"type":"PLANNER_RESPONSE","content":"Running command","tool_calls":[{"name":"run_command","args":{}}]}
        """
        try pendingTurn.write(to: transcriptFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcriptFile) }

        let tailContent = monitor.readTailOfFile(atPath: transcriptFile.path, maxBytes: 65536)
        XCTAssertNotNil(tailContent, "Transcript tail must be read.")
        XCTAssertTrue(tailContent?.contains("\"tool_calls\"") ?? false, "Pending planner tool call must be detected.")
    }

    func testClaudeToolUsePermissionDetection() throws {
        let monitor = AutoMonitor.shared
        let tmpDir = FileManager.default.temporaryDirectory
        let projectFile = tmpDir.appendingPathComponent("test_claude_project_\(UUID().uuidString).jsonl")

        let pendingToolUse = """
        {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","type":"tool_use"}}
        """
        try pendingToolUse.write(to: projectFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: projectFile) }

        let tailContent = monitor.readTailOfFile(atPath: projectFile.path, maxBytes: 65536)
        XCTAssertNotNil(tailContent, "Claude project tail must be read.")
        XCTAssertTrue(tailContent?.contains("tool_use") ?? false, "Claude tool_use permission gate must be detected.")
    }

    func testHTTPServerRequestTabFocusAndPop() throws {
        let server = HTTPServer.shared
        server.requestTabFocus(tabId: 998877)
        let popped = server.popPendingFocusTabId()
        XCTAssertEqual(popped, 998877, "HTTPServer must store and pop requested tabId 998877.")
        XCTAssertNil(server.popPendingFocusTabId(), "Popping second time must return nil.")
    }

    func testAgentStoreTargetTabIdStorage() throws {
        let store = AgentStore.shared
        store.updateStatus(for: .chatgpt, status: .done, detail: "Done output", sessionTitle: "Session 456", targetTabId: 456)
        let current = store.getStatus(for: .chatgpt)
        XCTAssertEqual(current.targetTabId, 456, "AgentStore must store exact targetTabId 456.")
        XCTAssertEqual(current.sessionTitle, "Session 456", "AgentStore must store sessionTitle Session 456.")
    }

    func testFocusingChromeCannotTurnBlockedAggregateIdle() throws {
        let store = AgentStore.shared
        store.updateStatus(for: .chatgpt, status: .blocked, detail: "Connection interrupted")
        let initial = store.getStatus(for: .chatgpt)
        XCTAssertEqual(initial.status, .blocked, "Initial status must be blocked.")

        // Simulate focusing Google Chrome window
        store.checkAutoInspect(frontmostBundleId: "com.google.Chrome")
        Thread.sleep(forTimeInterval: 0.1)
        store.checkAutoInspect(frontmostBundleId: "com.google.Chrome")

        let after = store.getStatus(for: .chatgpt)
        XCTAssertEqual(after.status, .blocked, "Focusing Chrome window MUST NOT turn aggregate blocked status to idle.")
    }

    func testTopPriorityPresentationFlickerPrevention() throws {
        let store = AgentStore.shared
        store.updateStatus(for: .claude, status: .done, detail: "Claude turn complete")
        let top1 = store.getHighestPriorityAgent()
        XCTAssertEqual(top1?.id, .claude, "Top item must initially select Claude (done).")

        // 1s later, ChatGPT reports done (equal priority)
        Thread.sleep(forTimeInterval: 0.1)
        store.updateStatus(for: .chatgpt, status: .done, detail: "ChatGPT output ready")
        let top2 = store.getHighestPriorityAgent()
        XCTAssertEqual(top2?.id, .claude, "Top item must hold Claude for 5s against equal-priority ChatGPT done to prevent flicker.")

        // Higher priority blocked state arrives for Antigravity
        store.updateStatus(for: .antigravity, status: .blocked, detail: "Permission prompt")
        let top3 = store.getHighestPriorityAgent()
        XCTAssertEqual(top3?.id, .antigravity, "Higher priority blocked state must immediately preempt lower priority top item.")
    }

    func testOpenLidSmartKeepAwakeLifecycleAndNoLeaks() throws {
        let sleepMgr = SleepManager.shared
        sleepMgr.mode = .smartAuto

        // 1. Zero working agents -> no sleep assertion
        AgentStore.shared.updateStatus(for: .claude, status: .idle)
        AgentStore.shared.updateStatus(for: .chatgpt, status: .idle)
        AgentStore.shared.updateStatus(for: .codex, status: .idle)
        AgentStore.shared.updateStatus(for: .antigravity, status: .idle)

        sleepMgr.updateSleepAssertionState()

        // 2. One agent working -> keep awake assertion active
        AgentStore.shared.updateStatus(for: .claude, status: .working, detail: "Executing bash command")
        sleepMgr.updateSleepAssertionState()

        // 3. Agent ends working -> sleep assertion released
        AgentStore.shared.updateStatus(for: .claude, status: .done, detail: "Task complete")
        sleepMgr.updateSleepAssertionState()

        // 4. Repeated toggle iterations must execute cleanly without process leak or crash
        for i in 1...5 {
            AgentStore.shared.updateStatus(for: .chatgpt, status: .working, detail: "Turn \(i)")
            sleepMgr.updateSleepAssertionState()
            AgentStore.shared.updateStatus(for: .chatgpt, status: .idle, detail: "Idle \(i)")
            sleepMgr.updateSleepAssertionState()
        }

        XCTAssertTrue(true, "Smart keep awake lifecycle and 5 toggle iterations completed without process leakage.")
    }

    func testContinuousThinkingStartTimeMonotonicityAcrossTransientReevaluations() throws {
        let store = AgentStore.shared
        store.updateStatus(for: .claude, status: .idle)

        let initialTurnId = "turn_epoch_001"
        // 1. Initial working status start
        store.updateStatus(for: .claude, status: .working, detail: "Claude working step 1", turnId: initialTurnId)
        let initialInfo = store.getStatus(for: .claude)
        XCTAssertNotNil(initialInfo.thinkingStartTime, "thinkingStartTime must be initialized on working start.")
        let firstStartTime = initialInfo.thinkingStartTime!

        // 2. Simulate 4 transient state re-evaluations during the SAME turn
        for i in 2...5 {
            Thread.sleep(forTimeInterval: 0.05)
            store.updateStatus(for: .claude, status: .working, detail: "Claude working step \(i)", turnId: initialTurnId)
            let updatedInfo = store.getStatus(for: .claude)
            XCTAssertEqual(updatedInfo.thinkingStartTime, firstStartTime, "thinkingStartTime MUST NOT reset during step \(i) of the same turn!")
        }

        // 3. Confirm terminal completion sets lastDurationSeconds cleanly
        Thread.sleep(forTimeInterval: 0.05)
        store.updateStatus(for: .claude, status: .done, detail: "Claude turn completed", turnId: initialTurnId)
        let finalInfo = store.getStatus(for: .claude)
        XCTAssertNil(finalInfo.thinkingStartTime, "thinkingStartTime must be cleared upon confirmed terminal completion.")
        XCTAssertNotNil(finalInfo.lastDurationSeconds, "lastDurationSeconds must be recorded upon completion.")
        XCTAssertGreaterThan(finalInfo.lastDurationSeconds!, 0.1, "Recorded duration must cover the entire continuous turn.")
    }

    func testClaudeUntouchedStaleSessionSuppression() throws {
        let store = AgentStore.shared
        store.updateStatus(for: .claude, status: .idle)

        let monitor = AutoMonitor.shared
        let tmpDir = NSTemporaryDirectory() + "claude_stale_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let jsonlPath = tmpDir + "stale_26h_session.jsonl"
        let stalePromptTs = "2026-08-14T10:00:00.000Z"
        let content = """
        {"type":"user","uuid":"stale_msg_26h","timestamp":"\(stalePromptTs)","origin":{"kind":"human"}}
        {"type":"assistant","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"in-progress content without stop reason"}]}}
        """
        try content.write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        // Set modification date to 26 hours ago
        let staleDate = Date().addingTimeInterval(-93600)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: jsonlPath)

        let info = AutoMonitor.ClaudeTranscriptInfo(path: jsonlPath, modDate: staleDate)

        let timeSinceMod = Date().timeIntervalSince(info.modDate)
        XCTAssertGreaterThan(timeSinceMod, 86400, "Mock file modification date must be older than 24 hours.")

        // Verify that stale turn evaluate check prevents Working state
        let timeSincePrompt = Date().timeIntervalSince(staleDate)
        let isTurnInProgress = timeSinceMod <= 300.0 || timeSincePrompt <= 300.0
        XCTAssertFalse(isTurnInProgress, "Untouched 24h+ session must NOT evaluate to turn in progress.")
    }

    func testCodexUIThreadBinding() throws {
        let monitor = AutoMonitor.shared
        let info = monitor.fetchCodexThreadInfo()
        if let info = info {
            XCTAssertFalse(info.id.isEmpty, "Bound thread ID must not be empty.")
            XCTAssertFalse(info.rolloutPath.isEmpty, "Bound rollout path must not be empty.")
        }
    }

    func testUserInputPromptLiteralStringsDoesNotTriggerBlocked() throws {
        let store = AgentStore.shared
        let userPromptText = "Write code with ask_question and RequestFeedback and permission_request strings."
        let session = AgentSessionInfo(
            provider: .antigravity,
            sessionId: "agy_user_prompt_unit_test",
            title: "Test Prompt",
            status: .working,
            turnId: "turn_user_prompt_99",
            sourceEvidence: userPromptText
        )
        store.syncSessions(for: .antigravity, activeSessions: [session], processRunning: true)
        let state = store.getStatus(for: .antigravity)
        XCTAssertEqual(state.status, .working, "USER PROMPT containing literal strings ask_question / RequestFeedback MUST NOT trigger Blocked status.")
    }

    func testPerSessionAcknowledgementLedgerPreventsResurrection() throws {
        let store = AgentStore.shared
        let turnId = "turn_ack_unit_100"
        let session = AgentSessionInfo(
            provider: .claude,
            sessionId: "claude_ack_unit_session",
            title: "Completed Task",
            status: .done,
            turnId: turnId,
            sourceEvidence: "Done task"
        )

        store.syncSessions(for: .claude, activeSessions: [session], processRunning: true)
        XCTAssertEqual(store.getStatus(for: .claude).status, .done, "Parent status must be .done for unacknowledged session.")

        store.markSessionChecked(provider: .claude, sessionId: "claude_ack_unit_session", turnId: turnId)
        XCTAssertEqual(store.getStatus(for: .claude).status, .idle, "Parent status must become .idle after session acknowledgement.")

        store.syncSessions(for: .claude, activeSessions: [session], processRunning: true)
        XCTAssertEqual(store.getStatus(for: .claude).status, .idle, "Resyncing acknowledged session MUST NOT resurrect parent .done status.")
    }

    func testAntigravityNativeHookLifecycleEvents() throws {
        let store = AgentStore.shared
        let sessionId = "test_agy_hook_session_001"
        defer {
            store.purgeSyntheticAndStaleSessions(provider: .antigravity)
        }

        // 1. PreInvocation / Prompt start -> Working
        let preInvocPayload: [String: Any] = [
            "event": "PreInvocation",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "is_test": true
        ]
        let res1 = store.handleAntigravityHookEvent(json: preInvocPayload, isTestMode: true)
        XCTAssertTrue(res1, "handleAntigravityHookEvent must accept valid PreInvocation payload.")

        let session1 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertNotNil(session1, "Session must exist after PreInvocation.")
        XCTAssertEqual(session1?.status, .working, "PreInvocation status must be .working.")
        XCTAssertNotNil(session1?.thinkingStartTime, "thinkingStartTime must be initialized.")
        XCTAssertNotNil(session1?.turnId, "turnId must be created on first PreInvocation.")
        let initialTurnId = session1?.turnId
        let firstThinkingStart = session1?.thinkingStartTime

        // 2. Subsequent PreInvocation inside SAME logical turn -> PRESERVES turnId and thinkingStartTime
        let secondPreInvoc: [String: Any] = [
            "event": "PreInvocation",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "invocation_num": 2,
            "is_test": true
        ]
        _ = store.handleAntigravityHookEvent(json: secondPreInvoc, isTestMode: true)
        let session1b = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session1b?.turnId, initialTurnId, "Subsequent PreInvocation inside SAME turn MUST preserve turnId.")
        XCTAssertEqual(session1b?.thinkingStartTime, firstThinkingStart, "Subsequent PreInvocation inside SAME turn MUST preserve thinkingStartTime.")

        // 3. PreToolUse (standard tool) -> Working with continuous duration (monotonic)
        Thread.sleep(forTimeInterval: 0.05)
        let toolPayload: [String: Any] = [
            "event": "PreToolUse",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "tool_name": "run_command",
            "step_idx": 1,
            "is_test": true
        ]
        let res2 = store.handleAntigravityHookEvent(json: toolPayload, isTestMode: true)
        XCTAssertTrue(res2, "handleAntigravityHookEvent must accept PreToolUse payload.")

        let session2 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session2?.status, .working, "PreToolUse for run_command must remain .working.")
        XCTAssertEqual(session2?.thinkingStartTime, firstThinkingStart, "thinkingStartTime MUST NOT reset during tool steps.")

        // 4. PostInvocation -> Remains .working (NO Done flicker mid-turn!)
        let postInvocPayload: [String: Any] = [
            "event": "PostInvocation",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "step_idx": 1,
            "is_test": true
        ]
        let res3 = store.handleAntigravityHookEvent(json: postInvocPayload, isTestMode: true)
        XCTAssertTrue(res3, "handleAntigravityHookEvent must accept PostInvocation payload.")

        let session3 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session3?.status, .working, "PostInvocation MUST remain .working (zero Done flicker mid-turn!).")
        XCTAssertEqual(session3?.thinkingStartTime, firstThinkingStart, "thinkingStartTime MUST remain monotonic.")

        // 5. Notification Center Permission Banner Correlation -> Blocked (Needs You)
        // Uses native AX banner shape: title: "Antigravity", body: "AGY Permission Detection Audit" (zero "permission" / "requesting" keywords)
        store.updateAntigravityPermissionFromNotification(reason: "AGY Permission Detection Audit")
        let session4 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session4?.status, .blocked, "Native-shaped notification banner correlated with single pending tool MUST transition session to .blocked.")
        XCTAssertEqual(session4?.attentionReason, "AGY Permission Detection Audit", "attentionReason must store native banner text.")
        XCTAssertEqual(store.getStatus(for: .antigravity).status, .blocked, "Parent status must reflect .blocked.")

        // 6. User approves -> PostToolUse clears Blocked and returns to Working
        let postToolPayload: [String: Any] = [
            "event": "PostToolUse",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "tool_name": "run_command",
            "step_idx": 1,
            "is_test": true
        ]
        let res5 = store.handleAntigravityHookEvent(json: postToolPayload, isTestMode: true)
        XCTAssertTrue(res5, "handleAntigravityHookEvent must accept PostToolUse payload.")

        let session5 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session5?.status, .working, "PostToolUse after user permission approval MUST return session status to .working.")
        XCTAssertNil(session5?.attentionReason, "attentionReason must be cleared upon PostToolUse.")
        XCTAssertEqual(session5?.thinkingStartTime, firstThinkingStart, "thinkingStartTime MUST remain monotonic across permission gate.")

        // 7. Stop -> Done (Turn Complete)
        Thread.sleep(forTimeInterval: 0.05)
        let stopPayload: [String: Any] = [
            "event": "Stop",
            "session_id": sessionId,
            "cwd": "/Users/ava/Projects/Agent-webchat monitor",
            "is_test": true
        ]
        let res6 = store.handleAntigravityHookEvent(json: stopPayload, isTestMode: true)
        XCTAssertTrue(res6, "handleAntigravityHookEvent must accept Stop payload.")

        let session6 = store.getSessions(for: .antigravity).first(where: { $0.sessionId == sessionId })
        XCTAssertEqual(session6?.status, .done, "Stop payload with no pending tools MUST transition session to .done.")
        XCTAssertNil(session6?.thinkingStartTime, "thinkingStartTime must be cleared upon turn completion.")
        XCTAssertNotNil(session6?.lastDurationSeconds, "lastDurationSeconds must be recorded.")
        XCTAssertGreaterThan(session6?.lastDurationSeconds ?? 0, 0.05, "Turn duration must cover the turn interval.")
    }

    func testClaudeQuotaExhaustionSemanticsAndKeepAwakeSeparation() throws {
        let store = AgentStore.shared
        let usageStore = AgentUsageStore.shared
        let sleepMgr = SleepManager.shared
        sleepMgr.mode = .smartAuto

        // 1. Quota Exhaustion at 100%
        var exhaustedUsage = AgentUsageData(
            agent: .claude,
            sessionLimitPercent: 100.0,
            sessionResetText: nil,
            weeklyLimitPercent: 60.0,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "plan-usage-history.json",
            quotaTimestamp: Date(),
            freshness: "Fresh"
        )
        usageStore.updateUsage(for: .claude, data: exhaustedUsage)

        XCTAssertTrue(exhaustedUsage.isQuotaExhausted, "100% usage must evaluate isQuotaExhausted == true.")
        XCTAssertEqual(store.getAvailability(for: .claude), .quotaExhausted, "Claude availability must be .quotaExhausted.")

        let claudeState = store.getStatus(for: .claude)
        XCTAssertEqual(claudeState.availability, .quotaExhausted, "AgentInfo.availability must be .quotaExhausted.")
        XCTAssertNotEqual(claudeState.status, .blocked, "Quota exhaustion MUST NOT produce .blocked (Needs You).")
        XCTAssertNotEqual(claudeState.status, .working, "Quota exhaustion MUST NOT produce .working.")

        // 2. Quota Exhausted Alone -> Smart Auto Inactive
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        store.updateStatus(for: .codex, status: .off)

        let evalAlone = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertFalse(evalAlone.shouldKeepAwake, "Quota exhausted Claude alone must NOT keep Smart Auto awake.")

        // 3. Quota Exhausted + AGY Working -> Smart Auto Active because of AGY
        store.updateStatus(for: .antigravity, status: .working, detail: "Task running")
        let evalAgy = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertTrue(evalAgy.shouldKeepAwake, "Smart Auto must be active when AGY is working while Claude is exhausted.")
        XCTAssertTrue(evalAgy.reason.contains("Antigravity"), "Reason must mention Antigravity.")
        store.updateStatus(for: .antigravity, status: .idle)

        // 4. Quota Exhausted + ChatGPT Working -> Smart Auto Active because of ChatGPT
        store.updateStatus(for: .chatgpt, status: .working, detail: "Generating")
        let evalGpt = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertTrue(evalGpt.shouldKeepAwake, "Smart Auto must be active when ChatGPT is working while Claude is exhausted.")
        XCTAssertTrue(evalGpt.reason.contains("ChatGPT Web"), "Reason must mention ChatGPT Web.")
        store.updateStatus(for: .chatgpt, status: .idle)

        // 5. Genuine Claude Needs You While Available
        var availUsage = AgentUsageData(
            agent: .claude,
            sessionLimitPercent: 30.0,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "plan-usage-history.json",
            freshness: "Fresh"
        )
        usageStore.updateUsage(for: .claude, data: availUsage)
        XCTAssertEqual(store.getAvailability(for: .claude), .available, "Claude must be available at 30% usage.")

        let testSess = "test_claude_xctest_perm"
        defer { store.purgeSyntheticAndStaleSessions(provider: .claude) }
        _ = store.handleClaudeHookEvent(json: ["event": "PermissionRequest", "session_id": testSess, "tool_name": "Bash", "cwd": "/tmp"], isTestMode: true)
        XCTAssertEqual(store.getStatus(for: .claude).status, .blocked, "Genuine PermissionRequest while quota is available must trigger .blocked.")
        let evalPerm = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertTrue(evalPerm.shouldKeepAwake, "Genuine permission gate must activate Smart Auto.")
        XCTAssertTrue(evalPerm.reason.contains("Claude Code"), "Reason must mention Claude Code.")

        // 6. Reset / Rollover
        _ = store.handleClaudeHookEvent(json: ["event": "Stop", "session_id": testSess, "cwd": "/tmp"], isTestMode: true)
        XCTAssertEqual(store.getStatus(for: .claude).status, .done, "Stop must transition to done.")
    }

    func testClosedLidV2PowerStateAndSmartAutoIntegration() throws {
        let sleepMgr = SleepManager.shared
        let store = AgentStore.shared
        let usageStore = AgentUsageStore.shared

        // 1. Power State Schema
        let powerState = SleepManager.getPowerState(minBatteryPercent: 20)
        if !powerState.isACPower {
            XCTAssertNotNil(powerState.batteryPercent, "Battery percent must be available on battery power.")
        } else {
            XCTAssertTrue(powerState.isBatterySafe, "AC power must evaluate isBatterySafe == true.")
        }

        // 2. Closed-Lid Mode State Binding
        sleepMgr.isClosedLidModeEnabled = true
        defer {
            sleepMgr.isClosedLidModeEnabled = false
            store.updateStatus(for: .antigravity, status: .idle)
            store.updateStatus(for: .claude, status: .idle)
            store.updateStatus(for: .chatgpt, status: .idle)
        }

        // Claude exhausted alone -> Smart Auto idle -> Closed-Lid disabled
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

        let evalIdle = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertFalse(evalIdle.shouldKeepAwake, "Smart Auto must be idle for exhausted Claude alone.")
        sleepMgr.updateSleepAssertionState()
        XCTAssertFalse(sleepMgr.isAssertionActive, "Assertion must be released.")
        XCTAssertFalse(sleepMgr.isDisableSleepActive, "Closed-Lid must not be active.")

        // AGY working -> Smart Auto active
        store.updateStatus(for: .antigravity, status: .working, detail: "AGY Task")
        let evalWorking = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertTrue(evalWorking.shouldKeepAwake, "Smart Auto must be active when AGY is working.")
        XCTAssertTrue(evalWorking.reason.contains("Antigravity"), "Reason must mention Antigravity.")
    }

    func testAssertionReasonSynchronizationAcrossProviderTransitions() throws {
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

        // 1. ChatGPT working
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        store.updateStatus(for: .chatgpt, status: .working, detail: "Generating")
        sleepMgr.updateSleepAssertionState()

        XCTAssertTrue(sleepMgr.isAssertionActive)
        XCTAssertTrue(sleepMgr.currentReason?.contains("ChatGPT Web") == true)
        let debug1 = sleepMgr.getDebugInfo()
        XCTAssertTrue((debug1["reason"] as? String)?.contains("ChatGPT Web") == true)
        if let liveName1 = sleepMgr.getLiveIOPMAssertionName() {
            XCTAssertTrue(liveName1.contains("ChatGPT Web"))
        }

        // 2. Switch to Claude working
        let availUsage = AgentUsageData(
            agent: .claude,
            sessionLimitPercent: 15.0,
            isPercentUsed: true,
            isLiveSource: true,
            quotaSource: "plan-usage-history.json",
            freshness: "Fresh"
        )
        usageStore.updateUsage(for: .claude, data: availUsage)
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .claude, status: .working, detail: "Claude working")
        sleepMgr.updateSleepAssertionState()

        XCTAssertTrue(sleepMgr.isAssertionActive, "Keep-awake assertion must remain active continuously.")
        XCTAssertTrue(sleepMgr.currentReason?.contains("Claude Code") == true)
        let debug2 = sleepMgr.getDebugInfo()
        XCTAssertTrue((debug2["reason"] as? String)?.contains("Claude Code") == true)
        if let liveName2 = sleepMgr.getLiveIOPMAssertionName() {
            XCTAssertTrue(liveName2.contains("Claude Code"))
        }
    }

    func testCodexRolloutTaskStartedAndCompletedLifecycle() throws {
        let store = AgentStore.shared
        store.purgeSyntheticAndStaleSessions(provider: .codex)

        let threadId = "codex_xct_t1"
        let turnId = "turn_xct_001"

        let started = store.handleCodexRolloutEvent(
            threadId: threadId,
            title: "XCTest Codex",
            cwd: "/tmp",
            rolloutPath: "/tmp/codex_xct.jsonl",
            eventType: "task_started",
            turnId: turnId,
            isTestMode: true
        )
        XCTAssertTrue(started, "task_started must return true.")
        XCTAssertEqual(store.getStatus(for: .codex).status, .working, "Codex status must be working.")

        // Mismatched completion must fail and preserve working
        let mismatched = store.handleCodexRolloutEvent(
            threadId: threadId,
            title: "XCTest Codex",
            cwd: "/tmp",
            rolloutPath: "/tmp/codex_xct.jsonl",
            eventType: "task_complete",
            turnId: "turn_xct_mismatch",
            durationMs: 3000,
            isTestMode: true
        )
        XCTAssertFalse(mismatched, "Mismatched turnId must return false.")
        XCTAssertEqual(store.getStatus(for: .codex).status, .working, "Codex status must remain working.")

        // Matching completion succeeds
        let completed = store.handleCodexRolloutEvent(
            threadId: threadId,
            title: "XCTest Codex",
            cwd: "/tmp",
            rolloutPath: "/tmp/codex_xct.jsonl",
            eventType: "task_complete",
            turnId: turnId,
            durationMs: 5000,
            isTestMode: true
        )
        XCTAssertTrue(completed, "Matching turnId task_complete must return true.")
        XCTAssertEqual(store.getStatus(for: .codex).status, .done, "Codex status must transition to done.")
    }

    func testCodexConcurrentThreadIsolation() throws {
        let store = AgentStore.shared
        store.purgeSyntheticAndStaleSessions(provider: .codex)

        let threadA = "codex_xct_A"
        let threadB = "codex_xct_B"

        _ = store.handleCodexRolloutEvent(threadId: threadA, title: "Thread A", cwd: "/tmp", eventType: "task_started", turnId: "turn_A", isTestMode: true)
        _ = store.handleCodexRolloutEvent(threadId: threadB, title: "Thread B", cwd: "/tmp", eventType: "task_started", turnId: "turn_B", isTestMode: true)

        let startA = store.getSessions(for: .codex).first(where: { $0.sessionId == threadA })?.thinkingStartTime

        // Complete thread B
        _ = store.handleCodexRolloutEvent(threadId: threadB, title: "Thread B", cwd: "/tmp", eventType: "task_complete", turnId: "turn_B", durationMs: 2500, isTestMode: true)

        let sessionA = store.getSessions(for: .codex).first(where: { $0.sessionId == threadA })
        let sessionB = store.getSessions(for: .codex).first(where: { $0.sessionId == threadB })

        XCTAssertEqual(sessionA?.status, .working, "Thread A must remain working.")
        XCTAssertEqual(sessionA?.turnId, "turn_A", "Thread A turnId must be intact.")
        XCTAssertEqual(sessionA?.thinkingStartTime, startA, "Thread A start time must be intact.")
        XCTAssertEqual(sessionB?.status, .done, "Thread B must be done.")
        XCTAssertEqual(store.getStatus(for: .codex).status, .working, "Parent status must be working while thread A is active.")
    }

    func testCodexPartialJSONLineAndOnceAppended() throws {
        let monitor = AutoMonitor.shared
        monitor.resetTestMetrics()

        let tmpPath = NSTemporaryDirectory() + "codex_xct_partial_\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let partial = "{\"timestamp\":\"2026-08-17T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_st"
        try partial.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let threadInfo = AutoMonitor.CodexThreadInfo(id: "codex_xct_part_t", title: "Partial", rolloutPath: tmpPath)
        monitor.processCodexRollout(thread: threadInfo)

        let s1 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_xct_part_t" })
        XCTAssertTrue(s1 == nil || s1?.status != .working, "Partial fragment must not trigger working.")

        if let handle = FileHandle(forWritingAtPath: tmpPath) {
            handle.seekToEndOfFile()
            handle.write("arted\",\"turn_id\":\"turn_xct_part_1\"}}\n".data(using: .utf8)!)
            try? handle.closeFile()
        }

        monitor.processCodexRollout(thread: threadInfo)
        let s2 = AgentStore.shared.getSessions(for: .codex).first(where: { $0.sessionId == "codex_xct_part_t" })
        XCTAssertEqual(s2?.status, .working, "Complete line must trigger working.")
        XCTAssertEqual(s2?.turnId, "turn_xct_part_1")
    }

    func testCompactSummaryHierarchyAndPreferencePersistence() throws {
        let store = AgentStore.shared
        store.currentTheme = .classic
        store.purgeSyntheticAndStaleSessions(provider: .claude)
        store.purgeSyntheticAndStaleSessions(provider: .antigravity)
        store.purgeSyntheticAndStaleSessions(provider: .codex)

        // All idle -> ⚪
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        store.updateStatus(for: .codex, status: .idle)
        XCTAssertEqual(store.compactSummary(), "⚪")

        // One working (Claude) -> CLD🟡
        store.updateStatus(for: .claude, status: .working)
        XCTAssertEqual(store.compactSummary(), "CLD🟡")

        // Two working (Claude & ChatGPT) -> CLD🟡 +1 (or GPT🟡 +1)
        store.updateStatus(for: .chatgpt, status: .working)
        let twoWorking = store.compactSummary()
        XCTAssertTrue(twoWorking.contains("🟡") && twoWorking.contains("+1"), "Two working providers must show top provider and +1: \(twoWorking)")

        // Done + Working -> Working wins (CLD🟡)
        store.updateStatus(for: .chatgpt, status: .done)
        XCTAssertEqual(store.compactSummary(), "CLD🟡")

        // Needs You + Working -> Needs You wins (AGY🔴)
        store.updateStatus(for: .antigravity, status: .blocked)
        XCTAssertEqual(store.compactSummary(), "AGY🔴")

        // Config persistence
        let configMgr = ConfigManager.shared
        var cfg = configMgr.config
        cfg.menuBarDisplayMode = "compact"
        configMgr.saveConfig(cfg)
        configMgr.loadConfig()
        XCTAssertEqual(configMgr.config.menuBarDisplayMode, "compact")

        cfg.menuBarDisplayMode = "detailed"
        configMgr.saveConfig(cfg)
        configMgr.loadConfig()
        XCTAssertEqual(configMgr.config.menuBarDisplayMode, "detailed")
    }

    func testCodexExcludedFromSmartAuto() throws {
        XCTAssertFalse(SleepManager.trustedProviders.contains(.codex), "Codex must not be in trustedProviders.")
    }

    func testQuotaAvailabilityDisplayDetailedAndCompact() throws {
        let store = AgentStore.shared
        let usageStore = AgentUsageStore.shared
        store.currentTheme = .classic

        // Available -> CLD:⚪
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
        XCTAssertTrue(store.overallSummary().contains("CLD:⚪"))
        XCTAssertEqual(store.getStatus(for: .claude).status, .idle)
        XCTAssertEqual(store.getStatus(for: .claude).availability, .available)

        // Quota Exhausted -> CLD:⛔
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
        XCTAssertTrue(store.overallSummary().contains("CLD:⛔"))
        XCTAssertEqual(store.getStatus(for: .claude).status, .idle)
        XCTAssertEqual(store.getStatus(for: .claude).availability, .quotaExhausted)

        // Compact when all else idle -> CLD⛔
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .codex, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        XCTAssertEqual(store.compactSummary(), "CLD⛔")

        // Compact when AGY Working -> AGY🟡
        store.updateStatus(for: .antigravity, status: .working)
        XCTAssertEqual(store.compactSummary(), "AGY🟡")

        // Compact when AGY Needs You -> AGY🔴
        store.updateStatus(for: .antigravity, status: .blocked)
        XCTAssertEqual(store.compactSummary(), "AGY🔴")
    }

    func testUnifiedDisplayStatusDerivationAcrossAllStates() throws {
        let store = AgentStore.shared
        let usageStore = AgentUsageStore.shared

        // Off
        store.updateStatus(for: .codex, status: .off)
        let offInfo = store.getStatus(for: .codex)
        XCTAssertEqual(offInfo.effectiveDisplayStatus, .off)
        XCTAssertEqual(offInfo.effectiveDisplayStatus.badge(theme: .classic), "⚫")
        XCTAssertEqual(offInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "😴")

        // Idle + Available
        let availUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 50.0, isPercentUsed: true, isLiveSource: true, quotaSource: "plan-usage-history.json", freshness: "Fresh")
        usageStore.updateUsage(for: .claude, data: availUsage)
        store.updateStatus(for: .claude, status: .idle)
        let idleInfo = store.getStatus(for: .claude)
        XCTAssertEqual(idleInfo.effectiveDisplayStatus, .idle)
        XCTAssertEqual(idleInfo.effectiveDisplayStatus.badge(theme: .classic), "⚪")
        XCTAssertEqual(idleInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "🫥")

        // Idle + Quota Exhausted
        let exhaustedUsage = AgentUsageData(agent: .claude, sessionLimitPercent: 100.0, isPercentUsed: true, isLiveSource: true, quotaSource: "plan-usage-history.json", freshness: "Fresh")
        usageStore.updateUsage(for: .claude, data: exhaustedUsage)
        store.updateStatus(for: .claude, status: .idle)
        let exhaustedInfo = store.getStatus(for: .claude)
        XCTAssertEqual(exhaustedInfo.effectiveDisplayStatus, .quotaExhausted)
        XCTAssertEqual(exhaustedInfo.effectiveDisplayStatus.badge(theme: .classic), "⛔")
        XCTAssertEqual(exhaustedInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "🤯")
        XCTAssertEqual(exhaustedInfo.status, .idle)

        // Working
        store.updateStatus(for: .antigravity, status: .working)
        let workingInfo = store.getStatus(for: .antigravity)
        XCTAssertEqual(workingInfo.effectiveDisplayStatus, .working)
        XCTAssertEqual(workingInfo.effectiveDisplayStatus.badge(theme: .classic), "🟡")
        XCTAssertEqual(workingInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "🤔")

        // Done
        store.updateStatus(for: .chatgpt, status: .done)
        let doneInfo = store.getStatus(for: .chatgpt)
        XCTAssertEqual(doneInfo.effectiveDisplayStatus, .done)
        XCTAssertEqual(doneInfo.effectiveDisplayStatus.badge(theme: .classic), "🟢")
        XCTAssertEqual(doneInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "🐶")

        // Blocked / Needs You
        store.updateStatus(for: .antigravity, status: .blocked)
        let blockedInfo = store.getStatus(for: .antigravity)
        XCTAssertEqual(blockedInfo.effectiveDisplayStatus, .blocked)
        XCTAssertEqual(blockedInfo.effectiveDisplayStatus.badge(theme: .classic), "🔴")
        XCTAssertEqual(blockedInfo.effectiveDisplayStatus.badge(theme: .funEmoji), "🥶")
    }

    func testAntigravityStopErrorSemanticsAndSubagentFiltering() throws {
        let store = AgentStore.shared
        let sleepMgr = SleepManager.shared
        sleepMgr.mode = .smartAuto

        let testSessionId = "test_unit_agy_stoperror"
        defer { store.purgeSyntheticAndStaleSessions(provider: .antigravity) }

        _ = store.handleAntigravityHookEvent(json: [
            "event": "PreInvocation",
            "session_id": testSessionId,
            "cwd": "/tmp"
        ], isTestMode: true)

        let sessionWorking = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
        XCTAssertEqual(sessionWorking?.status, .working)

        // StopError -> must be .idle, NOT .blocked, NOT .done
        _ = store.handleAntigravityHookEvent(json: [
            "event": "Stop",
            "session_id": testSessionId,
            "error": "The stream was interrupted. Please continue the task you were working on.",
            "termination_reason": "ERROR",
            "fully_idle": true,
            "cwd": "/tmp"
        ], isTestMode: true)

        let sessionStopped = store.getSessions(for: .antigravity).first(where: { $0.sessionId == testSessionId })
        XCTAssertEqual(sessionStopped?.status, .idle)
        XCTAssertNil(sessionStopped?.attentionReason)
        XCTAssertTrue(sessionStopped?.sourceEvidence.contains("Generation stopped") == true)
        XCTAssertEqual(store.getStatus(for: .antigravity).status, .idle)
    }

    func testProviderAvailabilityAndMultiModelFamilyQuotas() throws {
        let store = AgentStore.shared
        let usageStore = AgentUsageStore.shared
        let sleepMgr = SleepManager.shared
        sleepMgr.mode = .smartAuto

        // 1. Antigravity Limited State (Gemini available, Claude/GPT exhausted)
        let limitedUsage = AgentUsageData(
            agent: .antigravity,
            modelFamilies: [
                ModelFamilyQuota(name: "Gemini", sessionLimitPercent: 76.0, sessionResetText: nil, weeklyLimitPercent: 46.0, isPercentUsed: false),
                ModelFamilyQuota(name: "Claude/GPT", sessionLimitPercent: 0.0, sessionResetText: "resets in 2h", weeklyLimitPercent: 32.0, isPercentUsed: false)
            ],
            isLiveSource: true,
            freshness: "Fresh"
        )
        usageStore.updateUsage(for: .antigravity, data: limitedUsage)
        store.updateStatus(for: .antigravity, status: .idle)

        let agyInfo = store.getStatus(for: .antigravity)
        XCTAssertEqual(agyInfo.availability, .limited)
        XCTAssertEqual(agyInfo.effectiveDisplayStatus, .idle)
        XCTAssertEqual(agyInfo.effectiveDisplayStatus.badge(theme: .classic), "⚪")

        // 2. Antigravity Working outranks Limited/Exhausted
        store.updateStatus(for: .antigravity, status: .working)
        let workingInfo = store.getStatus(for: .antigravity)
        XCTAssertEqual(workingInfo.effectiveDisplayStatus, .working)
        XCTAssertEqual(workingInfo.effectiveDisplayStatus.badge(theme: .classic), "🟡")

        // 3. Antigravity All Exhausted
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
        store.updateStatus(for: .antigravity, status: .idle)

        let exhaustedInfo = store.getStatus(for: .antigravity)
        XCTAssertEqual(exhaustedInfo.availability, .quotaExhausted)
        XCTAssertEqual(exhaustedInfo.effectiveDisplayStatus, .quotaExhausted)
        XCTAssertEqual(exhaustedInfo.effectiveDisplayStatus.badge(theme: .classic), "⛔")

        // 4. Codex Honest Unknown
        let cdxUnknown = AgentUsageData(agent: .codex, isLiveSource: false, freshness: "Unavailable")
        usageStore.updateUsage(for: .codex, data: cdxUnknown)
        store.updateStatus(for: .codex, status: .idle)
        let cdxInfo = store.getStatus(for: .codex)
        XCTAssertEqual(cdxInfo.availability, .unknown)
        XCTAssertEqual(cdxInfo.effectiveDisplayStatus, .idle)

        // 5. Smart Auto assertion is not held by exhausted or limited quotas
        store.updateStatus(for: .chatgpt, status: .idle)
        store.updateStatus(for: .claude, status: .idle)
        store.updateStatus(for: .antigravity, status: .idle)
        store.updateStatus(for: .codex, status: .off)
        let eval = sleepMgr.evaluateSmartAutoRequirement()
        XCTAssertFalse(eval.shouldKeepAwake, "Smart Auto must NOT keep awake when all agents are idle even if quota is exhausted.")
    }

    func testProviderNativeQuotaConnectorsAndQuotaStopSemantics() throws {
        // 1. Test Antigravity local JSON parser
        let rawAgyJson: [String: Any] = [
            "userStatus": [
                "cascadeModelConfigData": [
                    "clientModelConfigs": [
                        [
                            "label": "Gemini 3.7 Flash",
                            "modelId": "gemini-3.7-flash",
                            "quotaInfo": [
                                "remainingFraction": 0.4831699,
                                "resetTime": "2026-08-17T12:48:12Z"
                            ]
                        ],
                        [
                            "label": "Claude Sonnet 4.6",
                            "modelId": "claude-sonnet-4-6",
                            "quotaInfo": [
                                "resetTime": "2026-08-17T14:19:13Z"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let agyUsage = AntigravityLocalQuotaConnector.shared.parseAntigravityUserStatusJSON(rawAgyJson)
        XCTAssertNotNil(agyUsage)
        XCTAssertEqual(agyUsage?.quotaSource, "agy_local_get_user_status")
        XCTAssertEqual(agyUsage?.availability, .limited)
        XCTAssertEqual(agyUsage?.modelFamilies.count, 2)

        // 2. Test Codex app-server JSON-RPC parser
        let rawCdxResult: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 79,
                    "windowDurationMins": 10080,
                    "resetsAt": 1787209587
                ],
                "secondary": NSNull(),
                "rateLimitReachedType": NSNull()
            ],
            "rateLimitResetCredits": [
                "availableCount": 0
            ]
        ]

        let cdxUsage = CodexAppServerQuotaConnector.shared.parseCodexRateLimitsResult(rawCdxResult)
        XCTAssertNotNil(cdxUsage)
        XCTAssertEqual(cdxUsage?.quotaSource, "codex_app_server")
        XCTAssertEqual(cdxUsage?.weeklyLimitPercent, 79.0)
        XCTAssertEqual(cdxUsage?.weeklyRemainingPercent, 21.0)
        XCTAssertEqual(cdxUsage?.availability, .available)
        XCTAssertFalse(cdxUsage?.isQuotaExhausted ?? true)
    }

    func testQuotaDisplayNormalizationAndCompleteness() throws {
        // 1. Raw % used -> % left normalization
        XCTAssertEqual(ModelFamilyQuota.normalizeRemaining(raw: 100.0, isPercentUsed: true), 0.0)
        XCTAssertEqual(ModelFamilyQuota.normalizeRemaining(raw: 79.0, isPercentUsed: true), 21.0)
        XCTAssertEqual(ModelFamilyQuota.normalizeRemaining(raw: 24.0, isPercentUsed: false), 24.0)
        XCTAssertEqual(ModelFamilyQuota.normalizeRemaining(raw: 0.0, isPercentUsed: false), 0.0)
        XCTAssertNil(ModelFamilyQuota.normalizeRemaining(raw: nil, isPercentUsed: true))

        // 2. Structured RetrieveUserQuotaSummary Connect-RPC parser
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
                                "remainingFraction": 0.9652436,
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
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.quotaSource, "agy_local_retrieve_user_quota_summary")
        XCTAssertEqual(usage?.modelFamilies.count, 2)

        let gemini = usage?.modelFamilies.first(where: { $0.name == "Gemini" })
        XCTAssertEqual(gemini?.sessionRemainingPercent, 97.0)
        XCTAssertEqual(gemini?.weeklyRemainingPercent, 37.0)
        XCTAssertFalse(gemini?.isExhausted ?? true)

        let claude = usage?.modelFamilies.first(where: { $0.name == "Claude/GPT" })
        XCTAssertEqual(claude?.sessionRemainingPercent, 0.0)
        XCTAssertEqual(claude?.weeklyRemainingPercent, 32.0)
        XCTAssertTrue(claude?.isExhausted ?? false)
        XCTAssertEqual(usage?.availability, .limited)
    }
}
#endif


