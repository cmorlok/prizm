import XCTest
@testable import Prizm

/// Prelogin and token responses: the new fields are read first, the old ones only by the legacy
/// adapters (openspec change `fix-kdf-derivation-and-validation`, D5).
///
/// "Not consulted" is shown without a spy: the old fields are given a value of the wrong type. The
/// legacy readers decode with `decodeIfPresent`, which throws on a wrong type, so the response only
/// decodes if they were never called.
final class KdfResponseDecodingTests: XCTestCase {

    private func prelogin(_ json: String) throws -> PreLoginResponse {
        try JSONDecoder().decode(PreLoginResponse.self, from: Data(json.utf8))
    }

    private func token(_ json: String) throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
    }

    private let pbkdf2 = KdfParams(type: .pbkdf2, iterations: 600_000, memory: nil, parallelism: nil)
    private let argon = KdfParams(type: .argon2id, iterations: 3, memory: 64, parallelism: 4)

    // MARK: - 5.1 Prelogin

    /// Vaultwarden 1.37.4 (`src/api/core/accounts.rs:1412-1424`): both shapes, `salt` null.
    func testPrelogin_vaultwarden1374() throws {
        let r = try prelogin("""
            {"kdf":1,"kdfIterations":3,"kdfMemory":64,"kdfParallelism":4,
             "kdfSettings":{"iterations":3,"kdfType":1,"memory":64,"parallelism":4},"salt":null}
            """)
        XCTAssertEqual(r.kdfParams, argon)
        XCTAssertNil(r.salt)
    }

    /// Official server (`PasswordPreloginResponseModel.cs`): both shapes and a `salt`.
    func testPrelogin_official_withSalt() throws {
        let r = try prelogin("""
            {"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null,
             "kdfSettings":{"kdfType":0,"iterations":600000,"memory":null,"parallelism":null},
             "salt":"alice@example.com"}
            """)
        XCTAssertEqual(r.kdfParams, pbkdf2)
        XCTAssertEqual(r.salt, "alice@example.com")
    }

    /// After PM-28143 the flat fields are gone.
    func testPrelogin_onlyKdfSettings() throws {
        let r = try prelogin(#"{"kdfSettings":{"kdfType":1,"iterations":3,"memory":64,"parallelism":4},"salt":"a@b.c"}"#)
        XCTAssertEqual(r.kdfParams, argon)
    }

    /// Vaultwarden 1.35.4: flat fields only, read by `LegacyPreloginKdfFields`.
    func testPrelogin_vaultwarden1354_flatFieldsOnly() throws {
        let r = try prelogin(#"{"kdf":1,"kdfIterations":3,"kdfMemory":64,"kdfParallelism":4}"#)
        XCTAssertEqual(r.kdfParams, argon)
        XCTAssertNil(r.salt)
    }

    func testPrelogin_kdfSettingsWin_legacyFieldsNotRead() throws {
        let r = try prelogin("""
            {"kdf":"wrong type","kdfIterations":5000,
             "kdfSettings":{"kdfType":1,"iterations":3,"memory":64,"parallelism":4}}
            """)
        XCTAssertEqual(r.kdfParams, argon)
    }

    func testPrelogin_pascalCase() throws {
        let r = try prelogin(#"{"KdfSettings":{"KdfType":1,"Iterations":3,"Memory":64,"Parallelism":4},"Salt":"x@y.z"}"#)
        XCTAssertEqual(r.kdfParams, argon)
        XCTAssertEqual(r.salt, "x@y.z")
    }

    func testPrelogin_noUsableSettings_hasNone() throws {
        XCTAssertNil(try prelogin(#"{"salt":null}"#).kdfParams)
        XCTAssertNil(try prelogin(#"{"kdfSettings":{"kdfType":7,"iterations":3}}"#).kdfParams, "unknown type")
        XCTAssertNil(try prelogin(#"{"kdfSettings":{"kdfType":0}}"#).kdfParams, "no iterations")
    }

    // MARK: - 5.2 Token response

    private let tokenHead = #""access_token":"at","expires_in":3600,"token_type":"Bearer","refresh_token":"rt""#

    /// Vaultwarden 1.37.4 (`src/api/identity.rs:536-591`): top-level and PascalCase nested fields.
    func testToken_vaultwarden1374() throws {
        let r = try token("""
            {\(tokenHead),"Key":"2.legacy","Kdf":0,"KdfIterations":600000,"KdfMemory":null,"KdfParallelism":null,
             "UserDecryptionOptions":{"HasMasterPassword":true,"MasterPasswordUnlock":{
               "Kdf":{"KdfType":1,"Iterations":3,"Memory":64,"Parallelism":4},
               "MasterKeyEncryptedUserKey":"2.new","MasterKeyWrappedUserKey":"2.new","Salt":"alice@example.com"}}}
            """)
        XCTAssertEqual(r.key, "2.new", "MasterPasswordUnlock wins over the top-level Key")
        XCTAssertEqual(r.kdfSettings?.kdfParams, argon)
        XCTAssertEqual(r.masterPasswordUnlock?.salt, "alice@example.com")
        XCTAssertNil(r.legacyUserKey)
    }

    func testToken_camelCase() throws {
        let r = try token("""
            {\(tokenHead),"userDecryptionOptions":{"masterPasswordUnlock":{
               "kdf":{"kdfType":0,"iterations":600000,"memory":null,"parallelism":null},
               "masterKeyEncryptedUserKey":"2.new","salt":"a@b.c"}}}
            """)
        XCTAssertEqual(r.key, "2.new")
        XCTAssertEqual(r.kdfSettings?.kdfParams, pbkdf2)
    }

    /// Vaultwarden 1.34.0 style: top-level `Key` and `Kdf*` only, read by `LegacyTokenUserKeyFields`.
    func testToken_legacyTopLevelFieldsOnly() throws {
        let r = try token(#"{\#(tokenHead),"Key":"2.legacy","Kdf":0,"KdfIterations":600000,"PrivateKey":"2.pk"}"#)
        XCTAssertEqual(r.key, "2.legacy")
        XCTAssertEqual(r.kdfSettings?.kdfParams, pbkdf2)
        XCTAssertEqual(r.privateKey, "2.pk")
    }

    func testToken_masterPasswordUnlockWins_legacyFieldsNotRead() throws {
        let r = try token("""
            {\(tokenHead),"Key":42,"Kdf":"wrong type",
             "UserDecryptionOptions":{"MasterPasswordUnlock":{"MasterKeyEncryptedUserKey":"2.new"}}}
            """)
        XCTAssertEqual(r.key, "2.new")
    }

    func testToken_userDecryptionOptionsWithoutMasterPasswordUnlock_usesLegacyFields() throws {
        let r = try token(#"{\#(tokenHead),"Key":"2.legacy","UserDecryptionOptions":{"HasMasterPassword":true}}"#)
        XCTAssertEqual(r.key, "2.legacy")
    }

    func testToken_otherFieldsStillDecode() throws {
        let r = try token(#"{\#(tokenHead),"Key":"2.k","TwoFactorToken":"tf","UserId":"u1","Email":"e@x.y","Name":"N"}"#)
        XCTAssertEqual(r.accessToken, "at")
        XCTAssertEqual(r.refreshToken, "rt")
        XCTAssertEqual(r.twoFactorToken, "tf")
        XCTAssertEqual(r.userId, "u1")
        XCTAssertEqual(r.email, "e@x.y")
        XCTAssertEqual(r.name, "N")
    }
}
