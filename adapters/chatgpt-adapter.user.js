// ==UserScript==
// @name         ChatGPT AgentSignalBar Adapter
// @namespace    https://github.com/guan-ops/Agent-Signal-Bar
// @version      1.1
// @description  Send ChatGPT status updates to AgentSignalBar macOS Menu Bar App
// @match        *://chatgpt.com/*
// @match        *://*.chatgpt.com/*
// @match        *://chat.openai.com/*
// @match        *://*.chat.openai.com/*
// @grant        GM_xmlhttpRequest
// @grant        GM.xmlHttpRequest
// @connect      127.0.0.1
// @connect      localhost
// @run-at       document-idle
// ==UserScript==

(function() {
    'use strict';

    const SIGNAL_URL = 'http://127.0.0.1:18888/status';
    let lastStatus = 'idle';

    function sendStatus(status, detail) {
        if (lastStatus === status) return;
        lastStatus = status;

        console.log(`[AgentSignalBar] ChatGPT status -> ${status} (${detail})`);

        const payload = JSON.stringify({
            agent: 'chatgpt',
            status: status,
            detail: detail || ''
        });

        const reqFunc = (typeof GM_xmlhttpRequest !== 'undefined') ? GM_xmlhttpRequest :
                        (typeof GM !== 'undefined' && GM.xmlHttpRequest) ? GM.xmlHttpRequest : null;

        if (reqFunc) {
            reqFunc({
                method: 'POST',
                url: SIGNAL_URL,
                headers: { 'Content-Type': 'application/json' },
                data: payload
            });
        } else {
            fetch(SIGNAL_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: payload
            }).catch(err => console.error('[AgentSignalBar] Fetch error:', err));
        }
    }

    function checkChatGPTState() {
        // Detect stop button or streaming indicator (generating response)
        const stopButton = document.querySelector('button[data-testid="stop-button"]') ||
                           document.querySelector('button[aria-label="Stop generating"]') ||
                           document.querySelector('.result-streaming') ||
                           document.querySelector('button[data-testid="fruitjuice-send-button"] [data-state="streaming"]');

        // Detect error alert
        const errorElem = document.querySelector('[data-testid="error-notification"]') ||
                          document.querySelector('.text-red-500');

        if (stopButton) {
            sendStatus('working', 'ChatGPT is generating response...');
        } else if (errorElem && errorElem.textContent.trim().length > 0) {
            sendStatus('blocked', 'ChatGPT error: ' + errorElem.textContent.trim().substring(0, 50));
        } else if (lastStatus === 'working') {
            sendStatus('done', 'ChatGPT finished generating response!');
        }
    }

    setInterval(checkChatGPTState, 500);

    const observer = new MutationObserver(checkChatGPTState);
    if (document.body) {
        observer.observe(document.body, { childList: true, subtree: true });
    }

    console.log('🚀 ChatGPT AgentSignalBar Adapter active on ' + window.location.href);
})();
