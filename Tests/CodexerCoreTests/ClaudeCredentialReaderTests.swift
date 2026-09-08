import Foundation
import Security
import XCTest
@testable import CodexerCore

final class ClaudeCredentialReaderTests: XCTestCase {
    func testDesktopKeyIsReusedWhileProfileCredentialsAreReadFresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A real, isolated Keychain with synthetic data; never query the login Keychain.
        let password = "agentdock-test-password"
        var created: SecKeychain?
        let status = password.withCString { bytes in
            SecKeychainCreate(
                directory.appendingPathComponent("fixture.keychain").path,
                UInt32(password.utf8.count), bytes, false, nil, &created
            )
        }
        XCTAssertEqual(status, errSecSuccess)
        let keychain = try XCTUnwrap(created)
        defer { _ = SecKeychainDelete(keychain) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecUseKeychain as String: keychain,
            kSecValueData as String: Data(password.utf8)
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)

        let official = directory.appendingPathComponent("official", isDirectory: true)
        let managed = directory.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: official, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        // Electron v10 AES-CBC fixtures, PBKDF2-SHA1(password, "saltysalt", 1003), space IV.
        let first = Data(#"{"lastKnownAccountUuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","oauth:tokenCacheV2":"djEwE9y4lgzKGR3SkB2bnuiCGyRu9Thl9kfHsh0glwfcgQ7JEx5myhGSAv+phFvoC2MCpK3VgEvAo7iiuBImTOCnJlWWVmFucBH3ZD5Eh54R/FfVs5Q2SWCckEmFJNct5iZHIBFyAscCYa2D1RO4M25aMGiLjpeJiDJbMqCTX5rGF/7DKydfhLrE1L/+mu8ZbSlQ9d0ZUv9lZmmbV3yKSdljpA=="}"#.utf8)
        let second = Data(#"{"lastKnownAccountUuid":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","oauth:tokenCacheV2":"djEwdg7PGZpJc77QOSdvoS8YSvNkgCSUGYt8jtehMMnLLTWBFO/nW0vRiOmRux5zYnPlMxnx/qWboh+lLeCr44jMIUpJ1p+uh9zLU9+AkB85XR2Ob8uWlNCSZoZDAq8LahFF29uz2K1j6Nbpymx+3jymLP1ZLsHLslNsusecFt9wszx6U/5Z/FYa2swcti8N6tUVfJ3edu1rQVr1kS/l9W6kiA=="}"#.utf8)
        try first.write(to: official.appendingPathComponent("config.json"))
        try second.write(to: managed.appendingPathComponent("config.json"))

        var reader = ClaudeCredentialReader(keychain: keychain)
        XCTAssertEqual(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        )?.accessToken, "synthetic-token-one")

        // Remove only our synthetic item. Subsequent success requires the retained key.
        let deletion: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecMatchSearchList as String: [keychain]
        ]
        XCTAssertEqual(SecItemDelete(deletion as CFDictionary), errSecSuccess)
        let other = try XCTUnwrap(reader.readDesktopCredential(
            userDataURL: managed, allowKeychainInteraction: false
        ))
        XCTAssertEqual(other.accessToken, "synthetic-token-two")
        XCTAssertEqual(other.identity?.accountUUID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        XCTAssertEqual(other.identity?.organizationUUID, "22222222-2222-2222-2222-222222222222")

        // A replaced token/account on the same root must not reuse the old credential.
        try second.write(to: official.appendingPathComponent("config.json"))
        XCTAssertEqual(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        )?.accessToken, "synthetic-token-two")
        try FileManager.default.removeItem(at: official.appendingPathComponent("config.json"))
        XCTAssertNil(reader.readDesktopCredential(
            userDataURL: official, allowKeychainInteraction: false
        ))

        // A new reader has no persisted key and cannot read the now-missing item.
        var freshReader = ClaudeCredentialReader(keychain: keychain)
        XCTAssertNil(freshReader.readDesktopCredential(
            userDataURL: managed, allowKeychainInteraction: false
        ))
    }
}
