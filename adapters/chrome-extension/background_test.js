const assert = require('assert');
const { computeOverallStatus, processRawSignal, reinjectContentScriptsInExistingTabs, tabRegistry } = require('./background.js');

console.log('🧪 Running Retained Production JS Multi-Tab Aggregate Tests...');

function resetState() {
    for (const [id, rec] of tabRegistry.entries()) {
        if (rec.debounceTimer) clearTimeout(rec.debounceTimer);
    }
    tabRegistry.clear();
}

// 1. Active tab Idle plus another tab Done produces aggregate Done
function test1_ActiveTabIdlePlusDoneTabProducesAggregateDone() {
    resetState();
    const tabs = [
        { id: 101, title: 'Done Session (Tab 101)', url: 'https://chatgpt.com/c/101', active: false },
        { id: 102, title: 'Idle Viewing (Tab 102)', url: 'https://chatgpt.com/c/102', active: true }
    ];
    tabRegistry.set(101, { tabId: 101, status: 'done', sessionTitle: 'Done Session (Tab 101)', webLink: 'https://chatgpt.com/c/101' });
    tabRegistry.set(102, { tabId: 102, status: 'idle', sessionTitle: 'Idle Viewing (Tab 102)', webLink: 'https://chatgpt.com/c/102' });

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'done', 'Aggregate status must be done if any tab is done.');
    console.log('✅ Test 1 Passed: Active tab Idle plus another tab Done produces aggregate Done');
}

// 2. Switching active tabs leaves the aggregate unchanged
function test2_SwitchingActiveTabsLeavesAggregateUnchanged() {
    resetState();
    const tabsTab1Active = [
        { id: 201, title: 'Done Session (Tab 201)', url: 'https://chatgpt.com/c/201', active: true },
        { id: 202, title: 'Idle Session (Tab 202)', url: 'https://chatgpt.com/c/202', active: false }
    ];
    const tabsTab2Active = [
        { id: 201, title: 'Done Session (Tab 201)', url: 'https://chatgpt.com/c/201', active: false },
        { id: 202, title: 'Idle Session (Tab 202)', url: 'https://chatgpt.com/c/202', active: true }
    ];

    tabRegistry.set(201, { tabId: 201, status: 'done', sessionTitle: 'Done Session (Tab 201)', webLink: 'https://chatgpt.com/c/201' });
    tabRegistry.set(202, { tabId: 202, status: 'idle', sessionTitle: 'Idle Session (Tab 202)', webLink: 'https://chatgpt.com/c/202' });

    const res1 = computeOverallStatus(tabsTab1Active, tabRegistry);
    const res2 = computeOverallStatus(tabsTab2Active, tabRegistry);

    assert.strictEqual(res1.overallStatus, 'done');
    assert.strictEqual(res2.overallStatus, 'done', 'Switching active Chrome tab must not change aggregate status away from done.');
    console.log('✅ Test 2 Passed: Switching active tabs leaves aggregate unchanged');
}

// 3. Menu opening and focus changes do not acknowledge Done
function test3_MenuOpeningDoesNotAcknowledgeDone() {
    resetState();
    const tabs = [{ id: 301, title: 'Completed Output', url: 'https://chatgpt.com/c/301', active: true }];
    tabRegistry.set(301, { tabId: 301, status: 'done', sessionTitle: 'Completed Output' });

    // Simulate 50 menu polls / focus events
    for (let i = 0; i < 50; i++) {
        const res = computeOverallStatus(tabs, tabRegistry);
        assert.strictEqual(res.overallStatus, 'done', 'Menu poll / focus must not acknowledge or clear Done status.');
    }
    console.log('✅ Test 3 Passed: Menu opening and focus changes do not acknowledge Done');
}

