import CryptoKit
import Foundation
import Security

/// Encrypts session files at rest with AES-256-GCM.
///
/// The key is 32 random bytes created once and kept only in the Keychain
/// (service "dsh-proper", account "session_key"); it never touches disk.
/// File format: `magic` followed by the AES-GCM combined box
/// (12-byte nonce, ciphertext, 16-byte tag). GCM authenticates the file,
/// so a wrong key and a tampered file are both detected, never misread.
enum SessionCipher {
    static let magic = Data("DSHENC1\n".utf8)
    static let keychainAccount = "session_key"

    enum Opened {
        case decrypted(Data)
        /// A file written before encryption existed (or garbage, which the
        /// JSON decoder then rejects). The caller re-saves it encrypted.
        case legacyPlaintext(Data)
        /// Encrypted, but it can't be opened now. The file must be left
        /// exactly as it is: the key may come back (Keychain unlocked,
        /// access allowed), and overwriting or moving it would lose it.
        case undecryptable(String)
    }

    enum KeyError: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case malformedKey
        var description: String {
            switch self {
            case .keychain(let st): return "Keychain error \(st)"
            case .malformedKey: return "the stored session key is malformed"
            }
        }
    }

    /// Lets tests swap keys (e.g. to simulate a lost key).
    static var keyOverride: SymmetricKey? {
        get { lock.lock(); defer { lock.unlock() }; return _override }
        set { lock.lock(); _override = newValue; lock.unlock() }
    }
    private static var _override: SymmetricKey?
    private static var cached: SymmetricKey?
    private static let lock = NSLock()

    static func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = _override ?? cached { return k }
        // Tests and preview fixtures never touch the real Keychain.
        if Settings.isTestRun || Preview.enabled {
            let k = SymmetricKey(size: .bits256)
            cached = k
            return k
        }
        let (stored, status) = Keychain.lookup(keychainAccount)
        switch status {
        case errSecSuccess:
            guard let s = stored, let raw = Data(base64Encoded: s), raw.count == 32 else {
                // Never replace an existing item: files sealed with it would
                // become unreadable for good.
                throw KeyError.malformedKey
            }
            let k = SymmetricKey(data: raw)
            cached = k
            return k
        case errSecItemNotFound:
            let k = SymmetricKey(size: .bits256)
            let raw = k.withUnsafeBytes { Data($0) }
            let st = Keychain.set(keychainAccount, raw.base64EncodedString())
            guard st == errSecSuccess else { throw KeyError.keychain(st) }
            cached = k
            return k
        default:
            // Denied, locked, or unavailable. Don't create a new key here
            // either: that would overwrite the real one. Retry next time.
            throw KeyError.keychain(status)
        }
    }

    static func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key()).combined else {
            throw KeyError.malformedKey // unreachable with the default 12-byte nonce
        }
        return magic + combined
    }

    static func isSealed(_ data: Data) -> Bool { data.prefix(magic.count) == magic }

    static func open(_ data: Data) -> Opened {
        guard isSealed(data) else { return .legacyPlaintext(data) }
        let k: SymmetricKey
        do { k = try key() } catch { return .undecryptable("key unavailable (\(error))") }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            return .decrypted(try AES.GCM.open(box, using: k))
        } catch {
            return .undecryptable("wrong key or damaged file")
        }
    }
}
