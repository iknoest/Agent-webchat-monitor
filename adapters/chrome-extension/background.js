// Chrome Extension Service Worker Background Script (Single Authoritative Per-Tab State Owner)
const SIGNAL_URL = 'http://127.0.0.1:18888/status';
const tabRegistry = new Map(); // tabId -> PerTabRecord
let lastSentPayloadJSON = '';

const STABILIZATION_MS = 5000;

function getOrCreateTabRecord(tabId) {
    if (!tabRegistry.has(tabId)) {
        tabRegistry.set(tabId, {
            tabId: tabId,
            status: 'idle',
            candidateStatus: null,
            lastSeenSeq: 0,
            lastSeenTimestamp: 0,
            debounceTimer: null,
            sessionTitle: 'ChatGPT Web',
            webLink: 'https://chatgpt.com',
            generationStart: 0,
            completionTime: 0,
            lastReason: ''
        });
    }
    return tabRegistry.get(tabId);
}

function acknowledgeTab(tabId) {
    if (!tabId) return false;
    const targetId = parseInt(tabId, 10);
    if (tabRegistry.has(targetId)) {
        const record = tabRegistry.get(targetId);
        if (record.debounceTimer) {
            clearTimeout(record.debounceTimer);
            record.debounceTimer = null;
        }
        record.status = 'idle';
        record.candidateStatus = null;
        console.log(`[StateTrace] Tab ${targetId} explicitly acknowledged -> status: idle`);
        aggregateAndSend();
        return true;
    }
    return false;
}

function processRawSignal(tabId, payload, opts = {}) {
    if (!tabId) return;
    const record = getOrCreateTabRecord(tabId);

    // Reject stale or out-of-order signals
    if (payload.seq && record.lastSeenSeq && payload.seq <= record.lastSeenSeq) {
        return;
    }
    if (payload.timestamp && record.lastSeenTimestamp && payload.timestamp < record.lastSeenTimestamp) {
        return;
    }

    record.lastSeenSeq = payload.seq || (record.lastSeenSeq + 1);
    record.lastSeenTimestamp = payload.timestamp || Date.now();
    if (payload.reason !== undefined) {
        record.lastReason = payload.reason;
    }

    if (payload.webLink && record.webLink !== payload.webLink) {
        if (record.debounceTimer) {
            clearTimeout(record.debounceTimer);
            record.debounceTimer = null;
        }
        record.webLink = payload.webLink;
        record.sessionTitle = payload.sessionTitle || 'ChatGPT Web';
        record.status = payload.active ? 'working' : (payload.status === 'blocked' ? 'blocked' : 'idle');
        record.candidateStatus = null;
        record.generationStart = payload.active ? (payload.timestamp || Date.now()) : 0;
    } else {
        if (payload.sessionTitle) record.sessionTitle = payload.sessionTitle;
        if (payload.webLink) record.webLink = payload.webLink;
    }

    const prevStatus = record.status;
    const isImmediate = !!payload.immediate || !!opts.immediate || !!payload.bypassStabilization;

    if (payload.status === 'blocked' || payload.interrupted) {
        // Candidate Blocked signal
        if (record.debounceTimer) {
            clearTimeout(record.debounceTimer);
            record.debounceTimer = null;
        }

        if (record.status === 'blocked') {
            aggregateAndSend();
            return;
        }

        if (isImmediate) {
            record.status = 'blocked';
            record.candidateStatus = null;
            console.log(`[StateTrace] TS: ${record.lastSeenTimestamp} | tabId: ${tabId} | raw: interrupted=true -> next: blocked (immediate) | owner: background.js`);
        } else if (record.candidateStatus !== 'blocked') {
            record.candidateStatus = 'blocked';
            record.debounceTimer = setTimeout(() => {
                record.debounceTimer = null;
                record.candidateStatus = null;
                record.status = 'blocked';
                console.log(`[StateTrace] TS: ${Date.now()} | tabId: ${tabId} | candidate blocked persisted 5s -> committed: blocked | owner: background.js`);
                aggregateAndSend();
            }, STABILIZATION_MS);
        }
    } else if (payload.active) {
        // Positive Working signal cancels any pending candidate timer immediately!
        if (record.debounceTimer) {
            clearTimeout(record.debounceTimer);
            record.debounceTimer = null;
        }
        record.candidateStatus = null;

        if (record.status !== 'working') {
            record.status = 'working';
            record.generationStart = payload.timestamp || Date.now();
            console.log(`[StateTrace] TS: ${record.lastSeenTimestamp} | tabId: ${tabId} | raw: active=true | prev: ${prevStatus} -> next: working | owner: background.js`);
        }
    } else {
        // No active generation signal, no interrupted signal
        if (record.status === 'working') {
            if (!record.debounceTimer) {
                const delay = isImmediate ? 0 : STABILIZATION_MS;
                if (delay === 0) {
                    record.status = 'done';
                    record.completionTime = Date.now();
                    aggregateAndSend();
                    return;
                }
                record.candidateStatus = 'done';
                record.debounceTimer = setTimeout(() => {
                    record.debounceTimer = null;
                    record.candidateStatus = null;
                    const beforeDone = record.status;
                    record.status = 'done';
                    record.completionTime = Date.now();
                    console.log(`[StateTrace] TS: ${record.completionTime} | tabId: ${tabId} | raw: active=false (quiet 5s) | prev: ${beforeDone} -> next: done | owner: background.js`);
                    aggregateAndSend();
                }, delay);
            }
        } else if (record.status === 'blocked') {
            // Blocked recovery: Underlying condition disappeared!
            if (record.debounceTimer) {
                clearTimeout(record.debounceTimer);
                record.debounceTimer = null;
            }
            record.candidateStatus = null;

            if (record.generationStart > 0) {
                // Terminal output evidence present: transition to done after 5s quiet or immediate
                const delay = isImmediate ? 0 : STABILIZATION_MS;
                if (delay === 0) {
                    record.status = 'done';
                    record.completionTime = Date.now();
                } else {
                    record.candidateStatus = 'done';
                    record.debounceTimer = setTimeout(() => {
                        record.debounceTimer = null;
                        record.candidateStatus = null;
                        record.status = 'done';
                        record.completionTime = Date.now();
                        console.log(`[StateTrace] TS: ${record.completionTime} | tabId: ${tabId} | blocked recovery (quiet 5s) -> next: done | owner: background.js`);
                        aggregateAndSend();
                    }, delay);
                }
            } else {
                record.status = 'idle';
                console.log(`[StateTrace] TS: ${Date.now()} | tabId: ${tabId} | blocked recovery (no output) -> next: idle | owner: background.js`);
            }
        } else if (record.candidateStatus === 'blocked') {
            // Candidate blocked canceled before 5s persistence
            if (record.debounceTimer) {
                clearTimeout(record.debounceTimer);
                record.debounceTimer = null;
            }
            record.candidateStatus = null;
        }
    }

    aggregateAndSend();
}