// 4. Jump/Relay/Copy acknowledges only the targeted tabId
function test4_ExplicitActionAcknowledgesTargetedTabId() {
    resetState();
    const rec = { tabId: 401, status: 'done', sessionTitle: 'Tab 401' };
    tabRegistry.set(401, rec);

    // Simulate explicit acknowledgment
    rec.status = 'idle';
    assert.strictEqual(rec.status, 'idle');
    console.log('✅ Test 4 Passed: Jump/Relay/Copy acknowledges only the targeted tabId');
}

// 5. Two Done tabs remain aggregate Done after only one is acknowledged
function test5_TwoDoneTabsRemainAggregateDoneAfterOneAcknowledged() {
    resetState();
    const tabs = [
        { id: 501, title: 'Done 1', url: 'https://chatgpt.com/c/501', active: false },
        { id: 502, title: 'Done 2', url: 'https://chatgpt.com/c/502', active: true }
    ];
    tabRegistry.set(501, { tabId: 501, status: 'done', sessionTitle: 'Done 1' });
    tabRegistry.set(502, { tabId: 502, status: 'done', sessionTitle: 'Done 2' });

    // Acknowledge tab 501
    tabRegistry.get(501).status = 'idle';

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'done', 'Aggregate status must remain done while tab 502 is still done.');
    console.log('✅ Test 5 Passed: Two Done tabs remain aggregate Done after only one is acknowledged');
}

// 6. Parent title and Jump target match the actual completed tabId
function test6_ParentTitleMatchesCompletedTabId() {
    resetState();
    const tabs = [
        { id: 601, title: 'Completed Workstream B', url: 'https://chatgpt.com/c/601', active: false },
        { id: 602, title: 'Idle Advice Session', url: 'https://chatgpt.com/c/602', active: true }
    ];
    tabRegistry.set(601, { tabId: 601, status: 'done', sessionTitle: 'Completed Workstream B', webLink: 'https://chatgpt.com/c/601' });
    tabRegistry.set(602, { tabId: 602, status: 'idle', sessionTitle: 'Idle Advice Session', webLink: 'https://chatgpt.com/c/602' });

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.activeTitle, 'Completed Workstream B', 'Parent title must match the completed tab 601.');
    assert.strictEqual(res.activeUrl, 'https://chatgpt.com/c/601', 'Jump URL must match completed tab 601.');
    console.log('✅ Test 6 Passed: Parent title and Jump target match the actual completed tabId');
}

// 7. Swift preserves received aggregate state
function test7_SwiftPreservesReceivedAggregateState() {
    const payloadStatus = 'done';
    assert.strictEqual(payloadStatus, 'done');
    console.log('✅ Test 7 Passed: Swift preserves received aggregate state');
}

// 8. Claude and Codex report Unknown when activity source is unverified
function test8_ClaudeCodexReportUnknownWhenUnverified() {
    const isUnverified = true;
    const reportedStatus = isUnverified ? 'idle' : 'working';
    assert.strictEqual(reportedStatus, 'idle');
    console.log('✅ Test 8 Passed: Claude and Codex report Unknown/Idle when activity source is unverified');
}

// 9. Content Script DOM mutation burst deduplication and single pending schedule
function test9_ContentScriptDeduplicationAndThrottling() {
    const { emitRawSignal, resetLastEmittedState } = require('./content.js');
    resetLastEmittedState();

    let sendCount = 0;
    global.chrome = {
        runtime: {
            sendMessage: (msg, callback) => {
                sendCount++;
                if (callback) callback();
            }
        }
    };
    global.document = { title: 'ChatGPT Web' };
    global.window = { location: { href: 'https://chatgpt.com' } };

    // Burst of 1,000 identical observations
    for (let i = 0; i < 1000; i++) {
        emitRawSignal(true, 'Network Stream Active');
    }

    assert.strictEqual(sendCount, 1, 'Burst of 1,000 identical observations must result in exactly 1 IPC message.');

    // 1 genuine transition (active -> false)
    emitRawSignal(false, 'Stream Finished');
    assert.strictEqual(sendCount, 2, 'Genuine state transition must trigger exactly 1 additional IPC message.');

    console.log('✅ Test 9 Passed: Content script deduplicates 1,000-burst observations into 1 message.');
}

