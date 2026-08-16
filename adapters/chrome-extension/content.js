(function() {
    'use strict';

    // Versioned Disposable Singleton Lifecycle for Script Reinjection
    if (typeof window !== 'undefined') {
        if (window.__AgentSignalBarDetectorInstance && typeof window.__AgentSignalBarDetectorInstance.dispose === 'function') {
            window.__AgentSignalBarDetectorInstance.dispose();
        }
    }

    const instanceId = Date.now() + '_' + Math.random().toString(36).substr(2, 5);
    let sequenceNumber = 0;
    let lastNetworkChunkTime = 0;
    let checkTimer = null;
    let pendingRelayTimer = null;
    let pendingEvalTimer = null;
    let domObserver = null;
    let eventListeners = [];
    let lastEmittedState = null;

    function addTrackedEventListener(target, event, fn, opts) {
        if (!target) return;
        target.addEventListener(event, fn, opts);
        eventListeners.push({ target, event, fn, opts });
    }

    // 0ms Main World Fetch Interceptor Injection (Strictly targeted at ChatGPT Backend API)
    try {
        if (typeof document !== 'undefined' && (document.head || document.documentElement)) {
            const script = document.createElement('script');
            script.textContent = `
            (function() {
                if (window.__AgentSignalBarFetchIntercepted) return;
                window.__AgentSignalBarFetchIntercepted = true;
                const origFetch = window.fetch;
                window.fetch = async function(...args) {
                    const url = (args[0] && typeof args[0] === 'string') ? args[0] : (args[0]?.url || '');
                    if (url.includes('/backend-api/conversation') || url.includes('/backend-api/lat/r')) {
                        window.dispatchEvent(new CustomEvent('chatgpt-stream-chunk'));
                        try {
                            const res = await origFetch.apply(this, args);
                            if (res.body && res.body.getReader) {
                                const reader = res.body.getReader();
                                const stream = new ReadableStream({
                                    start(controller) {
                                        function push() {
                                            reader.read().then(({ done, value }) => {
                                                if (done) {
                                                    window.dispatchEvent(new CustomEvent('chatgpt-stream-end'));
                                                    controller.close();
                                                    return;
                                                }
                                                window.dispatchEvent(new CustomEvent('chatgpt-stream-chunk'));
                                                controller.enqueue(value);
                                                push();
                                            });
                                        }
                                        push();
                                    }
                                });
                                return new Response(stream, { headers: res.headers, status: res.status, statusText: res.statusText });
                            }
                            return res;
                        } catch (err) {
                            window.dispatchEvent(new CustomEvent('chatgpt-stream-end'));
                            throw err;
                        }
                    }
                    return origFetch.apply(this, args);
                };
            })();
            `;
            (document.head || document.documentElement).appendChild(script);
        }
    } catch (e) {}

    // Pure Raw Signal Emitter (Emits raw boolean signal + sequence number + timestamp; deduplicated)
    function emitRawSignal(active, reason, force = false, statusOverride = null, interrupted = false) {
        const cleanTitle = (typeof document !== 'undefined' && document.title) ? document.title.replace('- ChatGPT', '').trim() : 'ChatGPT Web';
        const cleanUrl = (typeof window !== 'undefined') ? window.location.href : 'https://chatgpt.com';

        const activeBool = !!active;
        const reasonStr = reason || '';
        const statusVal = statusOverride || (activeBool ? 'working' : 'idle');

        // Bounded Suppression: Skip emitting if observation is identical to last emitted state
        if (!force && lastEmittedState &&
            lastEmittedState.active === activeBool &&
            lastEmittedState.status === statusVal &&
            lastEmittedState.reason === reasonStr &&
            lastEmittedState.sessionTitle === cleanTitle &&
            lastEmittedState.webLink === cleanUrl) {
            return false;
        }

        sequenceNumber++;
        lastEmittedState = {
            active: activeBool,
            status: statusVal,
            interrupted: !!interrupted,
            reason: reasonStr,
            sessionTitle: cleanTitle,
            webLink: cleanUrl
        };

        const payload = {
            instanceId: instanceId,
            seq: sequenceNumber,
            timestamp: Date.now(),
            active: activeBool,
            status: statusVal,
            interrupted: !!interrupted,
            reason: reasonStr,
            sessionTitle: cleanTitle,
            webLink: cleanUrl
        };

        try {
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
                chrome.runtime.sendMessage({
                    type: 'RAW_GENERATION_SIGNAL',
                    payload: payload
                }, () => {
                    if (chrome.runtime && chrome.runtime.lastError) {}
                });
            }
        } catch (err) {}
        return true;
    }

    // 100% Text-Independent Transient DOM Detector
    function isElementVisible(el) {
        if (!el) return false;
        if (typeof window === 'undefined' || typeof el.getBoundingClientRect !== 'function') {
            if (el.style && (el.style.display === 'none' || el.style.visibility === 'hidden')) {
                return false;
            }
            if (el.hidden) return false;
            return true;
        }
        if (el.offsetParent === null && window.getComputedStyle(el).position !== 'fixed') {
            return false;
        }
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
            return false;
        }
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
    }

    // 100% Text-Independent Transient DOM Detector with CURRENT-only Error Scope
    function detectChatGPTThinking(doc, lastNetworkChunkTs, nowOverride) {
        if (!doc) return { active: false, status: 'idle', reason: '' };
        const now = nowOverride || Date.now();

        // 1. Positive Working Signals Checked FIRST (Current working evidence immediately clears stale Blocked)
        if (lastNetworkChunkTs > 0 && (now - lastNetworkChunkTs < 2000)) {
            return { active: true, status: 'working', reason: 'Network Stream Active' };
        }

        const transientSelectors = [
            'button[data-testid="stop-button"]',
            'button[data-testid*="stop"]',
            'button[aria-label*="Stop" i]',
            'button[aria-label*="stop" i]',
            'button[data-state="streaming"]',
            '[data-is-streaming="true"]',
            '[data-state="streaming"]'
        ];

        for (const sel of transientSelectors) {
            const el = doc.querySelector(sel);
            if (el && isElementVisible(el)) {
                return { active: true, status: 'working', reason: `Transient Selector [${sel}]` };
            }
        }

        const actionButtons = doc.querySelectorAll('button[data-testid*="send"], button[data-testid*="stop"], button[aria-label*="Send" i], button[aria-label*="Stop" i]');
        for (const btn of actionButtons) {
            if (!isElementVisible(btn)) continue;
            const testId = btn.getAttribute('data-testid') || '';
            const ariaLabel = btn.getAttribute('aria-label') || '';

            if (testId.toLowerCase().includes('stop') || ariaLabel.toLowerCase().includes('stop')) {
                return { active: true, status: 'working', reason: 'Stop Button Invariant' };
            }

            if (btn.querySelector('rect') || btn.querySelector('svg rect')) {
                return { active: true, status: 'working', reason: 'Stop Rect Icon' };
            }
        }

        const articles = doc.querySelectorAll('article');
        const lastArticle = articles.length > 0 ? articles[articles.length - 1] : null;

        if (lastArticle) {
            if (lastArticle.querySelector('.result-streaming') ||
                lastArticle.querySelector('.streaming') ||
                lastArticle.querySelector('.markdown-prose.streaming') ||
                lastArticle.querySelector('span.cursor')) {
                return { active: true, status: 'working', reason: 'Active Markdown Stream' };
            }
        }

        // 2. CURRENT-only Visible Error / Interruption Detection
        // Only inspect currently visible top-level toasts or error elements inside the LATEST article
        const candidateErrorElements = doc.querySelectorAll('[data-testid="error-notification"], .text-token-text-error, .border-red-500, div[class*="text-red"]');
        for (const el of candidateErrorElements) {
            if (!isElementVisible(el)) continue;

            // If the element is inside an article, it MUST be inside the LAST article (latest turn)
            const parentArticle = el.closest('article');
            if (parentArticle && articles.length > 0 && parentArticle !== lastArticle) {
                // Historical turn error element — ignore!
                continue;
            }

            const txt = (el.innerText || '').toLowerCase();
            if (txt.includes('error') || txt.includes('interrupted') || txt.includes('try again') || txt.includes('waiting for the complete answer')) {
                return { active: false, status: 'blocked', interrupted: true, reason: 'Current Turn Visible Error Element' };
            }
        }

        // Check for visible error banner text in the LAST article specifically
        if (lastArticle) {
            const lastArticleText = (lastArticle.innerText || '').toLowerCase();
            if (lastArticleText.includes('connection interrupted') ||
                lastArticleText.includes('there was an error generating a response') ||
                lastArticleText.includes('an error occurred while generating')) {
                // Confirm the error text is in a visible element inside lastArticle
                const childDivs = lastArticle.querySelectorAll('div, p, span');
                for (const child of childDivs) {
                    if (isElementVisible(child)) {
                        const cText = (child.innerText || '').toLowerCase();
                        if (cText.includes('connection interrupted') ||
                            cText.includes('there was an error generating') ||
                            cText.includes('an error occurred while generating')) {
                            return { active: false, status: 'blocked', interrupted: true, reason: 'Latest Turn Interruption Banner' };
                        }
                    }
                }
            }
        }

        return { active: false, status: 'idle', reason: '' };
    }

    function checkChatGPTState() {
        if (typeof document === 'undefined') return;
        const thinkingState = detectChatGPTThinking(document, lastNetworkChunkTime);
        emitRawSignal(thinkingState.active, thinkingState.reason, false, thinkingState.status, thinkingState.interrupted);
    }

    function scheduleCheckChatGPTState() {
        if (pendingEvalTimer) return; // Only one DOM evaluation job pending at a time
        pendingEvalTimer = setTimeout(() => {
            pendingEvalTimer = null;
            checkChatGPTState();
        }, 150);
    }

    function dispose() {
        if (checkTimer) clearInterval(checkTimer);
        if (pendingRelayTimer) clearInterval(pendingRelayTimer);
        if (pendingEvalTimer) clearTimeout(pendingEvalTimer);
        if (domObserver) domObserver.disconnect();
        eventListeners.forEach(({ target, event, fn, opts }) => {
            try { target.removeEventListener(event, fn, opts); } catch (e) {}
        });
        eventListeners = [];
        console.log(`[AgentSignalBar Detector] Disposed instance ${instanceId}`);
    }

    // Register active instance on window for singleton lifecycle
    if (typeof window !== 'undefined') {
        window.__AgentSignalBarDetectorInstance = { instanceId, dispose };

        addTrackedEventListener(window, 'chatgpt-stream-chunk', () => {
            lastNetworkChunkTime = Date.now();
            emitRawSignal(true, 'Network Stream Active', true);
        });

        addTrackedEventListener(window, 'chatgpt-stream-end', () => {
            lastNetworkChunkTime = 0;
            scheduleCheckChatGPTState();
        });
    }

    if (typeof document !== 'undefined') {
        addTrackedEventListener(document, 'keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                const promptArea = document.querySelector('#prompt-textarea');
                if (promptArea && document.activeElement === promptArea) {
                    lastNetworkChunkTime = Date.now();
                    emitRawSignal(true, 'Enter Key Submit', true);
                }
            }
        }, true);

        addTrackedEventListener(document, 'click', function(e) {
            const sendBtn = e.target.closest('button[data-testid="send-button"]') ||
                            e.target.closest('button[aria-label*="Send" i]');
            if (sendBtn) {
                lastNetworkChunkTime = Date.now();
                emitRawSignal(true, 'Send Button Click', true);
            }
        }, true);

        if (typeof window !== 'undefined') {
            checkTimer = setInterval(scheduleCheckChatGPTState, 500);
            if (document.body) {
                domObserver = new MutationObserver(scheduleCheckChatGPTState);
                domObserver.observe(document.body, { childList: true, subtree: true });
            }
        }
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = {
            detectChatGPTThinking,
            isElementVisible,
            emitRawSignal,
            checkChatGPTState,
            scheduleCheckChatGPTState,
            dispose,
            getLastEmittedState: () => lastEmittedState,
            resetLastEmittedState: () => { lastEmittedState = null; }
        };
    }

    console.log(`🚀 AgentSignalBar ContentScript Active [Instance: ${instanceId}]`);
})();
