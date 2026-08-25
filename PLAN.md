# Agent Signal Bar (macOS Status Monitor) Plan & Product Roadmap

## North Star
`Run multiple AI agents, walk away, and only come back when something actually needs you.`

## Primary SLA
* Needs You ≤ 30s
* Finished ≤ 30s

---

## Milestone 2 (M2) — Release Candidate Seal Status

### HUMAN ACCEPTED
- [x] **ChatGPT**: Exact Chrome return routing (`[x] Ava accepted`: exact Chrome tabId activation without opening new tabs/windows)
- [x] **ChatGPT Monitor Health**: Automatic disconnect lease detection & clean recovery (`[x] Ava accepted`: 60s lease expiration warned on extension disable, recovered within seconds on re-enable)
- [x] **Claude Lifecycle**: Provider-native lifecycle hooks & multi-turn continuity (`[x] Ava accepted`: real-use accepted)
- [x] **Claude Quota Semantics & 100% Exhausted UI**: Provider availability decoupled from turn lifecycle, zero fake reset-time guessing, reset timestamp caching & plan-usage preservation (`[x] Ava accepted`: real-use 100% 5-hour quota exhaustion observed, verified unified `⛔` badge, truthful 100% display, and clean lifecycle isolation)
- [x] **Closed-Lid V2 Smart Auto Keep-Awake**: Privileged `pmset disablesleep 1`/`0` integration under Smart Auto policy, battery floor safety (<20%), automatic restoration upon work completion (`[x] Ava accepted`: verified real 4-minute closed-lid continuous execution and automatic clean restoration to `SleepDisabled 0`; crash recovery automated verified)
- [x] **Unified Display Status & Menu Bar Modes**: Shared `EffectiveDisplayStatus` derivation across Detailed (default) and Compact/Fun with ` | ` separator between groups (`[x] Ava accepted`: visual polish frozen)
- [x] **Provider Close Lifecycle Truth**: Application close transitions to `.off`, zero false Done/Telegram notifications emitted (`[x] Ava accepted`)
- [x] **Telegram Alerts Root Menu Placement**: First-level root menu toggle directly below Smart Keep-Awake and above Settings (`[x] Ava accepted`)

### IMPLEMENTED + AUTOMATED VERIFIED
- [x] **Five-Provider Smart Auto Keep-Awake**: ChatGPT Web, Claude Code, Antigravity, Codex Desktop, GitHub Copilot participate in Smart Auto; disconnected providers are strictly excluded from sleep assertions.
- [x] **One-Shot Auto-Switch**: Turn-aware and session-aware window focus when ready without arming cross-provider races.
- [x] **Rate-Limit Semantic Repair**: StopFailure handling, quota recovery reconciliation, and rate limit backoff.
- [x] **Telegram Bridge v1**: Outbound Done / Needs You push alerts with strict privacy sanitization (no prompts, body texts, cwd paths, or private URLs in messages); inbound `/status`, `/quota`, `/sessions`, `/help` command router.
- [x] **Codex Current Version Lifecycle Tracking**:
  - Active session discovery directly from `~/.codex/state_5.sqlite` threads ordered by `updated_at_ms DESC`.
  - User-facing session title resolution via `~/.codex/sqlite/codex-dev.db` `local_thread_catalog.display_title`.
  - Rollout parser honoring authoritative `task_started` / `task_complete` turn boundaries.
  - Subagent filtering (`thread_source != 'subagent'`).
  - `token_count` metrics isolation and trailing event regression prevention.
  - Explicit `.disconnected` monitor health degradation on database corruption/inaccessibility.
- [x] **Monitored Agents & Usage Dashboard**: Per-provider toggle in UI, truthful unavailable quota reporting for non-persisted disk sources.

### PENDING HUMAN (Non-Blocking)
- [ ] **Codex Current-Version Lifecycle Natural Spot-Check**: Await natural human usage of Codex Desktop. (`RECORDED: PENDING NATURAL HUMAN ACCEPTANCE`)
- [ ] **Auto-Switch Final Natural Human Spot-Check**: Natural multi-agent turn focus switch observation.
- [ ] **Codex-Only Smart Auto Natural Spot-Check**: Natural spot-check of Codex keep-awake release.

### PARKED NATURAL EVENT
- [ ] **Claude Quota Exhaustion → Recovery**: Natural live cycle transition observation.
- [ ] **Claude Re-Login → Needs You**: Natural token expiration modal observation.

### EXTERNAL / PARKED
- [ ] **Copilot Authorization-Dependent Lifecycle Acceptance**: Parked pending active GitHub Copilot entitlement.

### WATCH ONLY
- [ ] **Copilot Telegram Duplicate Done**: Only reopen if reproduced on latest accepted build.

---