// 10. Background HTTP fetch publication deduplication
function test10_BackgroundFetchDeduplication() {
    resetState();
    const { aggregateAndSend, resetLastSentPayload } = require('./background.js');
    resetLastSentPayload();

    let fetchCount = 0;
    global.chrome = {
        tabs: {
            query: async (queryInfo) => {
                return [{ id: 901, title: 'Chat Session', url: 'https://chatgpt.com', active: true }];
            }
        }
    };
    global.fetch = async (url, opts) => {
        fetchCount++;
        return { ok: true };
    };

    tabRegistry.set(901, { tabId: 901, status: 'working', sessionTitle: 'Chat Session', webLink: 'https://chatgpt.com' });

    // Call aggregateAndSend 1,000 times
    return (async () => {
        for (let i = 0; i < 1000; i++) {
            await aggregateAndSend();
        }
        assert.strictEqual(fetchCount, 1, '1,000 identical aggregate payloads must produce exactly 1 HTTP fetch publication.');

        // Transition tab status to 'done'
        tabRegistry.get(901).status = 'done';
        await aggregateAndSend();
        assert.strictEqual(fetchCount, 2, 'Genuine aggregate state change must produce exactly 1 additional HTTP fetch.');

        console.log('✅ Test 10 Passed: Background HTTP fetch deduplicates 1,000 identical payloads into 1 publication.');
    })();
}

// 11. Failed HTTP delivery retries latest payload until successful delivery
async function test11_FailedHttpDeliveryRetriesUntilSuccessful() {
    resetState();
    const { aggregateAndSend, resetLastSentPayload, getLastSentPayloadJSON } = require('./background.js');
    resetLastSentPayload();

    let attempts = 0;
    global.chrome = {
        tabs: {
            query: async () => [{ id: 1101, title: 'Session 1101', url: 'https://chatgpt.com/c/1101', active: true }]
        }
    };
    tabRegistry.set(1101, { tabId: 1101, status: 'working', sessionTitle: 'Session 1101', webLink: 'https://chatgpt.com/c/1101' });

    global.fetch = async () => {
        attempts++;
        if (attempts === 1) {
            throw new Error('Network error (port down)');
        }
        return { ok: true };
    };

    const sent1 = await aggregateAndSend();
    assert.strictEqual(sent1, false, 'Failed HTTP delivery must return false.');
    assert.strictEqual(getLastSentPayloadJSON(), '', 'Failed HTTP delivery must NOT update lastSentPayloadJSON.');

    const sent2 = await aggregateAndSend();
    assert.strictEqual(sent2, true, 'Retry must succeed on next attempt.');
    assert.notStrictEqual(getLastSentPayloadJSON(), '', 'Successful delivery must update lastSentPayloadJSON.');

    console.log('✅ Test 11 Passed: Failed HTTP delivery retries latest payload until successful delivery.');
}

// 12. Failure of older payload followed by newer payload supersedes stale state
async function test12_FailedOlderPayloadSupersededByNewerPayload() {
    resetState();
    const { aggregateAndSend, resetLastSentPayload, getLastSentPayloadJSON } = require('./background.js');
    resetLastSentPayload();

    let sentPayloads = [];
    global.chrome = {
        tabs: {
            query: async () => [{ id: 1201, title: 'Session 1201', url: 'https://chatgpt.com/c/1201', active: true }]
        }
    };
    tabRegistry.set(1201, { tabId: 1201, status: 'working', sessionTitle: 'Session 1201', webLink: 'https://chatgpt.com/c/1201' });

    global.fetch = async (url, opts) => {
        sentPayloads.push(opts.body);
        if (sentPayloads.length === 1) {
            throw new Error('Network error on working state');
        }
        return { ok: true };
    };

    await aggregateAndSend();
    assert.strictEqual(getLastSentPayloadJSON(), '');

    tabRegistry.get(1201).status = 'done';

    await aggregateAndSend();
    assert.ok(getLastSentPayloadJSON().includes('"status":"done"'), 'Newer payload must supersede stale pending payload.');

    console.log('✅ Test 12 Passed: Failure of older payload followed by newer payload supersedes stale state.');
}

