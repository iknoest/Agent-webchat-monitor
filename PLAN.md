# Agent Signal Bar (macOS Status Monitor) Plan

## Problem (Y)
Prevent wasted developer context-switching & focus loss caused by not knowing when long-running AI agent tasks (ChatGPT Web, Codex Desktop, Claude Code Desktop, Antigravity) complete, encounter errors, or wait for input.

## Objective (v1)
Build a native macOS Menu Bar application in Swift (`AgentSignalBar`) listening on `127.0.0.1:18888` for agent status signals, rendering visual status indicators (Working/Done/Blocked), playing togglable audio alerts and macOS notifications, and providing quick window focus for Chrome (ChatGPT Web) and desktop agents.

## Build Verdict
BUILD — Custom lightweight Swift macOS Menu Bar app + Network framework HTTP listener + Tampermonkey/MV3 Chrome adapter & CLI log adapters.

## Definition of Done (MVP & Extensions)
Measurable — each line names its verification command (literal paths):
  - [x] Swift executable & app bundle builds cleanly — verify: `swift build -c release && ./build_app.sh`
  - [x] HTTP Server receives and updates agent status — verify: `curl -s -X POST http://127.0.0.1:18888/status -H "Content-Type: application/json" -d '{"agent":"chatgpt","status":"working"}'`
  - [x] Status retrieval API returns current state — verify: `curl -s http://127.0.0.1:18888/status`
Experiential — each line names its artifact + producing command:
  - [x] Menu Bar updates status & plays sound / notification when agent state changes — artifact: `AgentSignalBar.app` — serve: `open AgentSignalBar.app`
  - [x] Native Chrome Extension tracks multi-session ChatGPT Web state — artifact: `adapters/chrome-extension/`
  - [x] Bi-directional Relay engine transfers output between ChatGPT Web and Desktop agents — artifact: `Sources/AgentSignalBar/OutputRelayManager.swift`
  - [x] Smart Clamshell Anti-Sleep Engine prevents sleep during active turns — artifact: `Sources/AgentSignalBar/SleepManager.swift`

## Boundaries
- macOS AppKit / NSStatusItem API
- Local HTTP socket binding on `127.0.0.1:18888`
- Chrome DOM (ChatGPT Web) via Manifest V3 Chrome Extension
- macOS Accessibility & AppleScript for window focus (`osascript`)
- IOKit Power Management (`IOPMAssertion`) & `caffeinate` CLI

## Phases
- [x] Phase 1: Native Swift Menu Bar App & HTTP Core (`Package.swift`, `AgentState`, `HTTPServer`, `MenuBarManager`)
- [x] Phase 2: Notifications, Audio Control & Window Focus (NSSound toggle, UserNotifications, AppleScript focus)
- [x] Phase 3: Adapters Integration (ChatGPT Web Chrome Extension, Claude Code, Codex, Antigravity adapters)
- [x] Phase 4: Verification & Walkthrough (End-to-End simulation & user walkthrough guide)
- [x] Phase 5: Bi-Directional Output Relay & Multi-Session ChatGPT Support (`OutputRelayManager`, Chrome MV3 Background Worker)
- [x] Phase 6: Smart Clamshell Anti-Sleep Engine & Comprehensive Handover Protocol (`SleepManager`, `CHATGPT_COOPERATION_HANDOVER.md`)
