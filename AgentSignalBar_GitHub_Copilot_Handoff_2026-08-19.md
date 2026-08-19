# AgentSignalBar — GitHub Copilot Handoff Document (2026-08-19)

Welcome, GitHub Copilot coding assistant! This document is your self-contained onboarding and reference manual for `AgentSignalBar`. You do not need previous chat history to continue this project.

---

## 1. Current Stable Checkpoint

* **Working Directory**: `/Users/ava/Projects/Agent-webchat monitor`
* **Repository**: `https://github.com/iknoest/Agent-webchat-monitor`
* **Branch**: `main`
* **Latest Commits**:
  * `80a617e`: `feat: copilot lifecycle repair, quota, one-shot switch, and canonical priority`
  * Next commit: `feat: claude session preservation, provider icons in fun mode, settings flattening, and clean handoff`
* **Automated Verification Status**:
  * `swift run Stage1TestRunner`: **195 / 195 PASSED**
  * `swift test` (SPM package test suite): **PASSED (Exit 0)**
  * `node adapters/chrome-extension/background_test.js`: **28 / 28 PASSED**
  * `./build_app.sh` (Release Bundle Builder): **PASSED (`AgentSignalBar.app` created)**
  * `git diff --check`: **CLEAN (0 whitespace/formatting errors)**

---

## 2. Product Decisions & Architectural Invariants

### A. Lifecycle vs. Quota Separation
* **Lifecycle**: Real-time state of turns (`Working / thinking`, `Needs You`, `Done / New Output Ready`, `Idle`, `Off`). Measured via native hooks / event streams / Chrome Extension.
* **Quota**: Model usage percentages and reset timestamps (`5-hour`, `7-day`, `Chat % left`, `Reset timing`). Polled via structured OAuth / CLI / internal API endpoints independently from lifecycle.

### B. Smart Auto Anti-Sleep Trust Rules
* Only fully human-verified providers are allowed in `SleepManager.trustedProviders` (`.chatgpt`, `.claude`, `.antigravity`).
* **Codex Desktop** and **GitHub Copilot** remain EXCLUDED from `SleepManager.trustedProviders` until human acceptance.
* Closed-Lid keep-awake (`pmset disablesleep 1`) is enabled by default with battery safety guard (auto-sleep below 20% battery).

### C. Monitored Agents Selection (`Settings > Monitored Agents`)
* All detected providers default to monitored.
* Disabling a provider persists in `config.json` (`disabledAgents`).
* When disabled: stops lifecycle/quota polling, hides dropdown session rows, excludes from top menu summary, suppresses notifications/sounds, and cannot acquire anti-sleep assertions.

### D. Smart Keep-Awake Placement
* Promoted to the **first-level operational menu** directly above `Settings & Preferences...`.
* Settings menu is flattened: `Monitoring Behavior` submenu removed; `Overworking Threshold: <mins> min >` is placed directly under `Settings & Preferences...`.

### E. Auto-Switch When Ready Semantics
* User-facing label: `Auto-Switch When Ready` with native AppKit check state (`.on` / `.off`). Zero literal square/checkbox characters in title.
* Available for any active session with exact routing.
* Can be armed while `Idle` ("watch next turn") or `Working` ("watch current turn").
* Triggers window focus **exactly once** upon `Done` (New Output Ready) or `Blocked` (Needs You), and automatically disarms immediately.
* Can be manually unchecked/canceled. Unrelated session transitions never trigger it.

### F. Canonical Priority Resolver & Compact Mode
Canonical priority order for top priority action and Compact mode:
$$\text{Needs You (100)} > \text{unacknowledged Done (80)} > \text{Working (60)} > \text{Quota Restored (40)} > \text{Quota Exhausted (30)} > \text{Idle (20)} > \text{Closed (0)}$$
* Compact mode immediately surfaces newly completed output (`Done`) or actionable attention prompts (`Needs You`) above a still-working agent (e.g. `Claude Working + ChatGPT New Output` $\rightarrow$ surfaces `GPT🟢`).

### G. Provider Icons vs. Classic 3-Letter Tags
* **Fun / Emoji Mode**: Uses local monochrome/template assets in `agent-white-icon/` (ChatGPT, Claude, Codex, Antigravity, GitHub Copilot). Renders inline template icons (`[icon] 🐵`, `[icon] 🤔`, etc.) with macOS light/dark appearance tinting.
* **Classic Mode**: Retains 3-letter tags (`GPT:● CDX:● CLD:● AGY:● COP:●`).
* **Status Meaning & Color Legend**: Contains an `Agents & Icons:` section followed by status badge definitions.

### H. Removed Features (DO NOT REINTRODUCE)
* ❌ Relay feature
* ❌ Copy Output to Clipboard
* ❌ Global Sound Alerts master toggle (replaced by direct `Mute (No Sound)` option in sound pickers)
* ❌ Accessibility (AX) UI scraping for Claude quota (replaced by structured OAuth API / CLI)
* ❌ Fragile timeout / silence heuristics for lifecycle

---

## 3. Solved / Accepted Features