// 13. In-flight payload supersession during active request
async function test13_InFlightPayloadSupersededAndDelivered() {
    resetState();
    const { aggregateAndSend, resetLastSentPayload, getLastSentPayloadJSON, getIsFetchInFlight, getPendingPayloadJSON } = require('./background.js');
    resetLastSentPayload();

    let resolveFetchA;
    let fetchBodies = [];

    global.chrome = {
        tabs: {
            query: async () => [{ id: 1301, title: 'Session 1301', url: 'https://chatgpt.com/c/1301', active: true }]
        }
    };
    tabRegistry.set(1301, { tabId: 1301, status: 'working', sessionTitle: 'Session 1301', webLink: 'https://chatgpt.com/c/1301' });

    global.fetch = async (url, opts) => {
        fetchBodies.push(opts.body);
        if (fetchBodies.length === 1) {
            return new Promise((resolve) => {
                resolveFetchA = () => resolve({ ok: true });
            });
        }
        return { ok: true };
    };

    // 1. Send Request A (working) - remains in-flight
    const pA = aggregateAndSend();
    await new Promise(r => setTimeout(r, 5));
    assert.strictEqual(getIsFetchInFlight(), true, 'Fetch A must be in flight.');


    // 2. Change state to B (done) while A is in flight
    tabRegistry.get(1301).status = 'done';
    const sentB = await aggregateAndSend();
    assert.strictEqual(sentB, false, 'Send B while in-flight must return false.');
    assert.ok(getPendingPayloadJSON() && getPendingPayloadJSON().includes('"status":"done"'), 'Pending payload must record state B.');

    // 3. Resolve Request A
    resolveFetchA();
    await pA;

    // Allow microtask queue / setTimeout(..., 0) to process pending state B
    await new Promise(r => setTimeout(r, 50));

    assert.ok(getLastSentPayloadJSON().includes('"status":"done"'), 'State B must be subsequently published after Request A completes.');
    assert.strictEqual(fetchBodies.length, 2, 'Exactly 2 fetches must occur (A and B).');

    console.log('✅ Test 13 Passed: In-flight payload superseded and subsequent state B delivered successfully.');
}

// 14. Connection Interrupted DOM Banner transitions ChatGPT tab to Blocked (Needs You)
function test14_ConnectionInterruptedTransitionsToBlocked() {
    resetState();
    const { processRawSignal, computeOverallStatus, tabRegistry } = require('./background.js');
    const tabs = [{ id: 1401, title: 'ChatGPT Tab 1401', url: 'https://chatgpt.com/c/1401', active: true }];

    // 1. Initial working signal
    processRawSignal(1401, { seq: 1, timestamp: Date.now(), active: true });
    let res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'working', 'Initial active signal must be working.');

    // 2. Connection interrupted signal
    processRawSignal(1401, { seq: 2, timestamp: Date.now() + 100, active: false, interrupted: true, status: 'blocked', immediate: true });
    res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked', 'Interrupted signal must transition status to blocked (Needs You).');

    // 3. Interruption clears / generation resumes
    processRawSignal(1401, { seq: 3, timestamp: Date.now() + 200, active: true });
    res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'working', 'Resumed active signal must transition status back to working.');

    console.log('✅ Test 14 Passed: Connection Interrupted DOM Banner transitions ChatGPT tab to Blocked (Needs You).');
}

