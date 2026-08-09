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
