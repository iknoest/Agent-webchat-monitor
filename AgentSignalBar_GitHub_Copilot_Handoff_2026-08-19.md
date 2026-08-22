# AgentSignalBar — Handoff Document (Updated 2026-08-22)

Welcome, coding assistant! This document is your self-contained onboarding and reference manual for `AgentSignalBar`. You do not need previous chat history to continue this project.

---

## 1. Current Stable Checkpoint

* **Working Directory**: `/Users/ava/Projects/Agent-webchat monitor`
* **Repository**: `https://github.com/iknoest/Agent-webchat-monitor`
* **Branch**: `fix/runtime-state-reconciliation`
* **Automated Verification Status**:
  * `swift run Stage1TestRunner`: **206 / 206 PASSED**
  * `swift test` (SPM package test suite): **PASSED (Exit 0)**
  * `node adapters/chrome-extension/background_test.js`: **28 / 28 PASSED**
  * `./build_app.sh` (Release Bundle Builder): **PASSED (`AgentSignalBar.app` created)**
  * `git diff --check`: **CLEAN (0 whitespace/formatting errors)**

---

## 2. Product Decisions & Architectural Invariants

### A. Lifecycle vs. Quota Separation
* **Lifecycle**: Real-time state of turns (`Working / thinking`, `Needs You`, `Done / New Output Ready`, `Idle`, `Off`). Measured via native hooks / event streams / Chrome Extension.
* **Quota**: Model usage percentages and reset timestamps (`5-hour`, `7-day`, `Chat % left`, `Reset timing`). Polled via structured OAuth / CLI / internal API endpoints independently from lifecycle.

### B. Smart Auto Anti-Sleep Rules
* Monitored Agents remains authoritative: a disabled provider must NEVER influence Smart Auto.
* Quota remains strictly separated from lifecycle and must never activate Smart Auto by itself.
* Closed-Lid keep-awake (`pmset disablesleep 1`) is enabled by default with battery safety guard (auto-sleep below 20% battery).

### C. Menu Bar Visual Polish (FROZEN)
* **Fun / Emoji Mode**: Uses local monochrome/template assets in `agent-white-icon/` (ChatGPT, Claude, Codex, Antigravity, GitHub Copilot). Renders template icons with ` | ` separator between provider groups (e.g. `[ChatGPTIcon 🐵 | CodexIcon 😴 | ClaudeIcon 🤔 | AGYIcon 😴 | CopilotIcon 🫥]`).
* **Classic Mode**: Retains 3-letter tags (`GPT:● CDX:● CLD:● AGY:● COP:●`).
* **Visual Polish is FROZEN**: Do not make further cosmetic changes unless a concrete usability defect appears.

### D. Auto-Switch When Ready Semantics
* User-facing label: `Auto-Switch When Ready` with native AppKit check state (`.on` / `.off`). Zero literal square/checkbox characters in title.
* Available for any active session with exact routing.
* Can be armed while `Idle` ("watch next turn") or `Working` ("watch current turn").
* Triggers window focus **exactly once** upon `Done` (New Output Ready) or `Blocked` (Needs You), and automatically disarms immediately.

### E. Canonical Priority Resolver & Compact Mode
Canonical priority order for top priority action and Compact mode:
$$\text{Needs You (100)} > \text{unacknowledged Done (80)} > \text{Working (60)} > \text{Quota Restored (40)} > \text{Quota Exhausted (30)} > \text{Idle (20)} > \text{Closed (0)}$$
* Compact mode immediately surfaces newly completed output (`Done`) or actionable attention prompts (`Needs You`) above a still-working agent.

---

## 3. Solved / Accepted Features

1. **Structured Claude OAuth Quota**: `GET https://api.anthropic.com/api/oauth/usage` with keychain token support. Fallbacks: `plan-usage-history.json` and bounded `claude /usage` CLI.
2. **GitHub Copilot Quota**: `GET https://api.github.com/copilot_internal/user` matching Ava's live UI (68.4% left = ~32% used, resets Sep 1 in ~13d).
3. **Antigravity Quota Exhaustion $\rightarrow$ Quota Restored**: Observed and human-accepted in live use (`🥱`).
4. **Smart Keep-Awake First-Level Menu**: Tested and human-accepted.
5. **Menu Bar Status Item Visibility**: Zero-width collapse bug fixed by preserving `attributedTitle` on `NSStatusBarButton`.
6. **P0 Lifecycle State Reconciliation & HTTP Socket Teardown**: Fixed `NWConnection` state teardown, 5s fetch timeout protection, and OS process liveness reconciliation via `kill(pid, 0)` without arbitrary timeouts.

---

## 4. Next Milestones & Roadmap

### NEXT MILESTONE — Smart Auto Provider Completion
* **Target Smart Keep-Awake Provider Set**:
  1. ChatGPT Web
  2. Claude Code
  3. Antigravity
  4. Codex Desktop
  5. GitHub Copilot
* **Rules**:
  - Codex and Copilot are not intended to remain permanently excluded.
  - Do NOT add user-facing "trust promotion" controls.
  - When their normal lifecycle evidence is sufficiently reliable without concrete runtime defects, integrate them directly into Smart Auto.
  - Only park a provider again if real runtime behavior proves unreliable.
  - Monitored Agents remains authoritative: a disabled provider must never influence Smart Auto.
  - Quota remains separate from lifecycle and must never activate Smart Auto by itself.

### SUBSEQUENT MILESTONE — Telegram Mobile Alerts (v1)
* **Scope**: Notification only (one-way push).
* **Trigger Events**:
  - `🔴 Needs You`
  - `🟢 Done / New Output Ready`
  - Abnormal monitor / provider failure worth user attention
* **SLA**: Target delivery $\le$ 30s.
* **Suppression**: NO notifications for `Working` or `Idle`.
* **Parked**: Remote task dispatch / remote agent commands remain parked for later.

### PARKED ITEMS
* ❌ Telegram remote task/control
* ❌ Quota Resume Orchestration (Levels 2-3)
* ❌ Codex Desktop deep rollout watcher (re-evaluate on natural usage)

---

## 5. Key Source Files Map

```text
Sources/AgentSignalBar/
├── AgentState.swift                # Single source of truth, AgentStore, session models, canonical priority
├── AutoMonitor.swift               # Background file/process watcher, Claude/AGY/CDX/COP log hooks & PID liveness
├── MenuBarManager.swift            # Status item, AppKit menu builder, attributed title with icons & | separator
├── ProviderIconLoader.swift        # Template icon loader for ChatGPT, Claude, Codex, AGY, Copilot
├── OneShotSwitchManager.swift      # Auto-Switch When Ready 1-shot manager
├── ClaudeLocalQuotaConnector.swift # Structured Claude OAuth API / CLI quota parser
├── CopilotLocalQuotaConnector.swift# Structured GitHub Copilot quota API parser
├── SleepManager.swift              # Smart Keep-Awake anti-sleep engine (IOPM + caffeinate + closed-lid)
├── WindowFocuser.swift             # macOS window switching via NSWorkspace & AppleScript
├── ConfigManager.swift             # AppConfig manager (~/.config/AgentSignalBar/config.json)
└── HTTPServer.swift                # Local HTTP server (port 18888) with robust connection state teardown
```

---

## 6. Communication Style with Ava

* **Language**: Traditional Chinese (繁體中文) for all conversation responses with Ava.
* **Code / Prompts**: English.
* **Review Format**: Concise, evidence-backed verdicts. Prioritize human runtime evidence over automated test pass claims.