### Milestone 2.1 (M2.1) — Identity, Notification UX & App Canonicalization (CLOSED)
- [x] **Final Product Naming**: AgentBridge (`/Applications/AgentBridge.app`)
- [x] **Main App Icon**: Native `diversity_2` icon integration in `.icns` bundle
- [x] **ChatGPT Webchat Monitor Extension**: `ecg_heart` Chrome extension icon and identity
- [x] **Canonical Status Badges**: Fixed canonical Emoji mapping with exact `😶🌫️` (`U+1F636 U+200D U+1F32B U+FE0F`) and Classic Traffic Light (`⛔` Quota Exhausted, `⚠️` Monitor Not Connected)
- [x] **Simplified Telegram Completion Alerts**: Default-all / persistent opt-out session completion model with Minimum Runtime threshold (Off, 1m, 3m, 5m, 10m, 15m)
- [x] **High-Priority Telegram Alerts**: Independent Needs You, Monitor/Network Health Drops/Restorations, and Quota Depletion/Restoration alerts
- [x] **Antigravity Permission Detection**: Provider-native permission prompt & input gate detection (`.blocked` Needs You)
- [x] **Stable Env Discovery**: Durable `~/.config/AgentSignalBar/.env` loading and zero-exposure migration
- [x] **Canonical App Cleanup**: Single `/Applications/AgentBridge.app` production installation with `.build/` staging and zero repo-root `.app` pollution

---

### Milestone 2.1.1 (M2.1.1) — Runtime Integrity & Lifecycle Authority (CLOSED)
- [x] **M2.1.1 Implementation: CLOSED**
- [x] **Automated Verification: ACCEPTED** (All 427 Swift tests, 30 JS tests, SPM test suite, and release packaging clean)
- [x] **P0-A: Telegram Test Runtime Isolation**: Hard defense-in-depth isolation in `TestEnvironment`, blocking real Telegram network requests in `URLSessionTelegramTransport` and preventing production `.env` loading during test executions (`Stage1TestRunner` & `swift test`).
- [x] **P0-B1: Codex Restart / Rollout Baseline Repair**: Tail baseline initialization for newly discovered rollout files on restart; full support for current observed event schema (`event_msg` with `item_completed`, `task_started`, `turn_started`, `response_item`); exclusion of historical replay from mutating lifecycle.
- [x] **P0-B2: Codex Working Lifecycle Continuity & Baseline Offset Repair**: Fixed transient query/reconciliation miss wiping active sessions; protected Working sessions from older completed turn downgrade; fixed dynamic new-thread baseline offset handling; concurrent subprocess stream draining preventing pipe buffer deadlocks.
- [x] **M2.1.1-A: Main-Thread Privilege Probing Removal**: Converted privilege probing to cached stored property with asynchronous background refreshes, eliminating synchronous `sudo / pmset` subprocess launches from `MenuBarManager` UI rendering.
- [x] **M2.1.1-B: Startup-Silent Health Notification Transitions**: Enforced strict `HealthAlertLifecycleState` transition model for Global Network Health and ChatGPT Web Monitor Health; startup baseline and re-baselining are silent; orphan "restored" alerts eliminated.
- [x] **M2.1.1-C: Antigravity Evidence-Driven Transcript Fallback**: Eliminated speculative wall-clock elapsed time heuristics (`timeSinceMod < 60s/120s`); lifecycle strictly mapped to explicit transcript step schema (`ask_question` / `WAITING_FOR_INPUT` -> Blocked; `RUNNING` / `IN_PROGRESS` / `USER_INPUT` / `GENERIC` / active tools -> Working; final `DONE` -> Done; insufficient evidence -> nil).

### Human Runtime Observations (PENDING / WATCH ONLY)
- [ ] **AgentBridge Not Responding Recurrence**: Monitor macOS Activity Monitor to ensure zero UI hangs.
- [ ] **Orphan Telegram "Restored" Recurrence**: Monitor Telegram alerts to ensure zero spurious restoration alerts on network reconnect / browser restart.
- [ ] **Antigravity >2 min Lifecycle Continuity**: Monitor long-running Antigravity turns to ensure continuous Working state across tool executions.

### Parked Natural Human Acceptance
- [ ] **Codex Natural Human Acceptance**: Parked pending natural human usage of Codex Desktop.

---

## Next Roadmap Milestones

### Milestone 3 (M3) — Project Bridge
- [x] **M3.1**: Local Folder Canonical Project Identity & Config Storage (`[x] Automated verified`: canonical project identity, path normalization, symlink resolution, durable atomic `~/.config/AgentSignalBar/projects.json` storage, longest-parent path matching, safe corruption recovery, test isolation)
- [ ] **M3.2**: One Current ChatGPT Reviewer per Project & Migration History (NEXT)
- [ ] **M3.3**: Agent Session Association by CWD / Workspace
- [ ] **M3.4**: Optional GitHub Repository Association
- [ ] **M3.5**: Project Switcher & Contextual Menu Navigation

### Milestone 4 (M4) — Telegram → AI Routing
- [ ] **Project-Aware Remote AI Routing**: Direct prompt/dispatch to active project context via Telegram after Project Bridge is established.
