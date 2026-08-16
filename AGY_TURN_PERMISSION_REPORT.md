# Antigravity Turn Stability, State Identity & Permission Report

## Final Verdict

**AGY STATE IDENTITY CLEAN — READY FOR AVA REAL TEST**

---

## Executive Summary of Repairs

### 1. Duplicate Hook Scope Audit & Registration Cleanup
- **Audit Findings**: Antigravity was loading hook definitions from both global `~/.gemini/config/hooks.json` AND workspace `.agent/hooks.json`. Because Antigravity merges both scopes at runtime, every single hook invocation was delivered twice in rapid succession.
- **Resolution**:
  - Global `~/.gemini/config/hooks.json` established as the **single authoritative registration scope** for AgentSignalBar across all workspace projects on Ava's Mac.
  - Duplicate `agent-signalbar-monitor` configuration removed from workspace `.agent/hooks.json`.
  - Added 1.0s event fingerprint deduplication guard in `handleAntigravityHookEvent` in [`AgentState.swift`](file:///Users/ava/Projects/Agent-webchat%20monitor/Sources/AgentSignalBar/AgentState.swift) (`fingerprint = "\(sessionId):\(event):\(toolName):\(stepIdx):\(invocationNum)"`), guaranteeing event idempotency.

### 2. Logical `turnId` & `thinkingStartTime` Continuity
- **Defect**: Previously, `handleAntigravityHookEvent` generated a brand-new `turnId` on every `PreInvocation` event. Because multi-step turns contain multiple `PreInvocation` -> `PostInvocation` cycles, `turnId` was fluctuating mid-turn.
- **Resolution**:
  - First `PreInvocation` after `.idle` / `.done` / new user turn: Creates a fresh `turnId` and initializes `thinkingStartTime = now`.
  - Subsequent `PreInvocation` events while the session is already `.working`: **Preserve the SAME `turnId`** and **preserve `thinkingStartTime`**.
  - `Stop` / `StopFailure`: Concludes the turn, sets `.done` / `.blocked`, and records `lastDurationSeconds`.

### 3. Disambiguated Permission Notification Correlation
- **Defect**: `updateAntigravityPermissionFromNotification()` previously marked *every* session with `pendingToolTime <= 30s` as Blocked when a Notification Center banner arrived.
- **Resolution**:
  - **Single Candidate**: Binds permission block (`.blocked`) to that single unambiguous session.
  - **Multiple Candidates (Distinct Timing > 3s)**: Binds to the uniquely strongest candidate.
  - **Ambiguous Candidates (Timing <= 3s)**: Does **NOT** falsely mark multiple child sessions `.blocked`. Instead updates provider-level parent status to `"Antigravity Needs You — session unknown"`.
  - `PostToolUse` for any session clears its pending tool state and returns that session to `.working`.

---

## Test & Verification Matrix

| Test Suite | Coverage | Result |
| :--- | :--- | :--- |
| **`swift test`** | Unit tests for `turnId` continuity, non-flicker, idempotency | **PASSED** (exit 0) |
| **`Stage1TestRunner`** | 23 production logic & containment tests (including Test 23 multi-session & ambiguous correlation) | **23/23 PASSED** |
| **`background_test.js`** | 28 multi-tab JS sensor stress tests | **28/28 PASSED** |
| **App Release Build** | `AgentSignalBar.app` binary compilation | **SUCCESS** |

---

## Review Package Directory

Location: `/private/tmp/agent_signalbar_agy_turn_permission/`
Zip Archive: `/private/tmp/agent_signalbar_agy_turn_permission.zip`

**Package Files**:
1. `AGY_TURN_PERMISSION_REPORT.md` (Detailed closeout report)
2. `PLAN.md` & `LESSONS.md` (Updated product documentation & durable lessons)
3. `Sources/AgentSignalBar/AgentState.swift` & `AutoMonitor.swift` (Production sources)
4. `Tests/AgentSignalBarTests/AgentSignalBarTests.swift` & `Sources/Stage1TestRunner/main.swift` (Test suites)
5. `scripts/inspect_notification_center.swift` & `test_notification_detector.swift` (Probe scripts)
6. `agy_native_hook_trace.jsonl` (Native hook trace logs)
