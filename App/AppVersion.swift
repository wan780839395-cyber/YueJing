import Foundation

struct AppVersion: Equatable, Sendable {
    let version: String
    let build: String

    init(info: [String: Any]) {
        func value(_ key: String) -> String {
            guard let text = info[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未知" }
            return text
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary ?? [:]) }
    var displayText: String { "\(version)（构建 \(build)）" }
}
