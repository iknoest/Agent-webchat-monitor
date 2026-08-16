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
- [x] **Claude Quota Semantics**: Provider availability decoupled from turn lifecycle, zero fake reset-time guessing, Smart Auto keep-awake excluded when exhausted (`[x] Implementation Accepted`; 100% exhausted UI natural-event confirmation pending)
- [x] **Closed-Lid V2 Smart Auto Keep-Awake**: Privileged `pmset disablesleep 1`/`0` integration under Smart Auto policy, battery floor safety (<20%), automatic restoration upon work completion (`[x] Ava accepted`: verified real 4-minute closed-lid continuous execution and automatic clean restoration to `SleepDisabled 0`; crash recovery automated verified)

### TESTING / HUMAN ACCEPTANCE PENDING
- [ ] **Antigravity Permission**: Native hooks + AX notification center probe (`IMPLEMENTED — HUMAN ACCEPTANCE PENDING`)
- [ ] **Claude 100% Quota Exhausted UI**: Natural-event human confirmation pending next natural exhaustion
- [ ] **Claude Lifecycle**: Provider-native hooks undergoing final Ava real-use acceptance

### OPEN
- [ ] **Codex**: Codex Desktop session detector
- [ ] **Smart Keep-Awake**: Open-Lid validation across multi-agent active turns
- [ ] **Telegram mobile notification**: Remote attention push notifications
- [ ] **Quota tracking**: Live quota sources for Codex and Antigravity

### PARKED
- [ ] **AGY extended provider-task lifetime tracking**: Parked to prioritize reliable Needs You (🔴) permission detection
- [ ] **Relay**: Clean AI output relay enhancements
- [ ] **Desktop exact-session navigation**: Parked until native accessibility / URL schemes exist
- [ ] **Multi-agent autonomous turn orchestration**: Parked for future milestone
