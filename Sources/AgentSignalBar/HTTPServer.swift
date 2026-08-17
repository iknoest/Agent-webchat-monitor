import Foundation
import Network

public final class HTTPServer: @unchecked Sendable {
    public static let shared = HTTPServer()
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 18888

    private var pendingFocusTabId: Int? = nil
    private let focusLock = NSLock()

    public func requestTabFocus(tabId: Int) {
        focusLock.lock()
        pendingFocusTabId = tabId
        focusLock.unlock()
    }

    public func popPendingFocusTabId() -> Int? {
        focusLock.lock()
        defer { focusLock.unlock() }
        let id = pendingFocusTabId
        pendingFocusTabId = nil
        return id
    }

    public func start() {
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: port)
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🚀 AgentSignalBar HTTP Server listening on http://127.0.0.1:18888")
                case .failed(let error):
                    print("❌ HTTP Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: DispatchQueue.global(qos: .userInitiated))
        } catch {
            print("Failed to create NWListener on port 18888: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty, let requestString = String(data: data, encoding: .utf8) {
                self?.processHTTPRequest(requestString, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else if let error = error {
                print("Connection error: \(error)")
                connection.cancel()
            }
        }
    }

    private func processHTTPRequest(_ requestString: String, connection: NWConnection) {
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let method = parts[0]
        let pathWithQuery = parts[1]

        let urlComponents = URLComponents(string: pathWithQuery)
        let path = urlComponents?.path ?? pathWithQuery

        // Handle CORS Preflight
        if method == "OPTIONS" {
            sendCORSResponse(connection: connection)
            return
        }

        if path == "/status" {
            if method == "GET" {
                if let queryItems = urlComponents?.queryItems,
                   let agentStr = queryItems.first(where: { $0.name == "agent" })?.value,
                   let statusStr = queryItems.first(where: { $0.name == "status" })?.value {
                    let detailStr = queryItems.first(where: { $0.name == "detail" })?.value
                    handleStatusUpdate(agentStr: agentStr, statusStr: statusStr, detail: detailStr)
                }

                let allStates = AgentStore.shared.getAllStates()
                var dict: [String: [String: Any]] = [:]
                let isoFormatter = ISO8601DateFormatter()

                for (agent, info) in allStates {
                    let usage = AgentUsageStore.shared.getUsage(for: agent)
                    let quotaTsStr = usage?.quotaTimestamp != nil ? isoFormatter.string(from: usage!.quotaTimestamp!) : nil

                    var modelFamiliesList: [[String: Any]] = []
                    if let families = usage?.modelFamilies, !families.isEmpty {
                        for f in families {
                            modelFamiliesList.append([
                                "name": f.name,
                                "sessionPercent": f.sessionLimitPercent as Any,
                                "weeklyPercent": f.weeklyLimitPercent as Any,
                                "sessionResetText": f.sessionResetText as Any,
                                "weeklyResetText": f.weeklyResetText as Any,
                                "isPercentUsed": f.isPercentUsed,
                                "isExhausted": f.isExhausted
                            ])
                        }
                    }

                    dict[agent.rawValue] = [
                        "status": info.status.rawValue,
                        "availability": (usage?.availability ?? info.availability).rawValue,
                        "effectiveDisplayStatus": info.effectiveDisplayStatus.rawValue,
                        "badge": info.effectiveDisplayStatus.badge(theme: AgentStore.shared.currentTheme),
                        "name": info.id.displayName,
                        "detail": info.detail ?? "",
                        "lastUpdated": isoFormatter.string(from: info.lastUpdated),
                        "isLiveQuota": usage?.isLiveSource ?? false,
                        "sourceAuthority": usage?.sourceAuthority ?? (usage?.isLiveSource == true ? "live_first_party" : "loaded_from_config"),
                        "quotaSource": usage?.quotaSource ?? "none",
                        "quotaTimestamp": quotaTsStr as Any,
                        "parserDecision": usage?.parserDecision ?? "no_live_disk_file",
                        "freshness": usage?.freshness ?? "Unavailable",
                        "isQuotaExhausted": usage?.isQuotaExhausted ?? false,
                        "modelFamilies": modelFamiliesList
                    ]
                }
                dict["sleep"] = SleepManager.shared.getDebugInfo()

                if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                } else {
                    sendResponse(connection: connection, statusCode: 500, body: "JSON encoding error")
                }

            } else if method == "POST" {
                if let bodyRange = requestString.range(of: "\r\n\r\n") {
                    let body = String(requestString[bodyRange.upperBound...])
                    if let bodyData = body.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                        let agentStr = json["agent"] as? String ?? ""
                        let statusStr = json["status"] as? String ?? ""
                        let detail = json["detail"] as? String
                        let sessionCount = json["sessionCount"] as? Int
                        let sessionTitle = json["sessionTitle"] as? String
                        let targetTabId = json["targetTabId"] as? Int
                        let webLink = json["webLink"] as? String
                        let revision = json["revision"] as? Int

                        var openTabsList: [ChatGPTTabInfo] = []
                        if let tabsRaw = json["openTabs"] as? [[String: Any]] {
                            for tab in tabsRaw {
                                let tabId = tab["tabId"] as? Int
                                let title = tab["title"] as? String ?? "ChatGPT Session"
                                let url = tab["url"] as? String ?? "https://chatgpt.com"
                                let status = tab["status"] as? String ?? "idle"
                                let badge = tab["badge"] as? String
                                let active = tab["active"] as? Bool
                                openTabsList.append(ChatGPTTabInfo(tabId: tabId, title: title, url: url, status: status, badge: badge, active: active))
                            }
                        }

                        if handleStatusUpdate(agentStr: agentStr, statusStr: statusStr, detail: detail, sessionCount: sessionCount, sessionTitle: sessionTitle, targetTabId: targetTabId, webLink: webLink, openTabs: openTabsList, revision: revision) {
                    var responseDict: [String: Any] = ["success": true]
                    if let focusTabId = popPendingFocusTabId() {
                        responseDict["focusTabId"] = focusTabId
                    }
                    if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                    } else {
                        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                    }
                } else {
                    sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"Invalid agent or status\"}")
                }
                        return
                    }
                }
                sendResponse(connection: connection, statusCode: 400, body: "Invalid JSON body")
            } else {
                sendResponse(connection: connection, statusCode: 405, body: "Method Not Allowed")
            }
        } else if path == "/focus" {
            if method == "GET" {
                var responseDict: [String: Any] = [:]
                if let focusTabId = popPendingFocusTabId() {
                    responseDict["focusTabId"] = focusTabId
                } else {
                    responseDict["focusTabId"] = NSNull()
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                } else {
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"focusTabId\":null}")
                }
                return
            }
            sendResponse(connection: connection, statusCode: 405, body: "Method Not Allowed")
        } else if path.hasPrefix("/acknowledge") {
            if method == "POST" || method == "GET" {
                let agentStr = urlComponents?.queryItems?.first(where: { $0.name == "agent" })?.value ?? "chatgpt"
                let sessionStr = urlComponents?.queryItems?.first(where: { $0.name == "session" })?.value
                let turnStr = urlComponents?.queryItems?.first(where: { $0.name == "turn" })?.value
                if let agent = AgentID(rawValue: agentStr) {
                    if let sessId = sessionStr, !sessId.isEmpty {
                        AgentStore.shared.markSessionChecked(provider: agent, sessionId: sessId, turnId: turnStr)
                    } else {
                        AgentStore.shared.markChecked(for: agent)
                    }
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"acknowledged\":true}")
                    return
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid agent parameter")
        } else if path == "/relay/pending" {
            if let pending = OutputRelayManager.shared.popPendingRelayText() {
                let dict: [String: Any] = ["hasPending": true, "text": pending]
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                } else {
                    sendResponse(connection: connection, statusCode: 500, body: "JSON error")
                }
            } else {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"hasPending\":false}")
            }
        } else if path == "/relay" {
            if method == "POST", let bodyRange = requestString.range(of: "\r\n\r\n") {
                let body = String(requestString[bodyRange.upperBound...])
                if let bodyData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let text = json["text"] as? String {
                    OutputRelayManager.shared.setPendingRelayText(text)
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                    return
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid relay request")
        } else if path == "/sleep/closed-lid/toggle" {
            let current = SleepManager.shared.isClosedLidModeEnabled
            SleepManager.shared.isClosedLidModeEnabled = !current
            MenuBarManager.shared.updateTitleAndMenu()
            let resp: [String: Any] = [
                "success": true,
                "isClosedLidEnabled": SleepManager.shared.isClosedLidModeEnabled,
                "isDisableSleepActive": SleepManager.shared.isDisableSleepActive,
                "privilege": SleepManager.checkPrivilegeStatus().detail
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: resp),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonStr)
            } else {
                sendResponse(connection: connection, statusCode: 200, body: "{\"success\":true}")
            }
            return
        } else if path == "/relay/chatgpt-output" {
            if method == "POST", let bodyRange = requestString.range(of: "\r\n\r\n") {
                let body = String(requestString[bodyRange.upperBound...])
                if let bodyData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let text = json["text"] as? String {

                    OutputRelayManager.shared.setLastOutput(for: .chatgpt, text: text)
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                    return
                }
            }
        } else if path == "/hooks/claude" {
            if method == "POST", let bodyRange = requestString.range(of: "\r\n\r\n") {
                let body = String(requestString[bodyRange.upperBound...])
                if let bodyData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    let isTestMode = (json["is_test"] as? Bool) ?? (urlComponents?.queryItems?.first(where: { $0.name == "is_test" })?.value == "true")
                    if AgentStore.shared.handleClaudeHookEvent(json: json, isTestMode: isTestMode) {
                        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                        return
                    }
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid hook payload")
        } else if path == "/hooks/claude/purge" {
            AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .claude)
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"purged\":true}")
            return
        } else if path == "/hooks/antigravity" {
            if method == "POST", let bodyRange = requestString.range(of: "\r\n\r\n") {
                let body = String(requestString[bodyRange.upperBound...])
                if let bodyData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    let isTestMode = (json["is_test"] as? Bool) ?? (urlComponents?.queryItems?.first(where: { $0.name == "is_test" })?.value == "true")
                    if AgentStore.shared.handleAntigravityHookEvent(json: json, isTestMode: isTestMode) {
                        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                        return
                    }
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid hook payload")
        } else if path == "/hooks/antigravity/purge" {
            AgentStore.shared.purgeSyntheticAndStaleSessions(provider: .antigravity)
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"purged\":true}")
            return
        } else if path == "/usage" {
            if method == "POST", let bodyRange = requestString.range(of: "\r\n\r\n") {
                let body = String(requestString[bodyRange.upperBound...])
                if let bodyData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let agentStr = json["agent"] as? String,
                   let agent = AgentID(rawValue: agentStr.lowercased()) {

                    var usage = AgentUsageStore.shared.getUsage(for: agent) ?? AgentUsageData(agent: agent)

                    if let sPct = json["sessionPercent"] as? Double { usage.sessionLimitPercent = sPct }
                    if let sReset = json["sessionReset"] as? String { usage.sessionResetText = sReset }
                    if let wPct = json["weeklyPercent"] as? Double { usage.weeklyLimitPercent = wPct }
                    if let wReset = json["weeklyReset"] as? String { usage.weeklyResetText = wReset }
                    if let extra = json["extra"] as? String { usage.extraMetricText = extra }
                    if let isUsed = json["isPercentUsed"] as? Bool { usage.isPercentUsed = isUsed }

                    if let familiesRaw = json["modelFamilies"] as? [[String: Any]] {
                        var parsedFamilies: [ModelFamilyQuota] = []
                        for f in familiesRaw {
                            guard let name = f["name"] as? String else { continue }
                            let fSessionPct = f["sessionPercent"] as? Double
                            let fWeeklyPct = f["weeklyPercent"] as? Double
                            let fSessionReset = f["sessionResetText"] as? String
                            let fWeeklyReset = f["weeklyResetText"] as? String
                            let fIsUsed = f["isPercentUsed"] as? Bool ?? false
                            parsedFamilies.append(ModelFamilyQuota(
                                name: name,
                                sessionLimitPercent: fSessionPct,
                                sessionResetText: fSessionReset,
                                weeklyLimitPercent: fWeeklyPct,
                                weeklyResetText: fWeeklyReset,
                                isPercentUsed: fIsUsed
                            ))
                        }
                        usage.modelFamilies = parsedFamilies
                    }

                    usage.isLiveSource = true
                    usage.sourceAuthority = "injected_test"
                    usage.quotaSource = "post_usage_injected"
                    usage.parserDecision = "injected_test_fixture"
                    usage.freshness = "Fresh"
                    usage.lastUpdated = Date()

                    AgentUsageStore.shared.updateUsage(for: agent, data: usage)
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                    return
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid usage request")

        } else if path == "/debug/state" {
            let sessions = AgentStore.shared.getAllSessions()
            let isoFormatter = ISO8601DateFormatter()
            var list: [[String: Any]] = []

            let now = Date()
            for s in sessions {
                var durSecs: Double? = nil
                if let start = s.thinkingStartTime {
                    durSecs = now.timeIntervalSince(start)
                } else if let lastDur = s.lastDurationSeconds {
                    durSecs = lastDur
                }

                let ackAtStr: Any = s.acknowledgedAt != nil ? isoFormatter.string(from: s.acknowledgedAt!) : NSNull()

                let dict: [String: Any] = [
                    "provider": s.provider.rawValue,
                    "sessionId": s.sessionId,
                    "title": s.title,
                    "status": s.status.rawValue,
                    "committedState": s.status.rawValue,
                    "turnId": s.turnId as Any,
                    "attentionReason": s.attentionReason as Any,
                    "sourceEvidence": s.sourceEvidence,
                    "sensorReason": s.sensorReason ?? s.attentionReason ?? s.sourceEvidence,
                    "acknowledgedTurnId": s.acknowledgedTurnId as Any,
                    "acknowledgedAt": ackAtStr,
                    "isAcknowledged": s.isAcknowledged,
                    "durationSeconds": durSecs as Any,
                    "lastUpdated": isoFormatter.string(from: s.lastUpdated),
                    "webLink": s.webLink as Any,
                    "targetTabId": s.targetTabId as Any
                ]
                list.append(dict)
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
            } else {
                sendResponse(connection: connection, statusCode: 500, body: "JSON encoding error")
            }
        } else if path == "/debug/sleep" {
            let sleepInfo = SleepManager.shared.getDebugInfo()
            if let jsonData = try? JSONSerialization.data(withJSONObject: sleepInfo, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
            } else {
                sendResponse(connection: connection, statusCode: 500, body: "JSON encoding error")
            }
        } else if path == "/sound/toggle" {
            let soundOn = NotificationManager.shared.toggleSound()
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"soundEnabled\":\(soundOn)}")
        } else if path == "/sound/stop" {
            NotificationManager.shared.stopCurrentSound()
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"soundStopped\":true}")
        } else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
        }
    }

    @discardableResult
    private func handleStatusUpdate(
        agentStr: String,
        statusStr: String,
        detail: String?,
        sessionCount: Int? = nil,
        sessionTitle: String? = nil,
        targetTabId: Int? = nil,
        webLink: String? = nil,
        openTabs: [ChatGPTTabInfo]? = nil,
        revision: Int? = nil
    ) -> Bool {
        guard let agent = AgentID(rawValue: agentStr.lowercased()),
              let status = AgentStatus(rawValue: statusStr.lowercased()) else {
            return false
        }

        AgentStore.shared.updateStatus(
            for: agent,
            status: status,
            detail: detail,
            sessionCount: sessionCount,
            sessionTitle: sessionTitle,
            targetTabId: targetTabId,
            webLink: webLink,
            openTabs: openTabs,
            revision: revision
        )
        return true
    }

    private func sendCORSResponse(connection: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: POST, GET, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Access-Control-Allow-Private-Network: true",
            "Content-Length: 0",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        if let data = headers.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String = "text/plain", body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = [
            "HTTP/1.1 \(statusCode) OK",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: Content-Type",
            "Access-Control-Allow-Private-Network: true",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
