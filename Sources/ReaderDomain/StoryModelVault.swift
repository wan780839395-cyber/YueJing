import Foundation
import Security

public struct StoryModelConfiguration: Equatable, Sendable {
    public let endpoint: URL
    public let model: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint.absoluteString.utf8.elementsEqual(rhs.endpoint.absoluteString.utf8)
            && lhs.model.utf8.elementsEqual(rhs.model.utf8)
    }
}

enum StoryModelVaultError: LocalizedError {
    case invalidEndpoint, invalidModel, invalidKey, unavailable, configurationChanged
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "请填写有效的 HTTPS 接口，或明确批准完整的私网 HTTP 聊天地址。"
        case .invalidModel: return "请输入服务商提供的有效模型标识。"
        case .invalidKey: return "密钥格式无效，请重新输入。"
        case .unavailable: return "设备钥匙串不可用，请解锁设备后再试。"
        case .configurationChanged: return "模型配置已删除或发生变化，请重新预览后发送。"
        }
    }
}

public enum StoryModelVault {
    // Identity is constant: neither secrets nor endpoint/model go in searchable attributes.
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "YueJing.ReaderDomain.StoryModel.v1",
         kSecAttrAccount as String: "configuration",
         kSecAttrSynchronizable as String: false]
    }

    struct Record: Codable, Sendable {
        let endpoint: String
        let model: String
        let apiKey: String
        let approvedLANEndpoint: String?

        func validated() throws -> StoryModelConfiguration {
            let config = try StoryModelVault.configuration(endpoint: endpoint, model: model, approvedLANEndpoint: approvedLANEndpoint)
            guard config.endpoint.absoluteString.utf8.elementsEqual(endpoint.utf8) else { throw StoryModelVaultError.invalidEndpoint }
            if !apiKey.isEmpty || config.endpoint.scheme != "http" { try StoryModelVault.validateKey(apiKey) }
            return config
        }
    }

    /// Parse the raw authority and path before URL processing can interpret aliases or escapes.
    public static func lanEndpointCandidate(_ input: String) -> String? {
        let scheme = "http://"
        guard input.utf8.count <= 4096, input.utf8.allSatisfy({ (33...126).contains($0) }),
              input.hasPrefix(scheme) else { return nil }
        let remainder = input.dropFirst(scheme.count)
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let authority = remainder[..<slash].split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(authority.count) else { return nil }
        func decimal(_ s: Substring, maxDigits: Int) -> Int? {
            guard (1...maxDigits).contains(s.utf8.count), s == "0" || s.first != "0",
                  s.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(s)
        }
        if authority.count == 2 {
            guard let port = decimal(authority[1], maxDigits: 5), (1...65535).contains(port) else { return nil }
        }
        let octets = authority[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        let ip = octets.compactMap { decimal($0, maxDigits: 3) }
        guard ip.count == 4, ip.allSatisfy({ $0 <= 255 }),
              ip[0] == 10 || (ip[0] == 172 && (16...31).contains(ip[1])) || (ip[0] == 192 && ip[1] == 168) else { return nil }

        var path = input[input.index(after: slash)...]
        if path.last == "/" { path = path.dropLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".." && segment.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0)
            }
        }) else { return nil }
        let base = String(input[...slash]) + String(path)
        let candidate: String
        if segments.last == "v1" { candidate = base + "/chat/completions" }
        else if base.hasSuffix("/chat/completions") { candidate = base }
        else { return nil }
        return candidate.utf8.count <= 4096 ? candidate : nil
    }

    static func configuration(endpoint: String, model: String, approvedLANEndpoint: String? = nil) throws -> StoryModelConfiguration {
        let url: URL
        if endpoint.hasPrefix("http://") {
            guard let canonical = lanEndpointCandidate(endpoint), let approvedLANEndpoint,
                  canonical.utf8.elementsEqual(approvedLANEndpoint.utf8), let parsed = URL(string: canonical),
                  parsed.absoluteString.utf8.elementsEqual(canonical.utf8) else { throw StoryModelVaultError.invalidEndpoint }
            url = parsed
        } else {
            url = try httpsURL(endpoint)
        }
        guard (1...256).contains(model.utf8.count),
              model.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw StoryModelVaultError.invalidModel }
        return StoryModelConfiguration(endpoint: url, model: model)
    }

    private static func httpsURL(_ endpoint: String) throws -> URL {
        guard (1...4096).contains(endpoint.utf8.count),
              endpoint.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
              // Require a literal DNS/IP authority and bound the port before asking
              // Foundation for its numeric value; never reinterpret escaped host bytes.
              endpoint.range(of: #"^https://(?:[a-z0-9._-]+|\[[a-f0-9:.]+\])(?::[0-9]{1,5})?/"#,
                             options: [.regularExpression, .caseInsensitive]) != nil,
              let parts = URLComponents(string: endpoint), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/"), parts.path != "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url, url.absoluteString.utf8.elementsEqual(endpoint.utf8)
        else { throw StoryModelVaultError.invalidEndpoint }
        return url
    }

    static func validateKey(_ key: String) throws {
        guard (1...4096).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw StoryModelVaultError.invalidKey }
    }

    static func read() throws -> Record? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 64 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { throw StoryModelVaultError.unavailable }
        return record
    }

    public static func load() throws -> StoryModelConfiguration? {
        try read()?.validated()
    }

    static func credential(for expected: StoryModelConfiguration, record: Record?) throws -> String {
        guard let record else { throw StoryModelVaultError.configurationChanged }
        let actual = try record.validated()
        guard expected.endpoint.baseURL == nil, expected == actual else { throw StoryModelVaultError.configurationChanged }
        return record.apiKey
    }

    static func existingKey(endpoint: String, record: Record?) throws -> String? {
        guard let record, record.endpoint.utf8.elementsEqual(endpoint.utf8) else { return nil }
        _ = try record.validated()
        return record.apiKey
    }

    public static func saveKeepingKey(endpoint: String, model: String, approvedLANEndpoint: String? = nil) throws {
        let config = try configuration(endpoint: endpoint, model: model, approvedLANEndpoint: approvedLANEndpoint)
        guard let key = try existingKey(endpoint: config.endpoint.absoluteString, record: read()) else { throw StoryModelVaultError.configurationChanged }
        try save(endpoint: endpoint, model: model, apiKey: key, approvedLANEndpoint: approvedLANEndpoint)
    }

    public static func save(endpoint: String, model: String, apiKey: String, approvedLANEndpoint: String? = nil) throws {
        let config = try configuration(endpoint: endpoint, model: model, approvedLANEndpoint: approvedLANEndpoint)
        let record = Record(endpoint: config.endpoint.absoluteString, model: model, apiKey: apiKey,
                            approvedLANEndpoint: config.endpoint.scheme == "http" ? approvedLANEndpoint : nil)
        _ = try record.validated()
        guard let data = try? JSONEncoder().encode(record) else { throw StoryModelVaultError.unavailable }
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = identity as CFDictionary
        var status = SecItemUpdate(query, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = identity.merging(values) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query, values as CFDictionary) }
        }
        guard status == errSecSuccess else { throw StoryModelVaultError.unavailable }
    }

    public static func clear() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoryModelVaultError.unavailable }
    }
}
