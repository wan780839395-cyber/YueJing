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
        case .invalidEndpoint: return "请填写完整的 HTTPS 接口地址，不要附带用户名、密码、查询参数或片段。"
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

    private struct Record: Codable {
        let endpoint: String
        let model: String
        let apiKey: String

        func validated() throws -> StoryModelConfiguration {
            try StoryModelVault.validateKey(apiKey)
            return try StoryModelVault.configuration(endpoint: endpoint, model: model)
        }
    }

    static func configuration(endpoint: String, model: String) throws -> StoryModelConfiguration {
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
        guard (1...256).contains(model.utf8.count),
              model.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw StoryModelVaultError.invalidModel }
        return StoryModelConfiguration(endpoint: url, model: model)
    }

    static func validateKey(_ key: String) throws {
        guard (1...4096).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw StoryModelVaultError.invalidKey }
    }

    private static func read() throws -> Record? {
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

    static func credential(for expected: StoryModelConfiguration) throws -> String {
        guard let record = try read() else { throw StoryModelVaultError.configurationChanged }
        let actual = try record.validated()
        guard expected.endpoint.baseURL == nil, expected == actual else { throw StoryModelVaultError.configurationChanged }
        return record.apiKey
    }

    public static func save(endpoint: String, model: String, apiKey: String) throws {
        let record = Record(endpoint: endpoint, model: model, apiKey: apiKey)
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