1. **Structured Claude OAuth Quota**: `GET https://api.anthropic.com/api/oauth/usage` with keychain token support. Fallbacks: `plan-usage-history.json` and bounded `claude /usage` CLI.
2. **GitHub Copilot Quota**: `GET https://api.github.com/copilot_internal/user` matching Ava's live UI (68.4% left = ~32% used, resets Sep 1 in ~13d).
3. **Antigravity Quota Exhaustion $\rightarrow$ Quota Restored**: Observed and human-accepted in live use. Quota recovery badge `🥱` supported.
4. **Smart Keep-Awake First-Level Menu**: Tested and human-accepted.

---

## 4. Current State of In-Progress / Unresolved Items

### A. Claude Code Lifecycle (Active Task $\rightarrow$ `0 tracked sessions` / `Idle`)
* **Symptom**: During a real Claude Code CLI task, AgentSignalBar reported Claude as `Idle` with `Claude Code running (0 tracked sessions)`.
* **Root Cause Discovered**: `checkClaudeLog()` in `AutoMonitor.swift` only checked GUI apps (`NSWorkspace.runningApplications`). When Claude was run from CLI in VS Code / Cursor / iTerm2 / Terminal / Ghostty without GUI Claude Desktop, `isAppRunning` evaluated to `false`, causing `checkClaudeLog()` to call `syncSessions(..., activeSessions: [], processRunning: false)` every 1.0s and wipe all active hook sessions!
* **Fix Applied**: `AutoMonitor.swift` updated to check terminal hosts and `hasActiveTrackedSessions`, preventing active session wipeout.
* **Next Action**: Perform a real-world smoke test with `claude` CLI in terminal to confirm session continuity.

### B. GitHub Copilot Lifecycle
* **Symptom**: Copilot previously remained stuck in `Working` >3m after task completion due to `hook.start` events.
* **Fix Applied**: Generic child tool hooks (`preToolUse`, `postToolUse`, `postToolUseFailure`) are ignored; `assistant.turn_end` / `agentStop` strictly transitions to `.done`; `session.shutdown` / `sessionEnd` transitions to `.idle`.
* **Verification**: Tests 166–171 and 176–178 pass cleanly.

---

## 5. Human Validation Status Matrix

| Feature | Automated Tests | Human QA Status | Notes |
|---|---|---|---|
| Claude OAuth Quota | ✅ Passed | **Accepted** | Accurate 5h & 7d reset windows |
| Copilot Quota API | ✅ Passed | **Accepted** | 100% matches Ava's GitHub Copilot Free UI |
| AGY Quota Recovery (`🥱`) | ✅ Passed | **Accepted** | Observed live upon quota restore |
| Smart Keep-Awake 1st-level | ✅ Passed | **Accepted** | Verified in menu bar |
| Monitored Agents Submenu | ✅ Passed | **Accepted** | Per-provider toggling & persistence |
| Provider Icons in Fun Mode | ✅ Passed | **Pending Human Review** | Template icons loaded from `agent-white-icon/` |
| Auto-Switch When Ready | ✅ Passed | **Pending Human Review** | Native check state, 1-shot trigger |
| Claude CLI Hook Continuity | ✅ Passed | **Pending Human Review** | Terminal host detection added |
| Copilot Turn End Detection | ✅ Passed | **Pending Human Review** | Hook filtering implemented |
| Codex Desktop Lifecycle | ✅ Passed | **Parked** | Keep parked until natural usage |

---

## 6. Key Source Files Map

```text
Sources/AgentSignalBar/
├── AgentState.swift                # Single source of truth, AgentStore, session models, canonical priority
├── AutoMonitor.swift               # Background file/process watcher, Claude/AGY/CDX/COP log hooks
├── MenuBarManager.swift            # Status item, AppKit menu builder, attributed title with icons
├── ProviderIconLoader.swift        # [NEW] Template icon loader for ChatGPT, Claude, Codex, AGY, Copilot
├── OneShotSwitchManager.swift      # [NEW] Auto-Switch When Ready 1-shot manager
├── ClaudeLocalQuotaConnector.swift # Structured Claude OAuth API / CLI quota parser
├── CopilotLocalQuotaConnector.swift# [NEW] Structured GitHub Copilot quota API parser
├── SleepManager.swift              # Smart Keep-Awake anti-sleep engine (IOPM + caffeinate + closed-lid)
├── WindowFocuser.swift             # macOS window switching via NSWorkspace & AppleScript
├── ConfigManager.swift             # AppConfig manager (~/.config/AgentSignalBar/config.json)
└── HTTPServer.swift                # Local HTTP server (port 18888) for Chrome extension & hooks
```

---

## 7. Next Action for GitHub Copilot

**Single First Task**:
Verify Claude Code CLI and GitHub Copilot live turn continuity with Ava in real use:
1. Run `open AgentSignalBar.app`.
2. Start a command in `claude` (CLI) and verify status switches to `🟡 Working` and does NOT drop to `0 tracked sessions`.
3. Test `Auto-Switch When Ready` on an active task to verify one-shot window focus upon task completion.

---

## 8. Communication Style with Ava

* **Language**: Traditional Chinese (繁體中文) for all conversation responses with Ava.
* **Code / Prompts**: English.
* **Review Format**: Concise, evidence-backed verdicts. Prioritize human runtime evidence over automated test pass claims.
