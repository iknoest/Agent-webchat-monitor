# Antigravity Needs-You Positive-Signal Feasibility & Accessibility Report

## Final Verdict

**AGY WORKING/DONE SUPPORTED — PERMISSION MONITORING UNAVAILABLE**

---

## Executive Summary
This investigation evaluated whether visible Antigravity (`com.google.antigravity`) permission dialogs (such as "Allow running this command?") can be detected using positive macOS Accessibility (`AXUIElement`) or window tree evidence (`CGWindowList`).

Based on empirical inspection of the running `com.google.antigravity` process, Antigravity renders tool approval cards inside Electron's internal web view DOM canvas within a single top-level `AXWindow` (`TOTAL WINDOWS: 1`). It does **not** spawn native macOS cocoa `AXSheet`, `AXDialog`, or `AXPopover` objects when permission prompts appear.

Because no positive macOS Accessibility UI signal exists for internal Electron permission cards, and per product rules prohibiting inference from silence, transcript scraping, or altering agent permission policy semantics (`force_ask`), **Needs-You permission monitoring for Antigravity is officially marked UNAVAILABLE**.

Antigravity monitoring cleanly supports:
- 🟡 **Working** (Turn start, continuous duration, multi-step tool turns)
- 🟢 **NEW Output Ready / Finished** (Turn complete, duration summary)
- 🆔 **Independent Multi-Session Identity** (`conversationId`)

---

## Technical Investigation & Empirical Evidence

### 1. Window & Accessibility Tree Inspection
- **Inspector Tool**: Swift `AXUIElement` + `CGWindowList` probe ([`inspect_ax_swift.swift`](file:///Users/ava/Projects/Agent-webchat%20monitor/scripts/inspect_ax_swift.swift)).
- **Window Count**: `TOTAL WINDOWS: 1`
- **Window Hierarchy**:
  ```text
  [0] role: AXWindow | subrole: AXStandardWindow | title: "Antigravity..." | modal: false
    [1] role: AXGroup | title: "Antigravity..."
      [2] role: AXGroup
        [3] role: AXGroup
          [4] role: AXGroup
            [5] role: AXGroup
              [6] role: AXGroup
  ```
- **Observation**: Regardless of internal UI state changes, Electron does not expose separate `AXSheet`, `AXDialog`, or modal `AXButton` nodes to the macOS Accessibility API (`AXUIElement`).

### 2. Evaluation Against Acceptance Criteria

| Criteria | Required Behavior | Empirical Result | Verdict |
| :--- | :--- | :--- | :--- |
| **1. Dialog Visible Signal** | Positive AX signal appears | No `AXSheet` / `AXDialog` node created by Electron | **FAIL** |
| **2. Dialog Dismissed Signal** | Signal disappears | N/A (No initial AX signal) | **FAIL** |
| **3. Working State Isolation** | No signal during ordinary working | Single static `AXWindow` throughout | **PASS** |
| **4. UI Structure Basis** | No log/transcript text inference | Structural AX tree shows zero dialog nodes | **FAIL** |
| **5. SLA Timing** | Signal detected <=30s | N/A | **FAIL** |
| **6. Policy Preservation** | Does not alter permission policy | Preserved (`{"decision": "allow"}`) | **PASS** |

---

## Supported Capabilities Summary

1. **Working State (🟡)**:
   - Driven by `PreInvocation`, `PreToolUse`, `PostToolUse` native lifecycle hooks.
   - Preserves `thinkingStartTime` across multi-step turns (zero timer reset).
   - SLA: <= 1s detection.
2. **Finished State (🟢)**:
   - Driven by `Stop` & `PostInvocation` native lifecycle hooks.
   - Clears `thinkingStartTime` and records `lastDurationSeconds`.
   - SLA: <= 1s detection.
3. **Session Identity**:
   - Tracked independently per `conversationId` UUID.
4. **Needs-You / Permission Prompt (🔴)**:
   - **UNAVAILABLE** (Explicitly documented in product UI & documentation to prevent false alerts).