let stateRevision = 0;

function bumpStateRevision() {
    stateRevision++;
    return stateRevision;
}

function computeOverallStatus(tabs, registryMap, nowOverride) {
    let hasWorking = false;
    let hasBlocked = false;
    let workingCount = 0;
    let doneCount = 0;
    let workingTab = null;
    let blockedTab = null;
    let doneTab = null;
    let activeChromeTab = null;
    let openTabsList = [];

    for (const tab of tabs) {
        const tabId = tab.id;
        const record = registryMap.get(tabId) || { status: 'idle' };
        const cleanTitle = record.sessionTitle || (tab.title ? tab.title.replace('- ChatGPT', '').trim() : 'ChatGPT Web');
        const cleanUrl = record.webLink || tab.url || 'https://chatgpt.com';
        const isTabActive = !!tab.active;

        let badge = '⚪';
        if (record.status === 'working') {
            badge = '🟡';
            hasWorking = true;
            workingCount++;
        } else if (record.status === 'blocked') {
            badge = '🔴';
            hasBlocked = true;
        } else if (record.status === 'done') {
            badge = '🟢';
            doneCount++;
        }

        const item = {
            tabId: tabId,
            title: cleanTitle,
            url: cleanUrl,
            status: record.status,
            active: isTabActive,
            badge: badge,
            generationStart: record.generationStart || 0,
            completionTime: record.completionTime || 0,
            sensorReason: record.lastReason || ''
        };

        if (record.status === 'working' && !workingTab) workingTab = item;
        if (record.status === 'blocked' && !blockedTab) blockedTab = item;
        if (record.status === 'done' && !doneTab) doneTab = item;

        openTabsList.push(item);
        if (isTabActive) {
            activeChromeTab = item;
        }
    }

    let overallStatus = 'idle';
    let sessionCount = Math.max(1, openTabsList.length);

    if (hasBlocked) {
        overallStatus = 'blocked';
    } else if (hasWorking) {
        overallStatus = 'working';
    } else if (doneCount > 0) {
        overallStatus = 'done';
    }

    // Target Selection Priority: Blocked Tab > Working Tab > Done Tab > Active Chrome Tab > First Tab
    let target = activeChromeTab;
    if (overallStatus === 'blocked' && blockedTab) {
        target = blockedTab;
    } else if (overallStatus === 'working' && workingTab) {
        target = workingTab;
    } else if (overallStatus === 'done' && doneTab) {
        target = doneTab;
    } else if (!target && openTabsList.length > 0) {
        target = openTabsList[0];
    }

    return {
        overallStatus,
        workingCount,
        doneCount,
        sessionCount,
        activeTitle: target ? target.title : 'ChatGPT Web',
        activeUrl: target ? target.url : 'https://chatgpt.com',
        targetTabId: target ? target.tabId : null,
        openTabs: openTabsList,
        revision: stateRevision
    };
}