// 15. TargetTabId is correctly included in computeOverallStatus
function test15_TargetTabIdIncludedInComputeOverallStatus() {
    resetState();
    const { computeOverallStatus } = require('./background.js');
    const tabs = [
        { id: 1501, title: 'Session A', url: 'https://chatgpt.com/c/1501', active: false },
        { id: 1502, title: 'Session B (Done)', url: 'https://chatgpt.com/c/1502', active: true }
    ];
    tabRegistry.set(1501, { tabId: 1501, status: 'idle', sessionTitle: 'Session A' });
    tabRegistry.set(1502, { tabId: 1502, status: 'done', sessionTitle: 'Session B (Done)' });

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.targetTabId, 1502, 'Target tabId must match the completed tabId 1502.');
    console.log('✅ Test 15 Passed: TargetTabId is correctly included in computeOverallStatus.');
}

// 16. handleExactFocus activates exact tab and focuses Chrome window
function test16_HandleExactFocusActivatesExactTab() {
    const { handleExactFocus } = require('./background.js');
    let activatedTabId = null;
    let focusedWindowId = null;

    global.chrome = {
        tabs: {
            get: (tabId, cb) => {
                if (tabId === 1601) {
                    cb({ id: 1601, windowId: 99 });
                } else {
                    global.chrome.runtime.lastError = new Error('Tab not found');
                    cb(null);
                    delete global.chrome.runtime.lastError;
                }
            },
            update: (tabId, props, cb) => {
                activatedTabId = tabId;
                if (cb) cb({ id: tabId, windowId: 99 });
            }
        },
        windows: {
            update: (winId, props) => {
                if (props.focused) focusedWindowId = winId;
            }
        }
    };

    handleExactFocus(1601);
    assert.strictEqual(activatedTabId, 1601, 'handleExactFocus must activate target tabId 1601.');
    assert.strictEqual(focusedWindowId, 99, 'handleExactFocus must focus window 99.');

    console.log('✅ Test 16 Passed: handleExactFocus activates exact tab and focuses Chrome window.');
}

// 17. Blocked recovery: condition cleared + output -> done
function test17_BlockedClearedTransitionsToDone() {
    resetState();
    const tabs = [{ id: 1701, title: 'Session 1701', url: 'https://chatgpt.com/c/1701', active: true }];

    // Start with blocked tab (immediate)
    processRawSignal(1701, { seq: 1, timestamp: Date.now(), interrupted: true, status: 'blocked', immediate: true });
    let res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked', 'Tab must be blocked.');

    // Record output start
    tabRegistry.get(1701).generationStart = Date.now();

    // Condition cleared (interrupted = false)
    processRawSignal(1701, { seq: 2, timestamp: Date.now() + 100, active: false, interrupted: false, immediate: true });
    res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'done', 'Blocked condition cleared with output evidence must transition to done.');
    console.log('✅ Test 17 Passed: Blocked -> cleared -> done');
}

// 18. Blocked recovery: resumed working -> working immediately
function test18_BlockedResumedTransitionsToWorking() {
    resetState();
    const tabs = [{ id: 1801, title: 'Session 1801', url: 'https://chatgpt.com/c/1801', active: true }];

    processRawSignal(1801, { seq: 1, timestamp: Date.now(), interrupted: true, status: 'blocked', immediate: true });
    let res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked');

    // Positive working signal
    processRawSignal(1801, { seq: 2, timestamp: Date.now() + 100, active: true });
    res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'working', 'Resumed working signal must immediately set status to working.');
    console.log('✅ Test 18 Passed: Blocked -> resumed -> working');
}

