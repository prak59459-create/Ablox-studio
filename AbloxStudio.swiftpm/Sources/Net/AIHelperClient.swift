import Foundation
import AbloxCore

/// The grown-up's AI key, in the keychain beside the sign-in token. It is
/// read only here, when a question is sent, and never written anywhere else.
enum AIHelperKey {
    private static let account = "ai-helper-key"

    static var isSet: Bool { read() != nil }

    static func read() -> String? {
        Keychain.read(account: account).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ key: String) {
        Keychain.write(Data(key.utf8), account: account)
    }

    static func remove() {
        Keychain.delete(account: account)
    }
}

/// Sends one question to the provider (AIHelper.endpoint) and reads the
/// answer. Nothing but the question, the last few turns and the guide goes.
struct AIHelperClient {
    var session: URLSession = .shared

    func ask(_ question: String, history: [AIHelper.Turn], japanese: Bool,
             moderator: ChatModerator = ChatModerator()) async -> Result<String, AIHelper.Failure> {
        guard let key = AIHelperKey.read() else { return .failure(.badKey) }
        var result: Result<String, AIHelper.Failure> = .failure(.unreadable)
        for model in AIHelper.models {
            var request = URLRequest(url: AIHelper.endpoint, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = AIHelper.requestBody(question: question, history: history, japanese: japanese, model: model)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = AIHelper.reply(status: status, data: data, moderator: moderator)
                guard AIHelper.modelIsGone(status: status) else { return result }
            } catch {
                return .failure(.offline)
            }
        }
        return result
    }
}