function handleExactFocus(focusTabId) {
    if (!focusTabId || focusTabId === 'null') return;
    const targetTabId = parseInt(focusTabId, 10);
    if (!targetTabId || isNaN(targetTabId)) return;
    if (typeof chrome === 'undefined' || !chrome.tabs) return;

    chrome.tabs.get(targetTabId, (tab) => {
        if ((typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.lastError) || !tab) {
            console.error(`[AgentSignalBar] Exact focus failed: Tab ${targetTabId} not found`);
            return;
        }
        chrome.tabs.update(targetTabId, { active: true }, (updatedTab) => {
            if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.lastError) {
                console.error(`[AgentSignalBar] Exact focus update failed for tab ${targetTabId}:`, chrome.runtime.lastError);
                return;
            }
            if (updatedTab && updatedTab.windowId && chrome.windows) {
                chrome.windows.update(updatedTab.windowId, { focused: true });
            }
        });
    });
}

async function checkFocusCommand() {
    try {
        if (typeof fetch === 'undefined') return;
        const res = await fetch('http://127.0.0.1:18888/focus', { cache: 'no-store' });
        if (res && res.ok) {
            const data = await res.json();
            if (data && data.focusTabId) {
                handleExactFocus(data.focusTabId);
            }
        }
    } catch (e) {
        // Ignored
    }
}

async function reinjectContentScriptsInExistingTabs() {
    try {
        if (typeof chrome === 'undefined' || !chrome.tabs || !chrome.scripting) return;
        const tabs = await chrome.tabs.query({ url: [
            "*://chatgpt.com/*",
            "*://*.chatgpt.com/*",
            "*://chat.openai.com/*",
            "*://*.chat.openai.com/*"
        ] });

        for (const tab of tabs) {
            if (tab.id) {
                chrome.scripting.executeScript({
                    target: { tabId: tab.id },
                    files: ['content.js']
                }).catch(() => {});
            }
        }
    } catch (err) {
        console.error('[AgentSignalBar Background] Script reinjection error:', err);
    }
}

let isFetchInFlight = false;
let pendingPayloadJSON = null;
let retryTimer = null;

async function aggregateAndSend() {
    try {
        if (typeof chrome === 'undefined' || !chrome.tabs) return false;
        const tabs = await chrome.tabs.query({ url: "*://*.chatgpt.com/*" });
        const res = computeOverallStatus(tabs, tabRegistry);

        const payload = {
            agent: 'chatgpt',
            status: res.overallStatus,
            detail: `${res.openTabs.length} ChatGPT tab(s) (${res.workingCount} generating)`,
            sessionCount: res.sessionCount,
            sessionTitle: res.activeTitle,
            targetTabId: res.targetTabId,
            webLink: res.activeUrl,
            openTabs: res.openTabs
        };

        const payloadJSON = JSON.stringify(payload);
        if (payloadJSON === lastSentPayloadJSON && !pendingPayloadJSON) {
            return false; // Suppress redundant HTTP publication of already delivered payload
        }

        if (isFetchInFlight) {
            pendingPayloadJSON = payloadJSON; // Supersede pending with newest payload
            return false;
        }

        return await executeFetchPayload(payloadJSON);

    } catch (err) {
        console.error('[AgentSignalBar Background] Query error:', err);
        return false;
    }
}

