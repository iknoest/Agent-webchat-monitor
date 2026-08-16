# Claude-Only Detector Recovery — Evaluation Report

**Target Workspace**: `/Users/ava/Projects/Agent-webchat monitor`  
**Date**: 2026-08-15  
**Final Verdict**: `CLAUDE DETECTOR BLOCKED — RELIABLE LIVE SESSION IDENTITY NOT FOUND`

---

## Executive Summary

As required by the directive, a rigorous evaluation of the Claude application architecture on macOS was conducted to establish whether the active Claude UI window/session can be reliably bound to its local session identity.

Because Electron webview rendering isolates the active conversation context, background CLI worker processes remain alive concurrently across multiple sessions, standard `claude.ai` cloud conversations create no local transcript files, and log tail parsing is an unreliable heuristic explicitly forbidden by the protocol ("Do not define active session as merely the most recently modified transcript"), **reliable live session identity binding cannot be established**.

Per explicit instruction (*"First establish how to reliably bind the current Claude UI/session to its local session identity. If that cannot be done reliably, stop and report CLAUDE DETECTOR BLOCKED rather than adding another heuristic"*), execution was stopped prior to adding unverified heuristics. 

In addition, the baseline UI wording was updated so that running providers whose monitoring is intentionally unavailable display `Monitoring unavailable / Experimental` rather than misleading `Idle`.

---

## 1. Live Session Identity Technical Evaluation

### A. Electron UI Sandbox Isolation (`com.anthropic.claudefordesktop`)
- **Accessibility Inspection**: The macOS Claude Desktop app is built on Electron. System Events / `AXAccessibility` exposes only top-level window titles (`"Claude"`). Individual tab titles, webview DOM elements, and internal URL states are sandboxed inside Chromium renderers and remain invisible to OS-level accessibility queries unless proprietary developer flags (`--force-renderer-accessibility`) are enabled.
- **Result**: AppleScript / `AXUIElement` cannot determine which session, conversation ID, or project is currently visible to the user.

### B. Multiple Background Subprocesses (`--resume=<session_id>`)
- **Process Inspection**: Local agent sessions in Claude Desktop spawn background worker processes (`/Applications/Claude.app/.../claude --resume=<session_id>`).
- **Empirical Observation**: Multiple background worker processes remain alive simultaneously long after turns complete (e.g. PID 9947 running session `9f32dc87-5f67-4bed...` and PID 2270 running session `7239c214-0b2c-490c...`).
- **Result**: Neither `ps aux`, process command-line arguments, open sockets (`/tmp/cc-socks/*.sock`), nor file handle locks indicate which session is actively focused in the UI vs running in the background vs dormant.

### C. Cloud Web Chats vs Local Agent Mode
- Standard conversations on `claude.ai` inside Claude Desktop run over HTTPS/WebSockets directly to Anthropic cloud servers.
- They create zero local `.jsonl` transcript files under `~/.claude/projects/` and spawn zero local `claude` worker processes.
- **Result**: Cloud web chats have no local session identity on disk.

### D. Log Tail & Heuristic Unreliability (`main.log`)
- `~/Library/Logs/Claude/main.log` logs `[CCD] LocalSessions.setFocusedSession: sessionId=local_...` transiently during UI click events for local CCD sessions.
- However:
  1. It misses app restarts, log rotation, and CLI sessions launched in Terminal.
  2. It logs `LocalSessions.setFocusedSession: sessionId=null` when focusing non-CCD tabs.
  3. Tail reading log files is an un-indexed append-only heuristic that fails when logs roll over or are truncated.

### E. Explicit Rule Compliance
- Requirement: *"Do not define active session as merely the most recently modified transcript."*
- Requirement: *"First establish how to reliably bind the current Claude UI/session to its local session identity. If that cannot be done reliably, stop and report CLAUDE DETECTOR BLOCKED rather than adding another heuristic."*
- **Conclusion**: Attempting to bind sessions without an authoritative OS/API binding mechanism breaks the strict requirement. Reporting `CLAUDE DETECTOR BLOCKED — RELIABLE LIVE SESSION IDENTITY NOT FOUND` is the only compliant outcome.

---

## 2. Baseline UI Wording Fix

To prevent user confusion while provider monitoring is intentionally disabled:
- Updated `AutoMonitor.swift` (`checkClaudeLog()`, `checkAntigravityLog()`, `checkCodexLogAndProcess()`) to pass `detail: "Monitoring unavailable / Experimental"`.
- Updated `AgentState.swift` (`syncSessions` & `recalculateParentStatus`) to preserve `"Monitoring unavailable / Experimental"` detail text when session list is empty.
- Updated `MenuBarManager.swift` to format status labels for running providers with intentionally disabled monitoring as `[Monitoring unavailable / Experimental]` instead of misleading `[Idle]`.

---

## 3. Verification & Test Suite Execution

### Automated Tests
- **JS Extension Suite**: `node adapters/chrome-extension/background_test.js` (28/28 tests passed).
- **Swift Stage 1 Containment Suite**: `swift run Stage1TestRunner` (19/19 tests passed).
- **Release Compilation**: `swift build -c release` & `./build_app.sh` (Clean build, exit 0).

---

## 4. Final Verdict

```
CLAUDE DETECTOR BLOCKED — RELIABLE LIVE SESSION IDENTITY NOT FOUND
```
