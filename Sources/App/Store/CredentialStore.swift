import Foundation
import Security

struct FastPixCredentials: Equatable {
    let tokenId: String
    let secret: String
}

/// FastPix credentials, stored only in the Keychain. Two generic-password items under one
/// service, keyed by account.
enum CredentialStore {
    static var serviceOverride: String?

    private static var service: String { serviceOverride ?? "com.fastpix.screen-to-stream" }
    private static let tokenAccount = "tokenId"
    private static let secretAccount = "secret"

    static func save(_ credentials: FastPixCredentials) throws {
        try set(account: tokenAccount, value: credentials.tokenId)
        try set(account: secretAccount, value: credentials.secret)
    }

    static func load() -> FastPixCredentials? {
        guard let tokenId = get(account: tokenAccount), let secret = get(account: secretAccount) else {
            return nil
        }
        return FastPixCredentials(tokenId: tokenId, secret: secret)
    }

    static func clear() {
        for account in [tokenAccount, secretAccount] {
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary)
        }
    }

    static var basicAuthHeader: String? {
        guard let credentials = load() else { return nil }
        let token = Data("\(credentials.tokenId):\(credentials.secret)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    // MARK: - Keychain primitives

    private static func set(account: String, value: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData] = Data(value.utf8)
        // Allow-all ACL: any process running as the user can read the token, no rebuild re-prompt.
        if let access = allowAllAccess() {
            attributes[kSecAttrAccess] = access
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // Uses the deprecated SecAccess/SecACL API: only it can express an allow-any-app ACL; the
    // modern data-protection keychain needs entitlements an ad-hoc-signed build can't carry (-34018).
    private static func allowAllAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("FastPix" as CFString, [] as CFArray, &access) == errSecSuccess,
              let access else { return nil }

        // Nil trusted-application list on the decrypt ACL means "any app, no prompt".
        if let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] {
            for acl in acls {
                var apps: CFArray?
                var description: CFString?
                var prompt = SecKeychainPromptSelector()
                SecACLCopyContents(acl, &apps, &description, &prompt)
                SecACLSetContents(acl, nil, description ?? "FastPix" as CFString, prompt)
            }
        }
        return access
    }

    private static func get(account: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
