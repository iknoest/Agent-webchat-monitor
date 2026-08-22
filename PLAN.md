# Agent Signal Bar (macOS Status Monitor) Plan & Product Roadmap

## North Star
`Run multiple AI agents, walk away, and only come back when something actually needs you.`

## Primary SLA
* Needs You ≤ 30s
* Finished ≤ 30s

## Product Roadmap Status Summary

### DONE
- [x] **ChatGPT**: Exact-tab session detector & multi-tab state aggregation (`[x] Implemented & Verified`)
- [x] **Claude**: Provider-native lifecycle hooks (`[x] Implemented & Verified`)
- [x] **Antigravity**: Native hooks + Notification Center AX probe support Working (🟡) + Finished (🟢) + Needs-You (🔴) permission detection + Multi-Session Identity (`[x] Implemented & Verified`)
- [x] **Runtime resource containment**: Zero-leak event loops, bounded tail reading, and subprocess reaping (`[x] Implemented & Verified`)
- [x] **Watchdog protection**: Non-overlapping poll execution lock (`[x] Implemented & Verified`)
- [x] **Caffeinate orphan/lifecycle repair**: Ownership auditing and clean process termination (`[x] Implemented & Verified`)

### ACCEPTED
- [x] **ChatGPT**: Exact Chrome return routing (`[x] Ava accepted`: exact Chrome tabId activation without opening new tabs/windows)
- [x] **Claude Lifecycle**: Provider-native lifecycle hooks (`[x] Ava accepted`: real-use accepted)
- [x] **Claude Quota Semantics & 100% Exhausted UI**: Provider availability decoupled from turn lifecycle, zero fake reset-time guessing, Smart Auto keep-awake excluded when exhausted (`[x] Ava accepted`: real-use 100% 5-hour quota exhaustion observed, verified unified `⛔` badge, truthful 100% display, and clean lifecycle isolation)
- [x] **Closed-Lid V2 Smart Auto Keep-Awake**: Privileged `pmset disablesleep 1`/`0` integration under Smart Auto policy, battery floor safety (<20%), automatic restoration upon work completion (`[x] Ava accepted`: verified real 4-minute closed-lid continuous execution and automatic clean restoration to `SleepDisabled 0`; crash recovery automated verified)
- [x] **Unified Display Status & Menu Bar Modes**: Shared `EffectiveDisplayStatus` derivation across Detailed (default) and Compact (optional provider-aware), persistent user preference, and stable status item autosave name (`[x] Implemented & Verified`)
- [x] **Provider Availability & Quota v1**: Unified 4-case availability model (`available`, `limited`, `quotaExhausted`, `unknown`), multi-model family structure (`ModelFamilyQuota`), truthful unavailable reporting for unpersisted disk sources (Antigravity/Codex), Smart Auto keep-awake decoupling, and multi-model family dropdown dashboard (`[x] Implemented & Verified`)
- [x] **Menu Bar Visual Direction**: Compact/Fun provider rendering with ` | ` separator between groups (`[x] Ava accepted`: visual polish frozen)

### ACTIVE / HUMAN DAILY-USE EVIDENCE
- [x] **P0 Lifecycle State Reconciliation & HTTP Socket Teardown**: Fixed `NWConnection` state teardown, 5s fetch timeout protection, and OS process liveness reconciliation via `kill(pid, 0)`. Automated 206 tests passing; in daily real use.

### NEXT MILESTONE — Smart Auto Provider Completion
- [ ] **Smart Auto Full Provider Integration**:
  - **Target Smart Keep-Awake Provider Set**:
    1. ChatGPT Web
    2. Claude Code
    3. Antigravity
    4. Codex Desktop
    5. GitHub Copilot
  - **Rules**:
    - Codex and Copilot are not intended to remain permanently excluded.
    - No user-facing "trust promotion" controls needed.
    - When normal lifecycle evidence is sufficiently reliable without concrete runtime defects, integrate them directly into Smart Auto.
    - Monitored Agents remains authoritative: a disabled provider must never influence Smart Auto.
    - Quota remains strictly separated from lifecycle and must never activate Smart Auto by itself.

### SUBSEQUENT MILESTONE — Telegram Mobile Alerts (v1)
- [ ] **Telegram Mobile Push Notifications**:
  - **Scope**: Notification only (one-way push).
  - **Trigger Events**:
    - `🔴 Needs You`
    - `🟢 Done / New Output Ready`
    - Abnormal monitor / provider failure worth user attention
  - **SLA**: Target delivery $\le$ 30s.
  - **Suppression**: NO notifications for `Working` or `Idle`.
  - **Parked**: Remote task dispatch / remote agent commands remain parked for later.

### PARKED
- [ ] **Telegram Remote Task / Control**: Parked until mobile notification v1 is fully accepted.
- [ ] **Codex Desktop v1 Working/Done Lifecycle**: `IMPLEMENTED — HUMAN ACCEPTANCE PARKED` (Parent rollout watcher `task_started`/`task_complete` per-thread isolation implemented; human acceptance parked until quota availability around Aug 20; strictly excluded from Smart Auto `trustedProviders`)
- [ ] **AGY extended provider-task lifetime tracking**: Parked to prioritize reliable Needs You (🔴) permission detection
- [ ] **Relay**: Clean AI output relay enhancements
- [ ] **Desktop exact-session navigation**: Parked until native accessibility / URL schemes exist
- [ ] **Multi-agent autonomous turn orchestration**: Parked for future milestone
- [ ] **Quota Resume Orchestration** (`LEVEL 1 IMPLEMENTED / LEVEL 2-3 INVESTIGATION — P1`):
  - **Goal**: When a provider hits quota exhaustion, AgentSignalBar helps work continue after quota resets.
  - **Level 1 (`IMPLEMENTED — QUOTA RESTORATION AWARENESS`)**: Detect quota restoration (>0% left after exhaustion) and surface it to Ava via Fun theme 🥱 / Classic theme `[Quota Restored]` without acquiring keep-awake.
  - **Level 2 (`INVESTIGATION / P1 — NOT IMPLEMENTED`)**: Use provider-native auto-resume when officially available from provider CLI/app.
  - **Level 3 (`INVESTIGATION / P1 — NOT IMPLEMENTED`)**: For providers with stable CLI/session identity, investigate safe automatic resume of the exact interrupted session after quota restoration.