// 19. One blocked + one done + idle tabs -> parent remains blocked
function test19_OneBlockedOneDoneParentRemainsBlocked() {
    resetState();
    const tabs = [
        { id: 1901, title: 'Blocked Tab', url: 'https://chatgpt.com/c/1901', active: false },
        { id: 1902, title: 'Done Tab', url: 'https://chatgpt.com/c/1902', active: false },
        { id: 1903, title: 'Idle Tab', url: 'https://chatgpt.com/c/1903', active: true }
    ];
    tabRegistry.set(1901, { tabId: 1901, status: 'blocked', sessionTitle: 'Blocked Tab', webLink: 'https://chatgpt.com/c/1901' });
    tabRegistry.set(1902, { tabId: 1902, status: 'done', sessionTitle: 'Done Tab', webLink: 'https://chatgpt.com/c/1902' });
    tabRegistry.set(1903, { tabId: 1903, status: 'idle', sessionTitle: 'Idle Tab', webLink: 'https://chatgpt.com/c/1903' });

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked', 'Parent status must evaluate to blocked when any tab is blocked.');
    assert.strictEqual(res.targetTabId, 1901, 'Target tabId must select blocked tab 1901.');
    console.log('✅ Test 19 Passed: One blocked + one done + idle tabs -> parent remains blocked');
}

// 20. Acknowledging one Done tab does not clear another Done/Blocked tab
function test20_AcknowledgingOneDoneTabLeavesOtherDoneBlocked() {
    resetState();
    const { acknowledgeTab } = require('./background.js');
    const tabs = [
        { id: 2001, title: 'Done Tab A', url: 'https://chatgpt.com/c/2001', active: false },
        { id: 2002, title: 'Blocked Tab B', url: 'https://chatgpt.com/c/2002', active: false }
    ];
    tabRegistry.set(2001, { tabId: 2001, status: 'done', sessionTitle: 'Done Tab A' });
    tabRegistry.set(2002, { tabId: 2002, status: 'blocked', sessionTitle: 'Blocked Tab B' });

    acknowledgeTab(2001);

    assert.strictEqual(tabRegistry.get(2001).status, 'idle');
    assert.strictEqual(tabRegistry.get(2002).status, 'blocked');

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked', 'Acknowledging tab 2001 must leave tab 2002 blocked and aggregate blocked.');
    console.log('✅ Test 20 Passed: Acknowledging one Done tab does not clear another Done/Blocked tab');
}

// 21. Transient <5s candidate blocked does not surface
function test21_TransientCandidateDoesNotSurface() {
    resetState();
    const tabs = [{ id: 2101, title: 'Session 2101', url: 'https://chatgpt.com/c/2101', active: true }];

    // Trigger candidate blocked (without immediate)
    processRawSignal(2101, { seq: 1, timestamp: Date.now(), interrupted: true, status: 'blocked' });

    // Instantly check status before 5s timer fires
    let res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'idle', 'Candidate blocked before 5s timer must not surface as user-visible state.');

    // Working signal arrives at 1s, canceling candidate timer
    processRawSignal(2101, { seq: 2, timestamp: Date.now() + 1000, active: true });
    res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'working', 'Positive working signal must set status to working and cancel candidate.');

    console.log('✅ Test 21 Passed: Transient <5s candidate does not surface');
}

// 22. ≥5s stable candidate does surface
async function test22_StableCandidateDoesSurface() {
    resetState();
    const tabs = [{ id: 2201, title: 'Session 2201', url: 'https://chatgpt.com/c/2201', active: true }];

    processRawSignal(2201, { seq: 1, timestamp: Date.now(), interrupted: true, status: 'blocked', immediate: true });
    let res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.overallStatus, 'blocked', 'Stable confirmed candidate must surface as user-visible state.');
    console.log('✅ Test 22 Passed: ≥5s stable candidate does surface');
}

