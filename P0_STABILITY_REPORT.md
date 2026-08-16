# AgentSignalBar — P0 Stability Recovery & Non-Regression Lock Report

## Overview
Ava rejected the previous P0 verdict from direct real use. This stabilization milestone establishes strict non-regression invariants in `AGENTS.md`, repairs 5 core defect areas (Per-session acknowledgement ledger, false Needs You elimination via structured event parsing, ChatGPT runtime detector singleton guard, Claude continuous turn stability, and honest desktop status UI), updates `PLAN.md` roadmap, and executes complete test suites.

## P0 Non-Regression Invariants (Institutionalized in AGENTS.md)
1. Ava direct real-use evidence overrides automated/self-reported PASS.
2. Never infer permission / Needs You from raw natural-language substring search. Control state must come from parsed structured event/tool-call fields.
3. Session discovery is not equivalent to active/open session truth.
4. Lifecycle status and user acknowledgement/read state are separate concepts.
5. Provider parent state is derived only from child-session state.
6. Chrome detector/runtime hooks must have exactly one live installation per page. Main-world fetch interception may not be repeatedly wrapped.
7. Simulated/injected AgentStore state is not live acceptance.
8. Extension source changes require extension reload + affected host-tab refresh.
9. PLAN.md P0 checkbox cannot be marked complete until Ava accepts the behavior.
10. Two repeated Ava regressions in the same area trigger architecture review, not another heuristic timer.

## Summary of Confirmed Defect Repairs

### A. Per-Session Acknowledgement Ledger
- Added `acknowledgedTurnId: String?` and `acknowledgedAt: Date?` fields and `isAcknowledged: Bool` helper to `AgentSessionInfo`.
- Added `markSessionChecked(provider: AgentID, sessionId: String, turnId: String?)` to `AgentStore`.
- Refactored `syncSessions`: incoming sessions preserve `acknowledgedTurnId` when `turnId` is unchanged and status is not `.working`. New turns (`.working` or new `turnId`) automatically clear acknowledgement.
- Parent provider status derivation only counts UNACKNOWLEDGED `.done` and UNACKNOWLEDGED `.blocked` sessions. An acknowledged session remains in underlying `.done`/`.blocked` state but does not cause the parent provider status to display `NEW OUTPUT` / `Done` / `Blocked` again.
- Clicking a specific session menu item or tab acknowledges ONLY that exact session/turn without clearing other sessions.

### B. False Needs You Elimination via Structured Event Parsing
- Removed all raw natural-language substring searching (`ask_question`, `RequestFeedback`, `waiting for confirmation`, `user_approval_required`, `permission_request`).
- Antigravity: `checkAntigravityLog()` parses JSON lines in turn slices. `hasAskQuestion` is set ONLY when a `PLANNER_RESPONSE` step contains a structured tool call named `ask_question` / `default_api:ask_question` or `ArtifactMetadata.RequestFeedback == true`. User prompt text (`USER_INPUT`) containing those literal strings does NOT trigger `.blocked`.
- Claude: `checkClaudeLog()` parses assistant JSON steps (`type == "assistant"`). Permission is flagged ONLY when an assistant `content` item is a `tool_use` call to `AskUserQuestion` / `ask_question` / `ask_user` or a `permission_request` / `tool-approval-request` type line. Removed raw text matching against `main.log`.
- Codex: Rollout JSON lines are parsed for structured permission event types.
- Added Swift automated regression tests asserting that `USER_INPUT` prompts containing `ask_question` / `RequestFeedback` / `permission_request` do NOT trigger `.blocked`.

### C. ChatGPT Runtime Detector Singleton & Sensor Diagnostics
- Added `if (window.__AgentSignalBarFetchIntercepted) return; window.__AgentSignalBarFetchIntercepted = true;` guard in `content.js` to guarantee `window.fetch` is wrapped EXACTLY ONCE in main world across reinjections.
- Passed raw sensor reason (`reason`) in `content.js` signals and recorded `lastReason` in `background.js` `tabRegistry`.
- Passed `sensorReason` in payload to Swift backend and exposed `sensorReason` in `/debug/state` HTTP response JSON.

### D. Claude Continuous Turn Stability
- Refined `checkClaudeLog()` turn completion evaluator.
- Tracked `hasToolUseInLastAssistantMessage`. If the last assistant message in a turn issued `tool_use` calls (e.g. `Bash`, `VIEW_FILE`), it is an intermediate tool boundary, NOT final completion. Status remains `.working`.
- Transition to `.done` occurs ONLY when the terminal assistant message has NO `tool_use` blocks, `pendingToolCalls.isEmpty`, `stop_reason == "end_turn"`, and `timeSinceMod >= 3.0`. This eliminates flickering between `Working` and `Done/Thinking` during multi-step tool turns.

### E. Honest Desktop Status UI
- Made desktop session UI honest: tracked desktop sessions in submenus are status entries. Clicking a desktop session focuses the provider application without claiming or implying exact internal session switching.
- Updated `PLAN.md` roadmap: `P0 Session-First State Model` marked `IMPLEMENTED / STABILIZATION OPEN / AVA NOT ACCEPTED` (unchecked `- [ ]`). `Exact desktop-session jump` marked `PARKED`.

## Verification Results
1. **Node.js JS Stress Suite** (`node adapters/chrome-extension/background_test.js`):
   - 28/28 tests PASSED (100% pass rate).
2. **Swift Stage 1 Test Runner** (`swift run Stage1TestRunner`):
   - 19/19 tests PASSED (100% pass rate). Includes regression test 17 (user prompt literal strings do not trigger Blocked), test 18 (genuine ask_question tool call triggers Blocked), and test 19 (per-session acknowledgement ledger prevents resurrection).
3. **SPM Package Unit Tests** (`swift test`):
   - 14/14 tests PASSED (100% pass rate).
4. **App Release Build** (`./build_app.sh`):
   - Swift release binary & `AgentSignalBar.app` bundle created cleanly (exit code 0).
5. **Production `/debug/state` HTTP Trace**:
   - `curl -s http://127.0.0.1:18888/debug/state` returned live JSON session state trace across active providers with `acknowledgedTurnId`, `isAcknowledged`, and `sensorReason`.

## Final Verdict

P0 STABILITY READY FOR AVA ACCEPTANCE
