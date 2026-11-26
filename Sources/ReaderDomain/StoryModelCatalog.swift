import Foundation

public enum StoryModelCatalog {
    enum Failure: LocalizedError {
        case path, status(Int), format, network
        var errorDescription: String? {
            switch self {
            case .path: return "无法从此聊天地址确定模型列表，请手动填写模型名。"
            case .status(let code): return "模型列表返回 HTTP \(code)，仍可手动填写模型名。"
            case .format: return "列表为空、格式不兼容或超出上限，仍可手动填写模型名。"
            case .network: return "未能连接模型列表，请检查网络与证书，或手动填写模型名。"
            }
        }
    }
    static let limit = 512 * 1024

    public static func url(endpoint: String, approvedLANEndpoint: String? = nil) throws -> URL {
        let checked = try StoryModelVault.configuration(endpoint: endpoint, model: "catalog", approvedLANEndpoint: approvedLANEndpoint)
        return try modelsURL(for: checked.endpoint)
    }

    private static func modelsURL(for checked: URL) throws -> URL {
        let suffix = "/chat/completions"
        let value = checked.absoluteString.hasSuffix("/") ? String(checked.absoluteString.dropLast()) : checked.absoluteString
        guard value.hasSuffix(suffix), let result = URL(string: String(value.dropLast(suffix.count)) + "/models"),
              result.host == checked.host, result.port == checked.port, result.scheme == checked.scheme else { throw Failure.path }
        return result
    }

    static func parse(_ bytes: Data) throws -> [String] {
        struct Item: Decodable { let id: String }
        struct List: Decodable { let data: [Item] }
        guard bytes.count <= limit, let items = try? JSONDecoder().decode(List.self, from: bytes).data,
              items.count <= 4096 else { throw Failure.format }
        let ids = Set(items.map(\.id).filter { (1...256).contains($0.utf8.count) && $0.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil })
        guard !ids.isEmpty else { throw Failure.format }
        return ids.sorted()
    }

    static func request(endpoint: String, apiKey: String, approvedLANEndpoint: String?,
                        read: () throws -> StoryModelVault.Record?) throws -> URLRequest {
        let chat = try StoryModelVault.configuration(endpoint: endpoint, model: "catalog", approvedLANEndpoint: approvedLANEndpoint).endpoint
        let target = try modelsURL(for: chat)
        var key = apiKey
        if key.isEmpty {
            if let saved = try StoryModelVault.existingKey(endpoint: chat.absoluteString, record: read()) { key = saved }
            else if chat.scheme != "http" { throw StoryModelVaultError.configurationChanged }
        }
        if !key.isEmpty || chat.scheme != "http" { try StoryModelVault.validateKey(key) }
        var request = StoryModelSessionPolicy.request(to: target, key: key)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func fetch(endpoint: String, apiKey: String, approvedLANEndpoint: String? = nil) async throws -> [String] {
        try Task.checkCancellation()
        let request = try Self.request(endpoint: endpoint, apiKey: apiKey, approvedLANEndpoint: approvedLANEndpoint, read: StoryModelVault.read)
        guard let target = request.url else { throw Failure.path }
        let config = StoryModelSessionPolicy.settings(for: target)
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: StoryModelSessionPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let task = bytes.task
            return try await withTaskCancellationHandler {
                guard let http = response as? HTTPURLResponse else { throw Failure.format }
                guard http.statusCode == 200 else { throw Failure.status(http.statusCode) }
                guard response.expectedContentLength <= Int64(limit) else { throw Failure.format }
                var result = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard result.count < limit else { throw Failure.format }
                    result.append(byte)
                }
                try Task.checkCancellation()
                return try parse(result)
            } onCancel: { task.cancel() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.network
        }
    }
}
