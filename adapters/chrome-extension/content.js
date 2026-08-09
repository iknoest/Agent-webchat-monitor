(function() {
    'use strict';

    let lastStatus = null;
    let lastTitle = '';
    let doneDebounceTimer = null;
    let isWorkingState = false;
    let lastNetworkChunkTime = 0;

    // 0ms Main World Fetch Interceptor Injection (Strictly targeted at ChatGPT Backend API)
    try {
        const script = document.createElement('script');
        script.textContent = `
        (function() {
            const origFetch = window.fetch;
            window.fetch = async function(...args) {
                const url = (args[0] && typeof args[0] === 'string') ? args[0] : (args[0]?.url || '');
                // Strictly match ChatGPT backend conversation streaming URLs; ignore local 127.0.0.1 requests
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
    } catch (e) {}

    window.addEventListener('chatgpt-stream-chunk', () => {
        lastNetworkChunkTime = Date.now();
        triggerImmediateWorkingState('Network Stream Active');
    });

    window.addEventListener('chatgpt-stream-end', () => {
        lastNetworkChunkTime = 0;
        checkChatGPTState();
    });

    function triggerImmediateWorkingState(reason) {
        if (doneDebounceTimer) {
            clearTimeout(doneDebounceTimer);
            doneDebounceTimer = null;
        }
        isWorkingState = true;
        sendStatus('working', `ChatGPT generating [${reason}]`);
    }

    function sendStatusDirectly(status, detail, cleanTitle, cleanUrl) {
        const payload = {
            agent: 'chatgpt',
            status: status,
            detail: detail || '',
            sessionTitle: cleanTitle,
            webLink: cleanUrl
        };

        try {
            fetch('http://127.0.0.1:18888/status', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            }).catch(() => {});
        } catch (e) {}

        try {
            chrome.runtime.sendMessage({
                type: 'STATUS_UPDATE',
                payload: payload
            }, () => {
                if (chrome.runtime.lastError) {}
            });
        } catch (err) {}
    }

    function sendStatus(status, detail, forceSend = false) {
        const cleanTitle = document.title ? document.title.replace('- ChatGPT', '').trim() : 'ChatGPT Web';
        const cleanUrl = window.location.href;

        if (!forceSend && lastStatus === status && lastTitle === cleanTitle) return;
        lastStatus = status;
        lastTitle = cleanTitle;

        console.log(`[AgentSignalBar Extension] ChatGPT status -> ${status} (${detail}) [${cleanTitle}]`);
        sendStatusDirectly(status, detail, cleanTitle, cleanUrl);
    }

    // 100% Reliable Invariant Stop Button & Markdown Streaming Detector
    function isChatGPTThinking() {
        // 1. Active Network Stream within last 2 seconds
        const now = Date.now();
        if (lastNetworkChunkTime > 0 && (now - lastNetworkChunkTime < 2000)) {
            return { active: true, reason: 'Network Stream' };
        }

        // 2. Structural Stop Button anywhere on page
        const stopBtn = document.querySelector('button[data-testid="stop-button"]') ||
                        document.querySelector('button[aria-label*="Stop" i]') ||
                        document.querySelector('button[data-state="streaming"]');
        if (stopBtn) return { active: true, reason: 'Stop Button' };

        // 3. Prompt Action Button Invariant: Check if bottom-right submit button contains square <rect> (Stop icon)
        const allButtons = document.querySelectorAll('button');
        for (const btn of allButtons) {
            if (btn.querySelector('rect') || btn.querySelector('svg rect')) {
                return { active: true, reason: 'Stop Rect Icon' };
            }
        }

        // 4. Active Markdown Streaming & Pulsing Dots in recent DOM
        const articles = document.querySelectorAll('article');
        if (articles.length > 0) {
            const lastArticle = articles[articles.length - 1];

            if (lastArticle.querySelector('.result-streaming') ||
                lastArticle.querySelector('.streaming') ||
                lastArticle.querySelector('span.cursor') ||
                lastArticle.querySelector('svg.animate-spin') ||
                lastArticle.querySelector('svg.animate-pulse')) {
                return { active: true, reason: 'Active Markdown Stream' };
            }
        }

        return { active: false, reason: '' };
    }

    function checkChatGPTState() {
        const thinkingState = isChatGPTThinking();

        // If tab is hidden in background and not actively thinking, do not broadcast idle to prevent flickering
        if (document.visibilityState === 'hidden' && !thinkingState.active && !isWorkingState) {
            return;
        }

        const errorElem = document.querySelector('[data-testid="error-notification"]') ||
                          document.querySelector('.text-red-500');

        if (thinkingState.active) {
            if (doneDebounceTimer) {
                clearTimeout(doneDebounceTimer);
                doneDebounceTimer = null;
            }
            isWorkingState = true;
            sendStatus('working', `ChatGPT generating [${thinkingState.reason}]`);
        } else if (errorElem && errorElem.textContent.trim().length > 0) {
            if (doneDebounceTimer) {
                clearTimeout(doneDebounceTimer);
                doneDebounceTimer = null;
            }
            isWorkingState = false;
            sendStatus('blocked', 'ChatGPT error: ' + errorElem.textContent.trim().substring(0, 50));
        } else if (isWorkingState) {
            // Quiet Window Debounce (2.0s): Transition to Done after 2.0s of NO streaming activity
            if (!doneDebounceTimer) {
                doneDebounceTimer = setTimeout(() => {
                    doneDebounceTimer = null;
                    isWorkingState = false;
                    sendStatus('done', 'ChatGPT finished generating response!');
                    extractAndSendChatGPTResponse();
                }, 2000);
            }
        } else if (!lastStatus) {
            sendStatus('idle', 'ChatGPT Web idle');
        }
    }

    // Extract latest ChatGPT Assistant turn text for Bi-Directional Relay
    function extractAndSendChatGPTResponse() {
        const articles = document.querySelectorAll('article');
        if (articles.length === 0) return;

        let assistantText = '';
        for (let i = articles.length - 1; i >= 0; i--) {
            const art = articles[i];
            if (!art.querySelector('[data-message-author-role="user"]') && !art.innerText.includes('You said:')) {
                assistantText = art.innerText || art.textContent || '';
                if (assistantText.trim().length > 0) break;
            }
        }

        if (assistantText.trim().length === 0) {
            assistantText = articles[articles.length - 1].innerText || '';
        }

        if (assistantText.trim().length === 0) return;

        try {
            fetch('http://127.0.0.1:18888/relay/chatgpt-output', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text: assistantText })
            }).catch(() => {});
        } catch (e) {}
    }

    // Instant prompt submission listener
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
            const promptArea = document.querySelector('#prompt-textarea');
            if (promptArea && document.activeElement === promptArea) {
                lastNetworkChunkTime = Date.now();
                triggerImmediateWorkingState('Enter Key Submit');
            }
        }
    }, true);

    document.addEventListener('click', function(e) {
        const sendBtn = e.target.closest('button[data-testid="send-button"]') ||
                        e.target.closest('button[aria-label*="Send" i]');
        if (sendBtn) {
            lastNetworkChunkTime = Date.now();
            triggerImmediateWorkingState('Send Button Click');
        }
    }, true);

    // Output Relay Auto-Injector (Agent -> ChatGPT)
    function injectRelayText(text) {
        if (!text || text.trim().length === 0) return;

        const promptArea = document.querySelector('#prompt-textarea') ||
                           document.querySelector('div[contenteditable="true"]') ||
                           document.querySelector('textarea');

        if (promptArea) {
            console.log('📲 Injecting relayed output into ChatGPT prompt:', text.substring(0, 50) + '...');
            promptArea.focus();

            if (promptArea.tagName.toLowerCase() === 'textarea') {
                promptArea.value = text;
                promptArea.dispatchEvent(new Event('input', { bubbles: true }));
                promptArea.dispatchEvent(new Event('change', { bubbles: true }));
            } else {
                promptArea.innerHTML = '<p>' + text.replace(/\n/g, '<br>') + '</p>';
                promptArea.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            }

            setTimeout(() => {
                const sendBtn = document.querySelector('button[data-testid="send-button"]') ||
                                document.querySelector('button[aria-label*="Send" i]') ||
                                document.querySelector('button[aria-label*="send" i]');
                if (sendBtn && !sendBtn.disabled) {
                    sendBtn.click();
                    lastNetworkChunkTime = Date.now();
                    triggerImmediateWorkingState('Auto-Relay Submit');
                }
            }, 500);
        }
    }

    function checkPendingRelay() {
        try {
            fetch('http://127.0.0.1:18888/relay/pending')
                .then(res => {
                    if (res.ok) return res.json();
                    return null;
                })
                .then(data => {
                    if (data && data.hasPending && data.text) {
                        injectRelayText(data.text);
                    }
                })
                .catch(() => {});
        } catch (e) {}
    }

    setInterval(checkChatGPTState, 300);
    setInterval(checkPendingRelay, 1500);

    const observer = new MutationObserver(checkChatGPTState);
    if (document.body) {
        observer.observe(document.body, { childList: true, subtree: true });
    }

    console.log('🚀 AgentSignalBar Non-Flickering ChatGPT Engine Active!');
})();
