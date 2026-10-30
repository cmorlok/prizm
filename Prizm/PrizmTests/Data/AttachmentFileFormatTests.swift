import CryptoKit
import XCTest
@testable import Prizm

/// The official attachment file layout, reading Prizm's old layout, refusing type 0 and malformed
/// blobs, and converting old files (openspec change fix-attachment-file-format, tasks 1.1, 2.1–2.3,
/// 3.1–3.3).
@MainActor
final class AttachmentFileFormatTests: XCTestCase {

    private let crypto = PrizmCryptoServiceImpl()
    private let key64 = Data((0..<64).map { UInt8($0) })

    // MARK: - 1.1 / 2.1 Known-answer vector

    /// Bitwarden SDK `crates/bitwarden-wasm-internal/src/pure_crypto.rs:396-411` (`KEY`,
    /// `ENCRYPTED_BYTES`), test `test_symmetric_decrypt_array_buffer` at :486-491, sdk-internal
    /// commit c1c9b9a540510f9f8b3f4eb37c0738f510f89b98.
    private static let sdkKey = Data([
        81, 142, 1, 228, 222, 3, 3, 133, 34, 176, 35, 66, 150, 6, 109, 70, 190, 149, 47, 47, 89,
        23, 144, 87, 92, 46, 220, 13, 148, 106, 162, 234, 202, 139, 136, 33, 16, 200, 8, 73, 176,
        172, 185, 187, 224, 10, 65, 223, 228, 54, 92, 181, 8, 213, 162, 221, 117, 254, 245, 111,
        55, 211, 77, 29,
    ])
    private static let sdkEncryptedBytes = Data([
        2, 209, 195, 115, 49, 205, 253, 128, 162, 169, 246, 175, 217, 144, 73, 108, 191, 27, 113,
        69, 55, 94, 142, 62, 129, 204, 173, 130, 37, 42, 97, 209, 25, 192, 64, 126, 112, 139, 248,
        2, 89, 112, 178, 83, 25, 77, 130, 187, 127, 85, 179, 211, 159, 186, 111, 44, 109, 211, 18,
        120, 104, 144, 4, 76, 3,
    ])

    func testSDKVector_decryptsToTest() throws {
        let plain = try crypto.decryptData(Self.sdkEncryptedBytes, attachmentKey: Self.sdkKey)
        XCTAssertEqual(plain, Data("test".utf8))
    }

    // MARK: - 2.2 Written layout

    func testEncrypt_writesTheOfficialLayout() throws {
        let plain = Data(repeating: 0x41, count: 10)
        let blob = try crypto.encryptData(plain, attachmentKey: key64)

        XCTAssertEqual(blob.count, 65, "49 + 16k")
        XCTAssertEqual(blob.first, 0x02)
        let bytes = [UInt8](blob)
        let iv = Data(bytes[1..<17])
        let mac = Data(bytes[17..<49])
        let ciphertext = Data(bytes[49...])
        let expected = HMAC<SHA256>.authenticationCode(for: iv + ciphertext, using: SymmetricKey(data: key64[32..<64]))
        XCTAssertEqual(mac, Data(expected))
    }

    func testEncrypt_lengthIs49Plus16k() throws {
        for size in [0, 1, 15, 16, 17, 100] {
            let blob = try crypto.encryptData(Data(count: size), attachmentKey: key64)
            XCTAssertEqual(blob.count % 16, 1, "size \(size)")
            XCTAssertGreaterThanOrEqual(blob.count, 65)
        }
    }

    // MARK: - 2.3 Reading by structure

    /// Prizm 1.1.0–1.5.x layout, `IV ‖ ciphertext ‖ MAC`, rebuilt from an official blob (the MAC
    /// covers the same bytes in both layouts).
    private func legacyBlob(_ plain: Data, ivStartingWith first: UInt8? = nil) throws -> Data {
        while true {
            let official = [UInt8](try crypto.encryptData(plain, attachmentKey: key64))
            if let first, official[1] != first { continue }
            return Data(official[1..<17]) + Data(official[49...]) + Data(official[17..<49])
        }
    }

    func testLegacyBlob_opens() throws {
        let plain = Data("an old Prizm upload".utf8)
        let blob = try legacyBlob(plain)
        XCTAssertEqual(blob.count % 16, 0)
        XCTAssertEqual(try crypto.decryptData(blob, attachmentKey: key64), plain)
        XCTAssertEqual(try AttachmentBlobLayout.of(blob), .legacyPrizm)
    }

