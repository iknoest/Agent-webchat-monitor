# find . -name '*.swift' -o -name '*.py' -o -name '*.js' -o -name '*.md' -not -path './.build/*' -not -path './.agent/*'

Package.swift — Swift package definition for AgentSignalBar executable
build_app.sh — Script to compile release binary and create standalone AgentSignalBar.app
CHATGPT_COOPERATION_HANDOVER.md — Comprehensive handover protocol & prompt for ChatGPT Web cooperation
Sources/AgentSignalBar/main.swift — Entry point for native macOS menu bar status app & AutoMonitor background service
Sources/AgentSignalBar/HTTPServer.swift — NWListener-based micro HTTP server (127.0.0.1:18888) with Chrome Private Network Access support
Sources/AgentSignalBar/AutoMonitor.swift — Background log & process monitor with process .off state and thinking duration tracking
Sources/AgentSignalBar/AgentState.swift — Data structures and thread-safe state store for 4 agents with .off status and active summary filtering
Sources/AgentSignalBar/MenuBarManager.swift — AppKit NSStatusItem indicator with relative timestamps and thinking duration metrics
Sources/AgentSignalBar/NotificationManager.swift — Audio alert (NSSound) and macOS UserNotification dispatcher with osascript CLI fallback
Sources/AgentSignalBar/SleepManager.swift — Smart Clamshell Anti-Sleep manager with IOKit IOPMAssertion and caffeinate process execution
Sources/AgentSignalBar/WindowFocuser.swift — Exact bundle ID (com.openai.codex / com.anthropic.claudefordesktop / com.google.antigravity) window manager
adapters/chrome-extension/manifest.json — Native Manifest V3 Chrome Extension manifest with background service worker
adapters/chrome-extension/background.js — Service worker relaying extension messages and tracking multi-tab ChatGPT sessions
adapters/chrome-extension/content.js — Native Chrome Extension content script monitoring ChatGPT Web streaming state with visibility filtering
adapters/chatgpt-adapter.user.js — Tampermonkey/Violentmonkey script for Chrome watching ChatGPT Web status
adapters/claude-adapter.sh — Shell/log watcher adapter for Claude Code Desktop
adapters/codex-adapter.sh — Shell/log watcher adapter for Codex Desktop
adapters/antigravity-adapter.py — Task watcher adapter for Antigravity
