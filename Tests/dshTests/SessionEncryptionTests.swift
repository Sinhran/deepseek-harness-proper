import CryptoKit
import XCTest
@testable import DSHCore

/// Session files are encrypted at rest (AES-256-GCM, key in the Keychain;
/// tests use an in-memory key). Plaintext from older versions still loads
/// and is re-encrypted on save; files that can't be decrypted are never
/// moved, overwritten, or quarantined.
final class SessionEncryptionTests: XCTestCase {
    private let store = SessionStore.shared

    private func file(_ id: UUID) -> URL {
        Settings.sessionsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private func sessionWithSecret(_ secret: String) -> Session {
        var s = Session(title: "enc-\(secret)", workspace: "/tmp", model: "m")
        s.messages.append(Message(role: .user, content: "secret \(secret)"))
        s.changes.append(FileChange(path: "/tmp/a.txt", before: "old \(secret)", after: "new", turn: 1))
        return s
    }

    func testSessionFileIsEncryptedOnDisk() throws {
        let secret = UUID().uuidString
        let s = sessionWithSecret(secret)
        store.adopt(s); store.flush()
        addTeardownBlock { self.store.delete(s.id); self.store.flush() }

        let raw = try Data(contentsOf: file(s.id))
        XCTAssertTrue(SessionCipher.isSealed(raw), "written with the encrypted format")
        XCTAssertNil(raw.range(of: Data(secret.utf8)), "no message or file-change text in the clear")

        let loaded = try XCTUnwrap(store.load(s.id))
        XCTAssertEqual(loaded.messages.first?.content, "secret \(secret)")
        XCTAssertEqual(loaded.changes.first?.before, "old \(secret)")
    }

    func testLegacyPlaintextLoadsAndIsReencryptedOnSave() throws {
        let secret = UUID().uuidString
        let s = sessionWithSecret(secret)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(s).write(to: file(s.id))  // a pre-encryption file

        let loaded = try XCTUnwrap(store.load(s.id), "old plaintext sessions keep working")
        XCTAssertEqual(loaded.messages.first?.content, "secret \(secret)")

        store.adopt(loaded); store.flush()
        addTeardownBlock { self.store.delete(s.id); self.store.flush() }
        let raw = try Data(contentsOf: file(s.id))
        XCTAssertTrue(SessionCipher.isSealed(raw))
        XCTAssertNil(raw.range(of: Data(secret.utf8)), "the plaintext was replaced")
    }

    func testFileSealedWithAnotherKeyIsLeftUntouched() throws {
        let id = UUID()
        let u = file(id)
        SessionCipher.keyOverride = SymmetricKey(size: .bits256)  // "the old key"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try SessionCipher.seal(enc.encode(sessionWithSecret("x"))).write(to: u)
        SessionCipher.keyOverride = nil
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        let before = try Data(contentsOf: u)

        XCTAssertNil(store.load(id), "can't be opened with the current key")
        XCTAssertNotNil(store.undecryptable[id], "reported, so the UI can say so")
        XCTAssertEqual(try Data(contentsOf: u), before, "left exactly as it was, not quarantined or rewritten")
    }

    func testTamperedFileIsRejectedNotMisread() throws {
        let s = sessionWithSecret("t")
        store.adopt(s); store.flush()
        addTeardownBlock { self.store.delete(s.id); self.store.flush() }
        var raw = try Data(contentsOf: file(s.id))
        raw[raw.count - 20] ^= 0x01
        try raw.write(to: file(s.id))

        XCTAssertNil(store.load(s.id), "GCM authentication catches a single flipped bit")
        XCTAssertNotNil(store.undecryptable[s.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(s.id).path))
    }
}