    func testLegacyBlobWhoseIVStartsWith0x02_opens() throws {
        let plain = Data("unlucky IV".utf8)
        let blob = try legacyBlob(plain, ivStartingWith: 0x02)
        XCTAssertEqual(blob.first, 0x02)
        XCTAssertEqual(try crypto.decryptData(blob, attachmentKey: key64), plain)
    }

    func testOfficialBlob_isDetected() throws {
        XCTAssertEqual(try AttachmentBlobLayout.of(Self.sdkEncryptedBytes), .official)
    }

    func testType0_isRefused() throws {
        // 0x00 ‖ IV(16) ‖ ciphertext(16k), no MAC.
        let blob = Data([0x00]) + Data(repeating: 0x11, count: 16) + Data(repeating: 0x22, count: 32)
        XCTAssertThrowsError(try crypto.decryptData(blob, attachmentKey: key64)) { error in
            XCTAssertEqual(error as? AttachmentCryptoError, .unsupportedEncryptionType)
        }
    }

    func testOtherTypeByte_isRefused() throws {
        let blob = Data([0x05]) + Data(repeating: 0x11, count: 64)
        XCTAssertThrowsError(try crypto.decryptData(blob, attachmentKey: key64)) { error in
            XCTAssertEqual(error as? AttachmentCryptoError, .unsupportedEncryptionType)
        }
    }

    func testMalformedLengths_areRefused() throws {
        for length in [0, 49, 50, 63, 16 * 5 + 5, 48] {
            XCTAssertThrowsError(try crypto.decryptData(Data(repeating: 0x02, count: length), attachmentKey: key64),
                                 "length \(length)") { error in
                XCTAssertEqual(error as? AttachmentCryptoError, .malformedBlob, "length \(length)")
            }
        }
    }

    func testFlippedByte_inEitherLayout_isAMacMismatch() throws {
        var official = try crypto.encryptData(Data("secret".utf8), attachmentKey: key64)
        official[official.startIndex + 60] ^= 0x01
        XCTAssertThrowsError(try crypto.decryptData(official, attachmentKey: key64)) { error in
            XCTAssertEqual(error as? AttachmentCryptoError, .macMismatch)
        }
        var legacy = try legacyBlob(Data("secret".utf8))
        legacy[legacy.startIndex + 20] ^= 0x01
        XCTAssertThrowsError(try crypto.decryptData(legacy, attachmentKey: key64)) { error in
            XCTAssertEqual(error as? AttachmentCryptoError, .macMismatch)
        }
    }

    // MARK: - 3.1 Size hint

    func testMapper_flagsSizesThatAreMultiplesOf16() throws {
        let keys = KeyedCipherBuilder.randomKeys()
        func dto(size: String) -> AttachmentDTO {
            try! JSONDecoder().decode(AttachmentDTO.self, from: JSONSerialization.data(withJSONObject: [
                "id": "a", "fileName": KeyedCipherBuilder.encrypt("f.txt", keys: keys),
                "key": KeyedCipherBuilder.encrypt("k", keys: keys), "size": size, "sizeName": "1 KB",
            ]))
        }
        XCTAssertTrue(try AttachmentMapper().map(dto(size: "1072"), cipherKey: keys).storedInLegacyPrizmFormat)
        XCTAssertFalse(try AttachmentMapper().map(dto(size: "1073"), cipherKey: keys).storedInLegacyPrizmFormat)
    }

    // MARK: - 3.2 Conversion in the repository

    private let cipherId = "cipher-1"
    private let cipherKeys = KeyedCipherBuilder.randomKeys()

    private struct ConversionRig {
        let repo: AttachmentRepositoryImpl
        let api: MockPrizmAPIClient
        let vault: MockVaultRepository
        let attachment: Attachment
        let plain: Data
    }

    /// An attachment whose file is `blob(plain, attachmentKey)` and whose key is wrapped with `wrapKeys`.
    private func makeConversionRig(
        legacy: Bool = true, wrappedWith wrapKeys: CryptoKeys? = nil, flagged: Bool = false
    ) throws -> ConversionRig {
        let plain = Data("quarterly plan".utf8)
        let attachmentKey = try crypto.generateSymmetricKey()
        let official = [UInt8](try crypto.encryptData(plain, attachmentKey: attachmentKey))
        let blob = legacy
            ? Data(official[1..<17]) + Data(official[49...]) + Data(official[17..<49])
            : Data(official)
        let api = MockPrizmAPIClient()
        api.downloadBlobResult = blob
        let attachment = Attachment(
            id: "att-old", fileName: "plan.pdf",
            encryptedKey: try crypto.encryptAttachmentKey(attachmentKey, cipherKey: wrapKeys ?? cipherKeys),
            size: blob.count, sizeName: "64 B", url: nil,
            wrappedWithPersonalKey: flagged, storedInLegacyPrizmFormat: blob.count % 16 == 0)
        let vault = MockVaultRepository()
        let repo = AttachmentRepositoryImpl(apiClient: api, crypto: crypto, vaultRepository: vault)
        return ConversionRig(repo: repo, api: api, vault: vault, attachment: attachment, plain: plain)
    }