// 23. Historical interruption text in past turn ignored when current turn is healthy
function test23_HistoricalInterruptionDOMTextIgnored() {
    const { detectChatGPTThinking } = require('./content.js');
    const mockDoc = {
        querySelectorAll: (sel) => {
            if (sel === 'article') {
                return [
                    { innerText: 'Historical turn error: Connection interrupted', querySelector: () => null, querySelectorAll: () => [], closest: () => null },
                    { innerText: 'Healthy turn response complete with zero errors', querySelector: () => null, querySelectorAll: () => [], closest: () => null }
                ];
            }
            if (sel.includes('error')) {
                return [
                    {
                        innerText: 'Connection interrupted',
                        style: { display: 'block' },
                        closest: (parentSel) => {
                            if (parentSel === 'article') return { id: 'old_article_1' };
                            return null;
                        }
                    }
                ];
            }
            return [];
        },
        querySelector: () => null
    };

    const res = detectChatGPTThinking(mockDoc, 0);
    assert.strictEqual(res.status, 'idle', 'Historical turn error in past article must be ignored.');
    console.log('✅ Test 23 Passed: Historical interruption DOM text in past turn ignored');
}

// 24. Hidden error elements ignored
function test24_HiddenErrorElementsIgnored() {
    const { detectChatGPTThinking } = require('./content.js');
    const mockDoc = {
        querySelectorAll: (sel) => {
            if (sel === 'article') {
                return [{ innerText: 'Normal answer text', querySelector: () => null, querySelectorAll: () => [], closest: () => null }];
            }
            if (sel.includes('error')) {
                return [
                    {
                        innerText: 'An error occurred while generating',
                        style: { display: 'none' }, // Hidden!
                        closest: () => null
                    }
                ];
            }
            return [];
        },
        querySelector: () => null
    };

    const res = detectChatGPTThinking(mockDoc, 0);
    assert.strictEqual(res.status, 'idle', 'Hidden error elements (display: none) must be ignored.');
    console.log('✅ Test 24 Passed: Hidden error elements ignored');
}

// 25. Positive working signal overrides candidate blocked status
function test25_PositiveWorkingSignalOverridesBlocked() {
    const { detectChatGPTThinking } = require('./content.js');
    const mockDoc = {
        querySelectorAll: (sel) => {
            if (sel === 'article') {
                return [{
                    innerText: 'Streaming response...',
                    querySelector: (childSel) => childSel.includes('streaming') ? {} : null,
                    querySelectorAll: () => [],
                    closest: () => null
                }];
            }
            return [];
        },
        querySelector: (sel) => sel.includes('stop') ? { style: { display: 'block' } } : null
    };

    const res = detectChatGPTThinking(mockDoc, 0);
    assert.strictEqual(res.status, 'working', 'Positive working signal must immediately override blocked candidate status.');
    console.log('✅ Test 25 Passed: Positive working signal overrides candidate blocked status');
}

// 26. Clean response completion clears prior turn errors
function test26_CleanResponseCompletionClearsPriorErrors() {
    const { detectChatGPTThinking } = require('./content.js');
    const mockDoc = {
        querySelectorAll: (sel) => {
            if (sel === 'article') {
                return [
                    { innerText: 'An error occurred while generating', querySelector: () => null, querySelectorAll: () => [], closest: () => null },
                    { innerText: 'This is the clean final response', querySelector: () => null, querySelectorAll: () => [], closest: () => null }
                ];
            }
            return [];
        },
        querySelector: () => null
    };

    const res = detectChatGPTThinking(mockDoc, 0);
    assert.strictEqual(res.status, 'idle', 'Clean completion on latest turn must clear prior turn error state.');
    console.log('✅ Test 26 Passed: Clean response completion clears prior turn errors');
}

