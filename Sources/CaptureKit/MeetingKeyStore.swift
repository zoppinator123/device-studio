import CryptoKit
import Foundation
import Security

public enum KeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case missing
    case corrupt
}

/// One random 256-bit key per meeting, kept in the login Keychain as "this device only, after first unlock"
///, so recording and later retries work with the screen locked but the key never syncs or moves
/// to another Mac. Destroying the key is what makes a meeting's audio unrecoverable.
///
/// A master key wrapped by the Secure Enclave is not built yet; until it is, each meeting key is stored
/// directly. It never leaves the Keychain except into memory while recording.
public struct MeetingKeyStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ meetingID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: meetingID,
         kSecAttrSynchronizable as String: false]
    }

    /// Create and store a fresh key. Refuses to replace an existing one: that would orphan its audio.
    public func create(for meetingID: String) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var item = query(meetingID)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Meeting recording key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return key
    }

    public func load(for meetingID: String) throws -> SymmetricKey {
        var q = query(meetingID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw KeyStoreError.missing }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        guard let data = out as? Data, data.count == 32 else { throw KeyStoreError.corrupt }
        return SymmetricKey(data: data)
    }

    /// Delete the key. Missing is not an error: the meeting is already unreadable.
    public func destroy(for meetingID: String) throws {
        let status = SecItemDelete(query(meetingID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.keychain(status) }
    }
}