    func testConvert_uploadsTheOfficialLayout_thenDeletesTheOld() async throws {
        let rig = try makeConversionRig()

        let converted = try await rig.repo.convertLegacyFormat(
            cipherId: cipherId, attachment: rig.attachment,
            downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())

        XCTAssertEqual(converted.id, "att-123", "The new attachment")
        XCTAssertEqual(converted.fileName, "plan.pdf")
        XCTAssertFalse(converted.storedInLegacyPrizmFormat)
        XCTAssertEqual(rig.api.uploadBitwardenHostedCallCount, 1)
        let sent = try XCTUnwrap(rig.api.lastUploadedBlob)
        XCTAssertEqual(try AttachmentBlobLayout.of(sent), .official)
        XCTAssertEqual(rig.api.deleteAttachmentCallCount, 1)
        XCTAssertEqual(rig.api.lastDeletedAttachmentId, "att-old")
        // The new file decrypts with a new attachment key wrapped under the cipher key.
        let request = try XCTUnwrap(rig.api.lastAttachmentMetadataRequest)
        let newKey = try crypto.decryptAttachmentKey(request.key, cipherKey: cipherKeys)
        XCTAssertEqual(try crypto.decryptData(sent, attachmentKey: newKey), rig.plain)
    }

    /// Task 3.2: after a conversion against a server that answers without the item, the local list
    /// holds only the new attachment.
    func testConvert_localListEndsWithOnlyTheNewAttachment() async throws {
        let rig = try makeConversionRig()
        let item = VaultItem(id: cipherId, name: "Plan", isFavorite: false, isDeleted: false, creationDate: Date(),
                             revisionDate: Date(), content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
                             attachments: [rig.attachment])
        await rig.vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        _ = try await rig.repo.convertLegacyFormat(
            cipherId: cipherId, attachment: rig.attachment,
            downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())

        XCTAssertEqual(rig.vault.lastUpdatedAttachments?.map(\.id), ["att-123"])
    }

