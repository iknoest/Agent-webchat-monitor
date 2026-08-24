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

## Next Roadmap Milestones

### Milestone 2.1 (M2.1) — Identity & Notification UX
- [ ] **Final Product Naming**
- [ ] **Main App Icon**: `diversity_2` icon integration
- [ ] **ChatGPT Webchat Monitor Icon**: `ecg_heart` Chrome extension icon
- [ ] **Config-Driven Status Badges**: Customizable emoji mapping for monitor unavailable (`😶🌫️` default) and quota restored
- [ ] **Telegram Done Notification Threshold**: Configurable thinking duration minimum for Done alerts + per-session override

### Milestone 3 (M3) — Project Bridge
- [ ] **Local Folder Canonical Project Identity**
- [ ] **One Current ChatGPT Reviewer per Project**
- [ ] **Reviewer Migration History & Thread Pairing**
- [ ] **Agent Session Association by CWD / Workspace**
- [ ] **Optional GitHub Repository Association**
- [ ] **Project Switcher & Contextual Menu Navigation**

### Milestone 4 (M4) — Telegram → AI Routing
- [ ] **Project-Aware Remote AI Routing**: Direct prompt/dispatch to active project context via Telegram after Project Bridge is established.
