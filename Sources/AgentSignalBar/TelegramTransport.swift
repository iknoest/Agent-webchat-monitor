import Foundation

public struct TelegramChat: Codable, Sendable, Equatable {
    public let id: Int64
    public let type: String
    public let title: String?
    public let username: String?
    public let first_name: String?

    public init(id: Int64, type: String = "private", title: String? = nil, username: String? = nil, first_name: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.first_name = first_name
    }
}

public struct TelegramMessage: Codable, Sendable, Equatable {
    public let message_id: Int64
    public let chat: TelegramChat
    public let text: String?
    public let date: Int64

    public init(message_id: Int64, chat: TelegramChat, text: String?, date: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.message_id = message_id
        self.chat = chat
        self.text = text
        self.date = date
    }
}

public struct TelegramUpdate: Codable, Sendable, Equatable {
    public let update_id: Int64
    public let message: TelegramMessage?

    public init(update_id: Int64, message: TelegramMessage?) {
        self.update_id = update_id
        self.message = message
    }
}

public struct TelegramDeliveryResult: Sendable, Equatable {
    public let success: Bool
    public let httpStatus: Int
    public let errorCode: Int?
    public let description: String?

    public init(success: Bool, httpStatus: Int = 0, errorCode: Int? = nil, description: String? = nil) {
        self.success = success
        self.httpStatus = httpStatus
        self.errorCode = errorCode
        self.description = description
    }

    public var safeSummary: String {
        if success {
            return "Delivered"
        }
        if let desc = description, !desc.isEmpty {
            return "Failed — \(desc)"
        }
        if httpStatus > 0 {
            return "Failed — HTTP \(httpStatus)"
        }
        return "Failed — Network Error"
    }
}

public struct TelegramUpdatesResponse: Codable, Sendable {
    public let ok: Bool
    public let error_code: Int?
    public let result: [TelegramUpdate]?
    public let description: String?
}

public struct TelegramSendMessageResponse: Codable, Sendable {
    public let ok: Bool
    public let error_code: Int?
    public let result: TelegramMessage?
    public let description: String?
}

public protocol TelegramTransportProtocol: Sendable {
    func sendMessage(botToken: String, chatId: String, text: String, parseMode: String?) async throws -> TelegramDeliveryResult
    func getUpdates(botToken: String, offset: Int?, timeout: Int) async throws -> [TelegramUpdate]
}

public final class URLSessionTelegramTransport: TelegramTransportProtocol {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sendMessage(botToken: String, chatId: String, text: String, parseMode: String? = nil) async throws -> TelegramDeliveryResult {
        guard !botToken.isEmpty, !chatId.isEmpty else {
            return TelegramDeliveryResult(success: false, httpStatus: 0, errorCode: nil, description: "Missing bot token or chat ID")
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            return TelegramDeliveryResult(success: false, httpStatus: 0, errorCode: nil, description: "Invalid Bot API URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15.0

        var payload: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        if let pm = parseMode {
            payload["parse_mode"] = pm
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return TelegramDeliveryResult(success: false, httpStatus: 0, errorCode: nil, description: "Failed to serialize message payload")
        }
        req.httpBody = body

        do {
            let (data, response) = try await session.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if let decoded = try? JSONDecoder().decode(TelegramSendMessageResponse.self, from: data) {
                return TelegramDeliveryResult(
                    success: decoded.ok,
                    httpStatus: statusCode,
                    errorCode: decoded.error_code,
                    description: decoded.ok ? "Delivered" : decoded.description
                )
            }

            let is2xx = (200...299).contains(statusCode)
            return TelegramDeliveryResult(
                success: is2xx,
                httpStatus: statusCode,
                errorCode: nil,
                description: is2xx ? "Delivered" : "HTTP \(statusCode)"
            )
        } catch {
            return TelegramDeliveryResult(
                success: false,
                httpStatus: 0,
                errorCode: nil,
                description: error.localizedDescription
            )
        }
    }

    public func getUpdates(botToken: String, offset: Int?, timeout: Int = 20) async throws -> [TelegramUpdate] {
        guard !botToken.isEmpty else { return [] }
        var urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?timeout=\(timeout)"
        if let off = offset {
            urlStr += "&offset=\(off)"
        }
        guard let url = URL(string: urlStr) else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = Double(timeout + 10)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }

        if let decoded = try? JSONDecoder().decode(TelegramUpdatesResponse.self, from: data), decoded.ok {
            return decoded.result ?? []
        }
        return []
    }
}

public struct MockSentTelegramMessage: Sendable, Equatable {
    public let chatId: String
    public let text: String
    public let parseMode: String?
    public let timestamp: Date

    public init(chatId: String, text: String, parseMode: String? = nil, timestamp: Date = Date()) {
        self.chatId = chatId
        self.text = text
        self.parseMode = parseMode
        self.timestamp = timestamp
    }
}

public final class MockTelegramTransport: @unchecked Sendable, TelegramTransportProtocol {
    private let lock = NSLock()
    public var sentMessages: [MockSentTelegramMessage] = []
    public var queuedUpdates: [TelegramUpdate] = []
    public var shouldFailSendMessage: Bool = false
    public var mockFailHttpStatus: Int = 400
    public var mockFailErrorCode: Int? = 400
    public var mockFailDescription: String? = "Bad Request: chat not found"
    public var shouldFailGetUpdates: Bool = false

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sentMessages.removeAll()
        queuedUpdates.removeAll()
        shouldFailSendMessage = false
        mockFailHttpStatus = 400
        mockFailErrorCode = 400
        mockFailDescription = "Bad Request: chat not found"
        shouldFailGetUpdates = false
    }

    public func sendMessage(botToken: String, chatId: String, text: String, parseMode: String? = nil) async throws -> TelegramDeliveryResult {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailSendMessage {
            return TelegramDeliveryResult(
                success: false,
                httpStatus: mockFailHttpStatus,
                errorCode: mockFailErrorCode,
                description: mockFailDescription ?? "Mock network failure"
            )
        }
        sentMessages.append(MockSentTelegramMessage(chatId: chatId, text: text, parseMode: parseMode))
        return TelegramDeliveryResult(success: true, httpStatus: 200, errorCode: nil, description: "Delivered")
    }

    public func getUpdates(botToken: String, offset: Int?, timeout: Int = 20) async throws -> [TelegramUpdate] {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailGetUpdates {
            return []
        }
        let updates = queuedUpdates
        queuedUpdates.removeAll()
        return updates
    }

    public func queueUpdate(_ update: TelegramUpdate) {
        lock.lock()
        defer { lock.unlock() }
        queuedUpdates.append(update)
    }

    public func getLastSentMessage() -> MockSentTelegramMessage? {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages.last
    }

    public func getAllSentMessages() -> [MockSentTelegramMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages
    }
}
