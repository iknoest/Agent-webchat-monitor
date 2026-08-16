<!-- permanent append-only knowledge base -->
- RULE: macOS UserNotifications framework (UNUserNotificationCenter) requires Bundle.main.bundleIdentifier != nil. Check bundleIdentifier or fallback to osascript when running outside an .app bundle.
  WHY: Running bare Swift SPM binary output (.build/release/AgentSignalBar) without Info.plist triggers bundleProxyForCurrentProcess is nil exception on 2026-08-08.

- RULE: Chrome Extension MV3 background service workers go to sleep after 30s of inactivity. Content scripts monitoring local state must issue direct `fetch("http://127.0.0.1:18888/status")` calls in addition to extension messaging to prevent status updates from freezing when the service worker sleeps.
  WHY: ChatGPT Web state stuck on idle (🫥) during active generation turns because extension background worker suspended.

- RULE: Log watchers for desktop apps (Codex, Claude, Antigravity) MUST filter out background telemetry, autosave SQLite database writes, and heartbeat logs (`.sqlite`, `storage.json`, `telemetry.log`, `[process-memory]`, `[EventLogging]`).
  WHY: Codex Desktop writes internal SQLite / storage updates every 5-10s while idle, causing false positive `🤔 Working` or `🐶 Done` statuses when the user is completely idle.

- RULE: Permission prompt detectors (🔴 Blocked / 🥶 Frozen) MUST scan the entire turn slice from the last `USER_INPUT` to current step and verify no subsequent tool results or user responses have answered it.
  WHY: Antigravity transcript files log `PLANNER_RESPONSE` steps with tool calls immediately after `ask_question`, causing reverse tail scanners to break on standard tool call lines before reaching `ask_question`.

- RULE: Extension content scripts MUST ignore hidden background tabs (`document.visibilityState === 'hidden'`) and local HTTP relay calls (`127.0.0.1:18888`) to prevent feedback loops and status flickering.
  WHY: 200ms ticker HTTP POST requests to local relay endpoints triggered Chrome DOM MutationObservers, resetting `isWorkingState` in a perpetual flicker cycle between `working` and `done`.

- RULE: Claude Desktop log watchers MUST use a minimum 60s inactivity window for model reasoning turns.
  WHY: Deep reasoning turns often pause log file writes for 15-30 seconds mid-turn. A 12s window caused `thinkingStartTime` to reset to 0, preventing `🥵 Overworking` badge from triggering.

- RULE: Clamshell mode sleep prevention on MacBook battery power without external displays CANNOT be achieved via standard `IOPMAssertion` or `caffeinate -s` alone.
  WHY: macOS hardware power management forces ACPI/SMC sleep when the lid is closed on battery unless `pmset -a disablesleep 1` is explicitly set via root privileges.

- RULE: Recent/discovered transcript != currently live/open session.
  WHY: Desktop log/transcript files represent historic file system records, not active process or window state. Scanning recent files caused stale historical conversations to override active desktop app state on 2026-08-15.

- RULE: Do not aggregate provider state until live-session identity is proven.
  WHY: Aggregating unverified session heuristics produced false positive Working/Done/Needs You indicators across desktop providers on 2026-08-15.

- RULE: User acknowledgement cannot be reliably inferred without observable session identity.
  WHY: Without explicit live session focus/view binding, read/acknowledged state toggled incorrectly and flapped status badges.

- RULE: Do not expand session architecture across multiple providers in one milestone.
  WHY: Attempting simultaneous multi-session tracking across ChatGPT, Claude, Antigravity, and Codex created uncontainable heuristic complexity and hidden regressions.

- RULE: A truthful Unsupported/Unavailable state is better than a confidently wrong status.
  WHY: Showing false Working/Done/Needs You damages user trust. Presenting honest "Monitoring experimental / unavailable" provides clear, reliable status truth until single-provider session identity is proven.

- RULE: Ava real-use failure after two logical repair rounds triggers rollback, not another heuristic.
  WHY: Stop-loss rule requires immediate fallback to a known stable baseline rather than adding incremental heuristic patches when real-use acceptance fails twice.

- RULE: Prefer provider-native lifecycle events/hooks over passive UI/log/transcript inference.
  WHY: Passive scraping of log files, Accessibility APIs, or transcript mtimes cannot reliably determine live session identity or turn boundaries. Official provider hooks (e.g. Claude Code hooks) provide deterministic, authoritative session_id, lifecycle events (UserPromptSubmit, PreToolUse, Stop, PermissionRequest), and turn boundaries.

- RULE: Provider-native hooks solve state identity, but global hook scope requires strict production/test isolation; synthetic provider sessions must never contaminate live monitor state.
  WHY: Global hook configurations (e.g. ~/.claude/settings.json) fire for all sessions including test harness runs. Monitor stores must filter out synthetic session IDs and enforce bounded lifecycle cleanup so test residue does not contaminate live user monitor UI.

- RULE: Antigravity provider-native lifecycle hooks (`hooks.json`) provide authoritative session identity (`conversationId`) and event boundaries (`PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`), eliminating false Needs You and timer flickering during multi-step tool calls.
  WHY: Passive log watching or transcript tail reading for Antigravity produced false positive Attention Needed flags whenever standard tool calls like `run_command` or `view_file` appeared in `transcript.jsonl`. Native hooks explicitly identify `ask_question` tool gates as Needs You while maintaining continuous duration tracking across ordinary tool steps.

- RULE: In Antigravity native hooks, `PostInvocation` events emitted mid-turn MUST remain `Working`; only terminal `Stop` events transition status to `Done`, preventing status flickering during multi-step tool turns.
  WHY: Inside a single user turn, Antigravity emits `PreInvocation` -> `PreToolUse` -> `PostToolUse` -> `PostInvocation` -> `PreInvocation` ... Treating `PostInvocation` as `Done` caused status flickering between Working and Done. Keeping `PostInvocation` as `Working` and depending on terminal `Stop` for `Done` guarantees smooth turn continuity and stable `thinkingStartTime`.

- RULE: While Electron apps render permission cards internally without native cocoa sheet objects, macOS Notification Center (`com.apple.notificationcenterui`) receives live `AXNotificationCenterBanner` events containing permission text ("Requesting your permission in Terminal:"), providing a positive Needs-You signal when correlated with recent `PreToolUse` pending tool timestamps.
  WHY: Correlating live Notification Center banner delivery with recent `PreToolUse` pending tool timestamps surfaces Needs You (🔴) immediately upon prompt appearance, while `PostToolUse` approval immediately returns status to Working (🟡), cleanly ignoring historical notifications remaining in Notification Center history.
