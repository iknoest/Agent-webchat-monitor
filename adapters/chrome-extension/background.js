// Chrome Extension Service Worker Background Script (Real-time Multi-Tab Registry via chrome.tabs.query)
const SIGNAL_URL = 'http://127.0.0.1:18888/status';
const tabStates = new Map(); // tabId -> { status, detail, sessionTitle, webLink }

async function aggregateAndSend() {
    try {
        // Query Chrome directly for ALL open ChatGPT tabs across all windows
        const tabs = await chrome.tabs.query({ url: "*://*.chatgpt.com/*" });
        
        let hasWorking = false;
        let hasBlocked = false;
        let workingCount = 0;
        let doneCount = 0;
        let activeTitle = '';
        let activeUrl = '';
        let openTabsList = [];

        for (const tab of tabs) {
            const tabId = tab.id;
            const info = tabStates.get(tabId) || {};
            
            const cleanTitle = info.sessionTitle || (tab.title ? tab.title.replace('- ChatGPT', '').trim() : 'ChatGPT Web');
            const cleanUrl = info.webLink || tab.url || 'https://chatgpt.com';
            const status = info.status || 'idle';

            openTabsList.push({
                title: cleanTitle,
                url: cleanUrl,
                status: status
            });

            if (tab.active) {
                activeTitle = cleanTitle;
                activeUrl = cleanUrl;
            }

            if (status === 'working') {
                hasWorking = true;
                workingCount++;
            } else if (status === 'blocked') {
                hasBlocked = true;
            } else if (status === 'done') {
                doneCount++;
            }
        }

        if (!activeTitle && openTabsList.length > 0) {
            activeTitle = openTabsList[0].title;
            activeUrl = openTabsList[0].url;
        }

        let overallStatus = 'idle';
        let sessionCount = Math.max(1, openTabsList.length);

        if (hasBlocked) {
            overallStatus = 'blocked';
        } else if (hasWorking) {
            overallStatus = 'working';
            sessionCount = Math.max(1, workingCount);
        } else if (doneCount > 0) {
            overallStatus = 'done';
            sessionCount = Math.max(1, doneCount);
        }

        const payload = {
            agent: 'chatgpt',
            status: overallStatus,
            detail: `${openTabsList.length} ChatGPT tab(s) in Chrome (${workingCount} active)`,
            sessionCount: sessionCount,
            sessionTitle: activeTitle || 'ChatGPT Web',
            webLink: activeUrl || 'https://chatgpt.com',
            openTabs: openTabsList
        };

        fetch(SIGNAL_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        }).catch(() => {});

    } catch (err) {
        console.error('[AgentSignalBar Background] Query error:', err);
    }
}

chrome.runtime.onMessage.addListener((message, sender) => {
    if (message.type === 'STATUS_UPDATE' && sender.tab) {
        const tabId = sender.tab.id;
        tabStates.set(tabId, {
            status: message.payload.status,
            detail: message.payload.detail || '',
            sessionTitle: message.payload.sessionTitle || sender.tab.title || '',
            webLink: message.payload.webLink || sender.tab.url || ''
        });
        aggregateAndSend();
    }
});

chrome.tabs.onRemoved.addListener((tabId) => {
    if (tabStates.has(tabId)) {
        tabStates.delete(tabId);
    }
    aggregateAndSend();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (tab.url && tab.url.includes('chatgpt.com')) {
        aggregateAndSend();
    }
});

chrome.tabs.onActivated.addListener(() => {
    aggregateAndSend();
});

// Sync tabs periodically every 2s
setInterval(aggregateAndSend, 2000);
