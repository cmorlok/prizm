import Foundation
import os.log

// LEGACY(Bitwarden server < v2025.1.0, no organizationUserId in the profile): remove when those versions are no longer supported

/// The collection-create body for servers whose sync profile has no `organizationUserId`
/// (openspec change fix-collection-access-on-rename, design D3).
///
/// Without that id Prizm cannot assign the creator, so it sends the body it always sent (no
/// members, no groups). Those servers accept it when admins may access all collection items.
/// Used only when the profile has no `organizationUserId` key at all, and never for a rename,
/// which must always resend the access list it read.
nonisolated enum LegacyCollectionCreateWithoutMembership {
    private static let logger = Logger(subsystem: "com.prizm", category: "LegacyCollectionCreate")

    static func request(encryptedName: String) -> CollectionWriteRequest {
        logger.info("Creating a collection without assigning the creator: the server sends no organizationUserId")
        return CollectionWriteRequest(name: encryptedName, externalId: nil, users: [], groups: [])
    }
}
