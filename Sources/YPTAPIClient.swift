import Foundation
import Darwin // sysctlbyname, for the real Mac model

/// Short, user-safe errors. Server messages are capped; a token can never
/// appear here because tokens are never part of a response body.
enum YPTError: Error, LocalizedError {
    case notLoggedIn
    case unauthorized // 401: the session expired, log in again
    case server(String)
    case network
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in"
        case .unauthorized: return "Session expired"
        case .server(let message): return message.isEmpty ? "Server error" : String(message.prefix(80))
        case .network: return "No connection"
        case .badResponse: return "Unexpected response"
        }
    }
}

/// Minimal client for the YPT endpoints the web client uses.
/// Only these endpoints are used; nothing else is invented.
struct YPTAPIClient {
    private static let base = "https://pi.tgclab.com"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// The real Mac model (e.g. Mac14,7), never a spoofed phone model.
    static func deviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(cString: buffer)
        return model.isEmpty ? "Mac" : model
    }

    func start(token: String, subject: String) async throws {
        let body: [String: Any] = ["subject": subject, "deviceModel": Self.deviceModel()]
        let json = try await post(path: "/study/start", token: token, body: body)
        guard json["s"] as? Bool == true else {
            throw YPTError.server(json["c"] as? String ?? "")
        }
    }

    func stop(token: String, startedAtMs: Int) async throws {
        let body: [String: Any] = ["startedAt": startedAtMs, "deviceModel": Self.deviceModel()]
        let json = try await post(path: "/study/stop", token: token, body: body)
        guard json["s"] as? Bool == true else {
            throw YPTError.server(json["c"] as? String ?? "")
        }
    }

    func dayLog(token: String, date: String) async throws -> DayLog {
        let json = try await get(path: "/logs/day?date=\(date)", token: token)
        return DayLog.parse(json)
    }

    // MARK: - HTTP plumbing (the token only ever goes in the header)

    private func request(path: String, token: String) throws -> URLRequest {
        guard let url = URL(string: Self.base + path) else { throw YPTError.badResponse }
        var req = URLRequest(url: url)
        req.setValue("JWT \(token)", forHTTPHeaderField: "authorization")
        return req
    }

    private func post(path: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        var req = try request(path: path, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func get(path: String, token: String) async throws -> [String: Any] {
        var req = try request(path: path, token: token)
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw YPTError.network
        }
        guard let http = response as? HTTPURLResponse else { throw YPTError.badResponse }
        if http.statusCode == 401 { throw YPTError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw YPTError.server("") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YPTError.badResponse
        }
        return json
    }
}
