// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Keeps the API keys of the language model services in the user's login keychain, one item per
/// service. A key is stored nowhere else; the settings only count how often one was changed
/// (`AppSettings.llmKeyRevision`).
///
/// The items are generic passwords of the file-based keychain, which an app can use without a
/// developer's signature and without entitlements. macOS ties an item to the signature of the
/// app that made it: after a build that is not signed by a developer it asks the user before it
/// hands the key out.
enum KeychainStore {
    /// What the items are filed under. The tests run inside the app and get a name of their own,
    /// so that nothing they store or leave behind can ever be taken for a key of the user.
    static let service = (Bundle.main.bundleIdentifier ?? "io.github.sopitz.MirrorAct")
        + (AppDelegate.isTesting ? ".llm.tests" : ".llm")

    private static let lock = NSLock()
    /// The keys read or stored since the app started, by service; "" = removed. The keychain is
    /// asked once per key that way, a key it did not take is still there to translate with, and
    /// a key it did not let go of is not used anymore.
    private static var remembered: [String: String] = [:]

    /// The key of a service; nil when there is none or the keychain does not hand it out
    static func key(for providerID: String) -> String? {
        if let known = rememberedKey(for: providerID) { return known.isEmpty ? nil : known }
        var query = item(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // Refused (the user said no to the question of macOS, the keychain is locked …):
            // the item stays where it is, and the user is asked to enter the key again.
            if status != errSecItemNotFound {
                Log.error("Keychain: the key for \(providerID) could not be read (OSStatus \(status))")
            }
            return nil
        }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        remember(key, for: providerID)
        return key
    }

    /// Whether there is a key for a service. Does not read the key, so macOS has nothing to ask
    /// the user about.
    static func hasKey(for providerID: String) -> Bool {
        if let known = rememberedKey(for: providerID) { return !known.isEmpty }
        var query = item(for: providerID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores the key of a service; nil or an empty key removes it.
    ///
    /// false = the keychain did not take the change. A key it did not take is kept until the
    /// app quits, so that translating works in the meantime.
    @discardableResult
    static func set(_ key: String?, for providerID: String) -> Bool {
        // a key copied from a web page often brings a line break along
        let key = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Replaced, not updated: a new item belongs to this build of the app, which can then
        // read it without a question of macOS.
        var status = SecItemDelete(item(for: providerID) as CFDictionary)
        if status == errSecItemNotFound { status = errSecSuccess }
        if status == errSecSuccess, !key.isEmpty {
            var attributes = item(for: providerID)
            attributes[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.error("Keychain: the key for \(providerID) could not be \(key.isEmpty ? "removed" : "stored") (OSStatus \(status))")
        }
        remember(key, for: providerID)
        // whoever translates right now starts over with the new key
        if Thread.isMainThread {
            AppSettings.shared.llmKeyRevision += 1
        } else {
            DispatchQueue.main.async { AppSettings.shared.llmKeyRevision += 1 }
        }
        return status == errSecSuccess
    }

    /// Forgets the keys read or stored so far, as if the app had just been started (for the tests)
    static func forgetRememberedKeys() {
        lock.lock()
        remembered = [:]
        lock.unlock()
    }

    /// What finds the item of a service: always its class, the service name and the account,
    /// so that no item of another app can be meant
    private static func item(for providerID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: providerID]
    }

    private static func rememberedKey(for providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return remembered[providerID]
    }

    private static func remember(_ key: String, for providerID: String) {
        lock.lock()
        remembered[providerID] = key
        lock.unlock()
    }
}
