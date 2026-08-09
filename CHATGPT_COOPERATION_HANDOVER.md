# AgentSignalBar — ChatGPT Web & Agent Cooperation Handover Protocol

> **Target Audience**: ChatGPT Web / OpenAI Assistant & Extension Adapters  
> **System Scope**: Native macOS Status Monitor (`AgentSignalBar.app`), Chrome Extension (`adapters/chrome-extension/`), HTTP Local Relay (`127.0.0.1:18888`), and Multi-Agent Orchestration (ChatGPT Web, Claude Code, Codex Desktop, Antigravity).

---

## 1. Executive Summary & Objective

**AgentSignalBar** is a lightweight, high-performance native macOS status bar application and multi-agent coordination hub designed to eliminate context-switching for developers.

### Core Objectives:
1. **Real-time Status Synchronization**: Track exact execution lifecycles (`⚪ Idle`, `🟡 Working/Thinking`, `🟢 Done`, `🔴 Attention Needed/Blocked`, `⚫ Offline`) across ChatGPT Web, Claude Code Desktop, Codex Desktop, and Antigravity.
2. **Bi-Directional Output Relay**: Allow seamless text transfer between ChatGPT Web and desktop coding agents (Claude, Antigravity, Codex) without copy-pasting.
3. **Smart Clamshell Anti-Sleep Engine**: Keep MacBook CPU & network active during long AI reasoning turns (even when the lid is closed), releasing sleep locks when turns complete.

---

## 2. Technical Architecture & Communication Protocols

```mermaid
flowchart TD
    subgraph Chrome Browser
        CT1["ChatGPT Tab 1 (Active)"]
        CT2["ChatGPT Tab 2 (Background)"]
        ExtCS["content.js (DOM & Stream Invariants)"]
        ExtBG["background.js (Tab Registry Service Worker)"]
    end

    subgraph Native macOS App (AgentSignalBar.app)
        HTTP["NWListener Micro HTTP Server (127.0.0.1:18888)"]
        Store["AgentState Thread-Safe Store"]
        AutoMon["AutoMonitor (Log Trajectory State Machine)"]
        SleepMgr["SleepManager (IOPMAssertion & Caffeinate Engine)"]
        MenuBar["AppKit NSStatusItem Menu Bar"]
    end

    subgraph Desktop Agents
        CLD["Claude Code Desktop"]
        CDX["Codex Desktop"]
        AGY["Antigravity IDE"]
    end

    CT1 --> ExtCS
    ExtCS --> ExtBG
    ExtBG -->|"POST /status (JSON payload)"| HTTP
    AutoMon -->|"File/Log reverse trajectory"| Store
    CLD & CDX & AGY --> AutoMon
    HTTP --> Store
    Store --> MenuBar
    Store --> SleepMgr
    HTTP -->|"POST /relay/chatgpt-output"| Store
    ExtCS -->|"GET /relay/pending"| HTTP
```

### Local HTTP API Endpoints (`127.0.0.1:18888`)
- **`POST /status`**: Update agent state payload.
  ```json
  {
    "agent": "chatgpt",
    "status": "working|done|blocked|idle|off",
    "detail": "2 ChatGPT tab(s) in Chrome (1 active)",
    "sessionTitle": "Mac Sleep Settings - Work",
    "webLink": "https://chatgpt.com/c/...",
    "openTabs": [
      { "title": "Mac Sleep Settings", "url": "https://chatgpt.com/c/123", "status": "working" }
    ]
  }
  ```
- **`GET /status`**: Returns JSON map of all 4 agent states.
- **`POST /relay/chatgpt-output`**: Receives clean markdown output from ChatGPT Web for 1-click transfer to desktop CLI/IDE.
- **`GET /relay/pending`**: Polled by ChatGPT extension content script to automatically inject relayed instructions from Claude/Antigravity into ChatGPT's prompt input box.

---

## 3. Deep Dive: Recurring Technical Issues & Standardized Solutions

Over the course of development, several critical edge cases caused status misdetection or UI instability. The table below details the exact root causes and standardized structural fixes:

### A. Missed Detection of `ask_question` / Permission Modals (Antigravity & Claude)
* **Symptom**: Antigravity or Claude pauses with an `ask_question` / permission prompt (`Allow finding files? [Yes/No]`), but the status bar shows `🟡 Working` instead of `🔴 Attention Needed / 🥶`.
* **Root Cause**:
  1. Inspecting only `lines.last` in `transcript.jsonl` failed when a background wrapper or telemetry log was written immediately after the `ask_question` step.
  2. Evaluating standard tool call execution (`type: PLANNER_RESPONSE` with `tool_calls`) before checking if `ask_question` was inside `tool_calls` caused the state machine to hit `isTurnActive = true` first.
* **Standardized Solution**:
  * **Reverse Turn-Slice Trajectory**: Locate the latest `USER_INPUT` line in `transcript.jsonl`. Inspect all lines in that current turn slice. If any line contains `ask_question` or `RequestFeedback: true` without a subsequent `USER_INPUT` or `TOOL_RESULT`, set `status = .blocked` (`🔴 Attention Needed / 🥶`) **100% of the time**.

