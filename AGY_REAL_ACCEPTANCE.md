# Antigravity Reality Check & Native Hook Verification Report

## Final Verdict

**AGY WORKING/DONE HOOKS VERIFIED — NEEDS-YOU SIGNAL NOT AVAILABLE**

---

## 1. Native Hook Delivery Verification (Phase 1 Result)

Native Antigravity lifecycle hooks (`hooks.json`) were configured and verified in real IDE sessions without synthetic HTTP POST mocks.

- **Trace File**: `/private/tmp/agy_native_hook_trace.jsonl` (75+ real native hook records captured)
- **Session Identity (`conversationId`)**: `fa06a29d-187f-49fa-acf6-596b7299e0be` (Current active Antigravity session)

### Captured Native Lifecycle Events
1. **`PreInvocation`**: Fires when user submits prompt / model turn starts.
   - Payload keys: `["artifactDirectoryPath", "conversationId", "initialNumSteps", "invocationNum", "modelName", "transcriptPath", "workspacePaths"]`
   - State Result: 🟡 **Working**
2. **`PreToolUse`**: Fires before tool execution (`run_command`, `write_to_file`, `view_file`, `list_dir`).
   - Payload keys: `["artifactDirectoryPath", "conversationId", "modelName", "stepIdx", "toolCall", "transcriptPath", "workspacePaths"]`
   - Contract Requirement: Must return `{"decision": "allow"}` on `stdout`.
   - State Result: 🟡 **Working** (Continuous monotonic duration timer)
3. **`PostToolUse`**: Fires after tool step completes.
   - Payload keys: `["artifactDirectoryPath", "conversationId", "error", "modelName", "stepIdx", "toolCall", "transcriptPath", "workspacePaths"]`
   - State Result: 🟡 **Working**
4. **`PostInvocation` & `Stop`**: Fires when turn completes.
   - Payload keys: `["artifactDirectoryPath", "conversationId", "error", "executionNum", "fullyIdle", "modelName", "terminationReason", "transcriptPath", "workspacePaths"]`
   - State Result: 🟢 **Done (NEW Output Ready)**

---

## 2. Permission Dialog & "Needs You" Signal Investigation

### Experimental Findings
When Antigravity presents an interactive permission approval dialog to Ava for standard tools (`run_command`):

A. **Structured Payload Indicator**: `PreToolUse` hook payload contains **no field** indicating whether the tool is auto-approved or waiting for interactive user permission. The top-level keys are strictly `artifactDirectoryPath`, `conversationId`, `modelName`, `stepIdx`, `toolCall`, `transcriptPath`, `workspacePaths`.
B. **Event Emitted**: Antigravity does **not** emit an `ask_permission` or `PermissionRequest` hook event prior to displaying its native permission UI.
C. **Semantics Boundary**: Modifying hook output to return `"decision": "ask"` would alter Antigravity's permission policy (forcing approval UI), violating the product constraint.

### Conclusion on Needs-You Signal
Native hooks provide 100% reliable session identity and turn lifecycle boundaries for **Working** (🟡) and **Done** (🟢) states. However, an explicit structured **Needs You / Blocked (🔴)** signal for native IDE `run_command` permission dialogs is **NOT AVAILABLE** in Antigravity's current native hook payload spec without altering agent permission semantics.

Per rule: *"If the native hook system cannot OBSERVE the existing permission dialog, report `AGY WORKING/DONE HOOKS VERIFIED — NEEDS-YOU SIGNAL NOT AVAILABLE`. That is preferable to another false detector."*

---

## 3. Hook Output Contract Verification
- `PreToolUse`: **MUST** output `{"decision": "allow"}` on `stdout`. Returning `{}` without `"decision": "allow"` causes Antigravity safety engine to reject the tool execution (`tool call denied by pre-tool hook:`).
- `PreInvocation` / `PostInvocation` / `Stop`: Accepts `{}` on `stdout`.

---

## 4. Reality Check Acceptance Matrix

| Lifecycle Stage | Native Hook Event | Real Event Logged | Observed State | Needs-You Signal Available |
| :--- | :--- | :--- | :--- | :--- |
| **Real Prompt Start** | `PreInvocation` | Yes (`fa06a29d-...`) | Working (🟡) | N/A |
| **Tool Execution** | `PreToolUse` / `PostToolUse` | Yes (`stepIdx: 177, 183, 197, 199`) | Working (🟡, monotonic) | N/A |
| **Permission Dialog** | `PreToolUse` | Yes (`toolName: run_command`) | Working (🟡) | **NO** (No indicator in payload) |
| **Turn Finish** | `Stop` / `PostInvocation` | Yes (`terminationReason`) | Done (🟢) | N/A |