    func testConvert_serverRejects_reportsItsMessage_andKeepsTheOld() async throws {
        let rig = try makeConversionRig()
        rig.api.createAttachmentMetadataShouldThrow = APIError.httpError(
            statusCode: 400, body: #"{"message":"Attachment storage limit reached!","object":"error"}"#)

        do {
            _ = try await rig.repo.convertLegacyFormat(
                cipherId: cipherId, attachment: rig.attachment,
                downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())
            XCTFail("The rejection must be reported")
        } catch let error as AttachmentError {
            XCTAssertEqual(error.errorDescription, "The server rejected the upload: Attachment storage limit reached!")
        }
        XCTAssertEqual(rig.api.deleteAttachmentCallCount, 0, "The old file stays")
    }

    func testConvert_uploadFails_rollsBackTheNewRecord_andKeepsTheOld() async throws {
        let rig = try makeConversionRig()
        rig.api.uploadBitwardenHostedShouldThrow = URLError(.networkConnectionLost)

        do {
            _ = try await rig.repo.convertLegacyFormat(
                cipherId: cipherId, attachment: rig.attachment,
                downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())
            XCTFail("The failure must be reported")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(rig.api.deleteAttachmentCallCount, 1, "Only the rollback")
        XCTAssertEqual(rig.api.lastDeletedAttachmentId, "att-123", "The new record, not the old one")
    }

    func testConvert_deleteOfTheOldFails_reportsBothKept() async throws {
        let rig = try makeConversionRig()
        rig.api.deleteAttachmentShouldThrow = URLError(.timedOut)

        do {
            _ = try await rig.repo.convertLegacyFormat(
                cipherId: cipherId, attachment: rig.attachment,
                downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())
            XCTFail("The partial success must be reported")
        } catch AttachmentError.convertedOldCopyLeft {
            XCTAssertEqual(AttachmentError.convertedOldCopyLeft.errorDescription,
                           "Converted, but the old copy could not be removed. Delete it from the item.")
        }
        XCTAssertEqual(rig.api.uploadBitwardenHostedCallCount, 1)
    }

    func testConvert_officialBlob_changesNothing() async throws {
        let rig = try makeConversionRig(legacy: false)

        do {
            _ = try await rig.repo.convertLegacyFormat(
                cipherId: cipherId, attachment: rig.attachment,
                downloadKey: cipherKeys.toData(), uploadKey: cipherKeys.toData())
            XCTFail("Nothing to convert")
        } catch AttachmentError.alreadyStandardFormat {
            XCTAssertEqual(AttachmentError.alreadyStandardFormat.errorDescription,
                           "This file is already in the standard format.")
        }
        XCTAssertEqual(rig.api.createAttachmentMetadataCallCount, 0, "No write calls")
        XCTAssertEqual(rig.api.deleteAttachmentCallCount, 0)
    }

    func testConvert_flaggedAttachmentInTheOfficialLayout_isStillConverted() async throws {
        let personal = KeyedCipherBuilder.randomKeys()
        let rig = try makeConversionRig(legacy: false, wrappedWith: personal, flagged: true)

        _ = try await rig.repo.convertLegacyFormat(
            cipherId: cipherId, attachment: rig.attachment,
            downloadKey: personal.toData(), uploadKey: cipherKeys.toData())

        XCTAssertEqual(rig.api.uploadBitwardenHostedCallCount, 1, "Its key still has to move to the org key")
    }

    // MARK: - 3.3 Conversion of an org attachment uses the org key

    private func makeOrgUseCase(api: MockPrizmAPIClient, vaultKeys: CryptoKeys, orgKeys: CryptoKeys) async -> ConvertAttachmentUseCaseImpl {
        let cryptoService = PrizmCryptoServiceImpl()
        await cryptoService.unlockWith(keys: vaultKeys)
        let cache = VaultKeyCache()
        await cache.populate(sources: [cipherId: .organization(orgId: "org-1")])
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        return ConvertAttachmentUseCaseImpl(
            repository: AttachmentRepositoryImpl(apiClient: api, crypto: cryptoService, vaultRepository: MockVaultRepository()),
            vaultKeyService: VaultKeyServiceImpl(cache: cache, orgKeyCache: orgKeyCache, crypto: cryptoService))
    }

    func testConvertOrgAttachment_wrapsTheNewKeyWithTheOrgKey() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let rig = try makeConversionRig(wrappedWith: orgKeys)
        let convert = await makeOrgUseCase(api: rig.api, vaultKeys: vaultKeys, orgKeys: orgKeys)

        _ = try await convert.execute(cipherId: cipherId, attachment: rig.attachment)

        let request = try XCTUnwrap(rig.api.lastAttachmentMetadataRequest)
        XCTAssertNoThrow(try crypto.decryptAttachmentKey(request.key, cipherKey: orgKeys))
        XCTAssertThrowsError(try crypto.decryptAttachmentKey(request.key, cipherKey: vaultKeys))
    }

    func testConvertFlaggedOrgAttachment_readsWithTheVaultKey_writesWithTheOrgKey() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let rig = try makeConversionRig(wrappedWith: vaultKeys, flagged: true)
        let convert = await makeOrgUseCase(api: rig.api, vaultKeys: vaultKeys, orgKeys: orgKeys)

        let converted = try await convert.execute(cipherId: cipherId, attachment: rig.attachment)

        XCTAssertFalse(converted.wrappedWithPersonalKey)
        let request = try XCTUnwrap(rig.api.lastAttachmentMetadataRequest)
        XCTAssertNoThrow(try crypto.decryptAttachmentKey(request.key, cipherKey: orgKeys))
        XCTAssertThrowsError(try crypto.decryptAttachmentKey(request.key, cipherKey: vaultKeys))
    }

    // MARK: - Download errors the user can read

    func testDownloadOfAType0File_saysTheFormatIsUnsupported() async throws {
        let rig = try makeConversionRig()
        rig.api.downloadBlobResult = Data([0x00]) + Data(repeating: 0x11, count: 48)

        do {
            _ = try await rig.repo.download(cipherId: cipherId, attachment: rig.attachment, cipherKey: cipherKeys.toData())
            XCTFail("A type 0 file must not open")
        } catch AttachmentError.unsupportedFileFormat {
            XCTAssertEqual(AttachmentError.unsupportedFileFormat.errorDescription,
                           "The file uses a format Prizm can't open.")
        }
    }

    func testDownloadOfATamperedFile_saysItCouldNotBeDecrypted() async throws {
        let rig = try makeConversionRig()
        rig.api.downloadBlobResult[rig.api.downloadBlobResult.startIndex + 20] ^= 0x01

        do {
            _ = try await rig.repo.download(cipherId: cipherId, attachment: rig.attachment, cipherKey: cipherKeys.toData())
            XCTFail("A tampered file must not open")
        } catch AttachmentError.fileDecryptionFailed {
            XCTAssertEqual(AttachmentError.fileDecryptionFailed.errorDescription, "The file could not be decrypted.")
        }
    }
}
