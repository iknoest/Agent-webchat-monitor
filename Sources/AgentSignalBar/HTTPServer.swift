import Foundation
import Network

public final class HTTPServer: @unchecked Sendable {
    public static let shared = HTTPServer()
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 18888

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
                var dict: [String: [String: String]] = [:]
                for (agent, info) in allStates {
                    dict[agent.rawValue] = [
                        "status": info.status.rawValue,
                        "badge": info.status.badge(),
                        "name": info.id.displayName,
                        "detail": info.detail ?? "",
                        "lastUpdated": ISO8601DateFormatter().string(from: info.lastUpdated)
                    ]
                }

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
                        let webLink = json["webLink"] as? String

                        var openTabsList: [ChatGPTTabInfo] = []
                        if let tabsRaw = json["openTabs"] as? [[String: Any]] {
                            for tab in tabsRaw {
                                let title = tab["title"] as? String ?? "ChatGPT Session"
                                let url = tab["url"] as? String ?? "https://chatgpt.com"
                                let status = tab["status"] as? String ?? "idle"
                                openTabsList.append(ChatGPTTabInfo(title: title, url: url, status: status))
                            }
                        }

                        if handleStatusUpdate(agentStr: agentStr, statusStr: statusStr, detail: detail, sessionCount: sessionCount, sessionTitle: sessionTitle, webLink: webLink, openTabs: openTabsList) {
                            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
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
            sendResponse(connection: connection, statusCode: 400, body: "Invalid relay output request")
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
                    usage.lastUpdated = Date()

                    AgentUsageStore.shared.updateUsage(for: agent, data: usage)
                    sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"success\":true}")
                    return
                }
            }
            sendResponse(connection: connection, statusCode: 400, body: "Invalid usage request")
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
        webLink: String? = nil,
        openTabs: [ChatGPTTabInfo]? = nil
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
            webLink: webLink,
            openTabs: openTabs
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
