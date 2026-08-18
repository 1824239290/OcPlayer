import Foundation

struct DandanplayCredentials: Equatable, Sendable {
    let appID: String
    let appSecret: String
}

enum AppConfiguration {
    private enum InfoKey {
        static let dandanplayAppID = "DandanplayAppId"
        static let dandanplayAppSecret = "DandanplayAppSecret"
    }

    /// Returns nil until both values have been supplied through Secrets.xcconfig.
    static var dandanplayCredentials: DandanplayCredentials? {
        dandanplayCredentials(in: .main)
    }

    static func dandanplayCredentials(in bundle: Bundle) -> DandanplayCredentials? {
        guard
            let appID = nonEmptyString(bundle.object(forInfoDictionaryKey: InfoKey.dandanplayAppID)),
            let appSecret = nonEmptyString(bundle.object(forInfoDictionaryKey: InfoKey.dandanplayAppSecret))
        else {
            return nil
        }
        return DandanplayCredentials(appID: appID, appSecret: appSecret)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