async function executeFetchPayload(payloadJSON) {
    isFetchInFlight = true;
    if (retryTimer) {
        clearTimeout(retryTimer);
        retryTimer = null;
    }

    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const fetchTimer = controller ? setTimeout(() => controller.abort(), 5000) : null;

    try {
        const fetchOpts = {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: payloadJSON
        };
        if (controller) fetchOpts.signal = controller.signal;

        const res = await fetch(SIGNAL_URL, fetchOpts);
        if (fetchTimer) clearTimeout(fetchTimer);

        if (res && res.ok) {
            lastSentPayloadJSON = payloadJSON;
            const nextPending = pendingPayloadJSON;
            pendingPayloadJSON = null;
            isFetchInFlight = false;

            try {
                const resData = await res.json();
                if (resData && resData.focusTabId) {
                    handleExactFocus(resData.focusTabId);
                }
            } catch (jsonErr) {}

            if (nextPending && nextPending !== lastSentPayloadJSON) {
                setTimeout(aggregateAndSend, 0);
            }
            return true;
        } else {
            throw new Error(`HTTP ${res ? res.status : 'error'}`);
        }

    } catch (err) {
        if (fetchTimer) clearTimeout(fetchTimer);
        isFetchInFlight = false;
        // Do NOT update lastSentPayloadJSON on failure
        if (!retryTimer) {
            retryTimer = setTimeout(() => {
                retryTimer = null;
                aggregateAndSend();
            }, 1000);
        }
        return false;
    }
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        computeOverallStatus,
        processRawSignal,
        acknowledgeTab,
        reinjectContentScriptsInExistingTabs,
        aggregateAndSend,
        handleExactFocus,
        checkFocusCommand,
        tabRegistry,
        getLastSentPayloadJSON: () => lastSentPayloadJSON,
        getIsFetchInFlight: () => isFetchInFlight,
        getPendingPayloadJSON: () => pendingPayloadJSON,
        resetLastSentPayload: () => {
            lastSentPayloadJSON = '';
            isFetchInFlight = false;
            pendingPayloadJSON = null;
            if (retryTimer) {
                clearTimeout(retryTimer);
                retryTimer = null;
            }
        }
    };
}


if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
    if (chrome.runtime.onInstalled) {
        chrome.runtime.onInstalled.addListener(() => {
            reinjectContentScriptsInExistingTabs();
        });
    }
    if (chrome.runtime.onStartup) {
        chrome.runtime.onStartup.addListener(() => {
            reinjectContentScriptsInExistingTabs();
        });
    }
    reinjectContentScriptsInExistingTabs();

    chrome.runtime.onMessage.addListener((message, sender) => {
        if (message.type === 'RAW_GENERATION_SIGNAL' && sender && sender.tab) {
            processRawSignal(sender.tab.id, message.payload);
        } else if (message.type === 'STATUS_UPDATE' && sender && sender.tab) {
            // Legacy compatibility fallback
            const isWorking = message.payload.status === 'working';
            processRawSignal(sender.tab.id, {
                seq: Date.now(),
                timestamp: Date.now(),
                active: isWorking,
                sessionTitle: message.payload.sessionTitle,
                webLink: message.payload.webLink
            });
        }
    });

    if (chrome.tabs) {
        chrome.tabs.onCreated.addListener((tab) => {
            if (tab.id && tab.url && tab.url.includes('chatgpt.com')) {
                if (chrome.scripting) {
                    chrome.scripting.executeScript({
                        target: { tabId: tab.id },
                        files: ['content.js']
                    }).catch(() => {});
                }
                aggregateAndSend();
            }
        });

        chrome.tabs.onRemoved.addListener((tabId) => {
            if (tabRegistry.has(tabId)) {
                const rec = tabRegistry.get(tabId);
                if (rec.debounceTimer) clearTimeout(rec.debounceTimer);
                tabRegistry.delete(tabId);
            }
            aggregateAndSend();
        });

        chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
            if (tab.url && tab.url.includes('chatgpt.com')) {
                const rec = getOrCreateTabRecord(tabId);
                if (changeInfo.url && changeInfo.url !== rec.webLink) {
                    if (rec.debounceTimer) clearTimeout(rec.debounceTimer);
                    rec.debounceTimer = null;
                    rec.webLink = changeInfo.url;
                    rec.sessionTitle = tab.title ? tab.title.replace('- ChatGPT', '').trim() : 'ChatGPT Web';
                    rec.status = 'idle';
                    rec.candidateStatus = null;
                    rec.generationStart = 0;
                } else if (tab.title) {
                    rec.sessionTitle = tab.title.replace('- ChatGPT', '').trim();
                }

                if (changeInfo.status === 'complete' && chrome.scripting) {
                    chrome.scripting.executeScript({
                        target: { tabId: tabId },
                        files: ['content.js']
                    }).catch(() => {});
                }
                aggregateAndSend();
            }
        });

        chrome.tabs.onActivated.addListener(() => {
            aggregateAndSend();
        });
    }

    setInterval(aggregateAndSend, 2000);
    setInterval(checkFocusCommand, 500);
}