### B. Rapid Status Flickering / Switching (`working` <-> `done` / `idle`)
* **Symptom**: Status bar rapidly toggled between `done` and `working` or `idle` every 1–2 seconds.
* **Root Cause**:
  1. **Local HTTP Fetch Feedback Loop**: `content.js` issued background HTTP `fetch("http://127.0.0.1:18888/relay/chatgpt-output")` requests on a 200ms interval. Each fetch mutated Chrome DOM nodes or network events, triggering `MutationObserver` in `content.js` to re-assert `working`, forming an infinite flicker loop.
  2. **Background Tab Contention**: Hidden background tabs ran instances of `content.js`. When throttled by Chrome, hidden tabs fired delayed `idle` status updates that overwrote the active tab's `working` status.
  3. **Premature Quiet Window Timeouts**: A 12s/15s log quiet timeout for Claude Code reset `thinkingStartTime` mid-turn during long 5m+ model reasoning pauses.
* **Standardized Solution**:
  1. **Strict URL Filtering**: In `content.js`, only match `https://chatgpt.com/backend-api/conversation`. Exclude all `127.0.0.1` and `18888` URLs.
  2. **State-Transition Fetching**: Only trigger output extraction and relay HTTP POST **once** upon state transition to `done`, NEVER on a 200ms interval ticker.
  3. **Background Tab Suppression**: If `document.visibilityState === 'hidden'` and no network stream is active, suppress `idle` status updates.
  4. **Extended Reasoning Windows**: Increased Claude log timeout to 60s to maintain continuous `thinkingStartTime` for 5m+ turns (triggering `🥵 Overworking` emoji properly).

### C. Quota Sync & Dynamic Reading Challenges
* **Symptom**: Quota progress bars in `AgentSignalBar` stayed on hardcoded percentages (e.g. 40%/67%) instead of syncing with live Antigravity settings (74% 5-Hour, 59% Weekly).
* **Root Cause**: `AutoMonitor` ran every 3 seconds and unconditionally overwrote `AgentUsageStore` in memory with stale values loaded from initial `config.json`.
* **Standardized Solution**: `AutoMonitor` only updates usage store when new data is received, preserving live `POST /usage` API updates and syncing `config.json` with user settings.

### D. MacBook Clamshell Lid-Closed Battery Sleep Limits
* **Symptom**: Closing the MacBook lid on battery power caused Codex and Claude turns to freeze.
* **Root Cause**: macOS power policy ignores standard `IOPMAssertion` (`kIOPMAssertionTypePreventUserIdleSystemSleep`) and `caffeinate -s` on battery power when the lid is closed unless an external display is attached or system-wide `pmset -a disablesleep 1` is configured with root privileges.
* **Standardized Solution**: Implemented `SleepManager.swift` with `Smart Auto-Mode` providing IOKit assertions and `caffeinate -d -i -s -u`. For battery-powered lid-closed operation without external displays, system kernel `pmset -a disablesleep 1` with battery/thermal cutoffs is required.

---

## 4. Invariants & Rules for ChatGPT Web Extension (`content.js`)

When ChatGPT Web is active:
1. **Stop Button Invariant**: If any button contains a square `<rect>` icon or `data-testid="stop-button"`, status MUST be `🟡 Working`.
2. **Code Block Streaming Invariant**: If an `<article>` contains pulsing dots (`...`), `.streaming`, or `.result-streaming` inside code blocks, status MUST stay `🟡 Working`.
3. **Done Transition**: Status transitions to `🟢 Done` ONLY when all streaming indicators disappear for >= 2.0 seconds.

---

## 5. Ready-to-Copy Prompt for ChatGPT Web

Copy and paste the formatted prompt below directly into ChatGPT Web to align it with this session and protocol:

```text
Hello ChatGPT! You are now connected to the AgentSignalBar local monitoring & bi-directional relay ecosystem on macOS.

Here is your operating context & system protocol:
1. Local Relay Hub: AgentSignalBar.app runs an HTTP server at http://127.0.0.1:18888.
2. Extension Relay: The native Chrome Extension (content.js & background.js) monitors your output status (Stop button rect icon, /backend-api/conversation network stream) and reports status updates to http://127.0.0.1:18888/status.
3. Multi-Session Support: All your open tabs across Chrome windows are indexed so the developer can 1-click switch between sessions from the macOS menu bar.
4. Bi-Directional Relay: When you finish generating code or responses, clean markdown text is extracted for 1-click relay to Claude Code, Antigravity, or Codex Desktop. Likewise, instructions from Claude/Antigravity can be automatically injected into your prompt area.
5. Invariants: Background tabs do not broadcast idle status; output relay fetches to 127.0.0.1 are strictly ignored to prevent status flickering.

Please acknowledge that you understand this protocol and stand by to assist with coding and relaying tasks!
```