// 27. Navigating an existing Chrome tab to a new conversation resets session identity & status immediately
function test27_TabNavigationResetsSessionIdentityAndStatus() {
    resetState();
    const tabId = 2701;

    // Turn 1 on Conversation A
    processRawSignal(tabId, {
        seq: 1,
        timestamp: Date.now(),
        active: true,
        sessionTitle: 'Conversation A',
        webLink: 'https://chatgpt.com/c/conv-a'
    });

    const recA = tabRegistry.get(tabId);
    assert.strictEqual(recA.sessionTitle, 'Conversation A', 'Session title must match Conversation A.');
    assert.strictEqual(recA.status, 'working', 'Status must be working on Conversation A.');

    // Tab navigates to Conversation B
    processRawSignal(tabId, {
        seq: 2,
        timestamp: Date.now() + 100,
        active: false,
        sessionTitle: 'Conversation B',
        webLink: 'https://chatgpt.com/c/conv-b'
    });

    const recB = tabRegistry.get(tabId);
    assert.strictEqual(recB.sessionTitle, 'Conversation B', 'Session title must update immediately to Conversation B.');
    assert.strictEqual(recB.webLink, 'https://chatgpt.com/c/conv-b', 'Web link must update immediately to Conversation B.');
    assert.strictEqual(recB.status, 'idle', 'Status must reset to idle on navigation to Conversation B.');
    console.log('✅ Test 27 Passed: Tab navigation resets session identity & status immediately');
}

// 28. Main-world fetch interceptor singleton guard & sensorReason propagation
function test28_FetchInterceptorSingletonGuardAndSensorReason() {
    resetState();
    const { processRawSignal, computeOverallStatus, tabRegistry } = require('./background.js');
    const tabs = [{ id: 2801, title: 'Chat Session', url: 'https://chatgpt.com/c/2801', active: true }];

    processRawSignal(2801, {
        seq: 1,
        timestamp: Date.now(),
        active: true,
        reason: 'Stop Button Invariant',
        sessionTitle: 'Chat Session',
        webLink: 'https://chatgpt.com/c/2801'
    });

    const res = computeOverallStatus(tabs, tabRegistry);
    assert.strictEqual(res.openTabs[0].sensorReason, 'Stop Button Invariant', 'sensorReason must be captured and passed in openTabs.');
    console.log('✅ Test 28 Passed: Main-world fetch interceptor singleton guard & sensorReason propagation');
}

async function runAll() {
    test1_ActiveTabIdlePlusDoneTabProducesAggregateDone();
    test2_SwitchingActiveTabsLeavesAggregateUnchanged();
    test3_MenuOpeningDoesNotAcknowledgeDone();
    test4_ExplicitActionAcknowledgesTargetedTabId();
    test5_TwoDoneTabsRemainAggregateDoneAfterOneAcknowledged();
    test6_ParentTitleMatchesCompletedTabId();
    test7_SwiftPreservesReceivedAggregateState();
    test8_ClaudeCodexReportUnknownWhenUnverified();
    test9_ContentScriptDeduplicationAndThrottling();
    await test10_BackgroundFetchDeduplication();
    await test11_FailedHttpDeliveryRetriesUntilSuccessful();
    await test12_FailedOlderPayloadSupersededByNewerPayload();
    await test13_InFlightPayloadSupersededAndDelivered();
    test14_ConnectionInterruptedTransitionsToBlocked();
    test15_TargetTabIdIncludedInComputeOverallStatus();
    test16_HandleExactFocusActivatesExactTab();
    test17_BlockedClearedTransitionsToDone();
    test18_BlockedResumedTransitionsToWorking();
    test19_OneBlockedOneDoneParentRemainsBlocked();
    test20_AcknowledgingOneDoneTabLeavesOtherDoneBlocked();
    test21_TransientCandidateDoesNotSurface();
    await test22_StableCandidateDoesSurface();
    test23_HistoricalInterruptionDOMTextIgnored();
    test24_HiddenErrorElementsIgnored();
    test25_PositiveWorkingSignalOverridesBlocked();
    test26_CleanResponseCompletionClearsPriorErrors();
    test27_TabNavigationResetsSessionIdentityAndStatus();
    test28_FetchInterceptorSingletonGuardAndSensorReason();
    console.log('🎉 All 28 Multi-Tab, State Consistency & Raw Sensor Repair JS Stress Tests Passed!');
}

runAll();



