import Foundation
import Security

public struct CredentialStore: Sendable {
    private let service = "com.myujigu.menubar"
    private let account = "spotify-sp-dc"

    public init() {}

    public func load() -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["SP_DC"], !environmentValue.isEmpty {
            return environmentValue
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }

        return nil
    }

    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }

        var insert = base
        insert[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }
}

public enum CredentialError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Could not save the Spotify cookie in Keychain (\(status))."
        }
    }
}
