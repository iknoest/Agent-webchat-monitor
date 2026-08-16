# Antigravity State Source Authority Document

## Executive Summary
Antigravity monitoring in `AgentSignalBar` uses **Antigravity Provider-Native Lifecycle Hooks (`hooks.json`)** as the primary source of truth, backed by structured session identity (`conversationId`) and transcript directory indexing (`~/.gemini/antigravity/brain/<conversationId>/`).

## Authority Hierarchy & Evidence Ranking

| Rank | Source Type | Implementation Mechanism | Session Identity | Event Precision | Reliability Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1 (Primary)** | **Provider-Native Lifecycle Hooks** | `~/.gemini/config/hooks.json` executing `antigravity_hook_relay.py` | Full UUID (`conversationId`) | Exact (`PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`) | **AUTHORITATIVE (100% Reliable)** |
| **2 (Secondary)** | **Structured Session Transcripts** | `~/.gemini/antigravity/brain/<sessionId>/.system_generated/logs/transcript.jsonl` | Full UUID (`conversationId`) | Structured step log (`USER_INPUT`, `PLANNER_RESPONSE`, `ask_question`) | **VALIDATION FALLBACK** |
| **3 (Prohibited)** | **Passive Log Scrapes / mtimes** | File modification age or natural language substring scraping | None | Weak heuristic | **PROHIBITED (Causes False Needs You)** |

## Payload Protocol
Antigravity passes JSON payloads on `stdin` for every registered lifecycle event:

```json
{
  "conversationId": "fa06a29d-187f-49fa-acf6-596b7299e0be",
  "workspacePaths": ["/Users/ava/Projects/Agent-webchat monitor"],
  "transcriptPath": "/Users/ava/.gemini/antigravity/brain/fa06a29d-187f-49fa-acf6-596b7299e0be/.system_generated/logs/transcript.jsonl",
  "toolCall": {
    "name": "ask_question",
    "args": { ... }
  }
}
```

## Lifecycle Event Mapping

1. **Prompt Submitted / Turn Started (`PreInvocation`)**:
   - Status: 🟡 **Working**
   - `thinkingStartTime`: Set to current timestamp
   - Duration: Monotonic continuous count up
2. **Tool Invocation (`PreToolUse` / `PostToolUse`)**:
   - Standard tool (`run_command`, `view_file`): Retains 🟡 **Working**, `thinkingStartTime` is preserved (zero timer reset)
   - Question / Permission gate (`ask_question`): Transitions to 🔴 **Needs You (Blocked)**
3. **Turn Completed (`Stop` / `PostInvocation`)**:
   - Status: 🟢 **NEW Output Ready (Done)**
   - `thinkingStartTime`: Cleared
   - `lastDurationSeconds`: Recorded for user display
4. **Session Termination (`SessionEnd` / Purge)**:
   - Status: ⚪ **Idle** or session removed from active tracking
