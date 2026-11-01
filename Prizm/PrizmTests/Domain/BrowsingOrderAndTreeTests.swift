import XCTest
@testable import Prizm

/// Trees (task 3.1), sort order (4.1) and the No Folder / My Vault views (2.1–2.2) of
/// `vault-browsing-parity`.
@MainActor
final class BrowsingOrderAndTreeTests: XCTestCase {

    private func login(_ id: String, name: String, username: String? = nil, folderId: String? = nil,
                       organizationId: String? = nil, deleted: Bool = false) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: deleted, creationDate: Date(), revisionDate: Date(),
                  content: .login(LoginContent(username: username, password: nil, uris: [], totp: nil,
                                               notes: nil, customFields: [])),
                  folderId: folderId, organizationId: organizationId)
    }

    private func note(_ id: String, name: String) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: false, creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
    }

    private func repository(_ items: [VaultItem], folders: [Folder] = [], organizations: [Organization] = [],
                            collections: [OrgCollection] = []) async -> VaultRepositoryImpl {
        let repo = await RepositoryFixtures.vaultRepository(apiClient: MockPrizmAPIClient(), crypto: MockPrizmCryptoService())
        await repo.populate(items: items, folders: folders, organizations: organizations,
                            collections: collections, syncedAt: Date())
        return repo
    }

    // MARK: - 3.1 Trees

    func testFolderTree_segmentsDifferingInCase_areSeparateParents() {
        let tree = FolderTreeNode.buildTree(from: [Folder(id: "1", name: "Work/A"), Folder(id: "2", name: "work/B")])
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(Set(tree.map(\.name)), ["Work", "work"])
        XCTAssertTrue(tree.allSatisfy(\.isVirtual), "missing parents stay virtual")
    }

    func testFolderTree_identicalNames_bothAppear() {
        let tree = FolderTreeNode.buildTree(from: [Folder(id: "1", name: "Work"), Folder(id: "2", name: "Work")])
        XCTAssertEqual(Set(tree.compactMap(\.folder?.id)), ["1", "2"])
    }

    func testCollectionTree_segmentsDifferingInCase_areSeparateParents() {
        let tree = CollectionTreeNode.buildTree(from: [
            OrgCollection(id: "1", organizationId: "o", name: "Eng/A"),
            OrgCollection(id: "2", organizationId: "o", name: "eng/B"),
        ])
        XCTAssertEqual(Set(tree.map(\.name)), ["Eng", "eng"])
    }

    func testTreeSiblings_sortNaturally() {
        let tree = FolderTreeNode.buildTree(from: [Folder(id: "1", name: "Server 10"), Folder(id: "2", name: "Server 2")])
        XCTAssertEqual(tree.map(\.name), ["Server 2", "Server 10"])
    }

    // MARK: - 4.1 Sorting

    func testItems_sortNaturally_andLoginsWithEqualNamesByUsername() async throws {
        let repo = await repository([
            login("a", name: "Server 10"), login("b", name: "Server 2"),
            login("c", name: "Google", username: "zoe"), login("d", name: "Google", username: "adam"),
            login("e", name: "Google", username: nil),
        ])
        let ids = try await repo.allItems().map(\.id)
        XCTAssertEqual(ids, ["e", "d", "c", "b", "a"])
    }

    func testItems_equalNonLogins_keepSyncOrder() async throws {
        let repo = await repository([note("x", name: "Same"), note("y", name: "Same"), note("z", name: "Same")])
        let ids = try await repo.allItems().map(\.id)
        XCTAssertEqual(ids, ["x", "y", "z"])
    }

    func testFoldersOrganizationsCollections_sortNaturally() async throws {
        let repo = await repository(
            [], folders: [Folder(id: "1", name: "F 10"), Folder(id: "2", name: "F 2")],
            organizations: [Organization(id: "o1", name: "Org 10", role: .user, membershipId: .notSent), Organization(id: "o2", name: "Org 2", role: .user, membershipId: .notSent)],
            collections: [OrgCollection(id: "c1", organizationId: "o1", name: "C 10"),
                          OrgCollection(id: "c2", organizationId: "o1", name: "C 2")])
        let folders = try await repo.folders().map(\.name)
        let orgs = try await repo.organizations().map(\.name)
        let cols = try await repo.collections().map(\.name)
        XCTAssertEqual(folders, ["F 2", "F 10"])
        XCTAssertEqual(orgs, ["Org 2", "Org 10"])
        XCTAssertEqual(cols, ["C 2", "C 10"])
    }

    // MARK: - 2.1 No Folder and My Vault

    func testNoFolderAndMyVault_indexes() async throws {
        let repo = await repository([
            login("p1", name: "P1"), login("p2", name: "P2", folderId: "f"),
            login("o1", name: "O1", organizationId: "org"), login("o2", name: "O2", folderId: "f", organizationId: "org"),
            login("d", name: "Deleted", deleted: true),
        ], folders: [Folder(id: "f", name: "Work")], organizations: [Organization(id: "org", name: "Org", role: .user, membershipId: .notSent)])
        let noFolder = try await repo.items(for: .noFolder).map(\.id)
        let myVault = try await repo.items(for: .myVault).map(\.id)
        let counts = try await repo.itemCounts()
        XCTAssertEqual(noFolder, ["o1", "p1"], "org items without a folder count too")
        XCTAssertEqual(myVault, ["p1", "p2"])
        XCTAssertEqual(counts[.noFolder], 2)
        XCTAssertEqual(counts[.myVault], 2)
    }

    // MARK: - 2.2 Selection equality

    func testNewSelections_equalOnlyThemselves_andHashApart() {
        let all: [SidebarSelection] = [.allItems, .favorites, .trash, .verificationCodes, .noFolder, .myVault]
        for a in all {
            for b in all {
                XCTAssertEqual(a == b, a.displayName == b.displayName, "\(a) vs \(b)")
            }
        }
        XCTAssertEqual(Set(all.map(\.hashValue)).count, all.count)
        XCTAssertEqual(SidebarSelection.noFolder.displayName, "No Folder")
        XCTAssertEqual(SidebarSelection.myVault.displayName, "My Vault")
    }

    // MARK: - Review findings

    func testSort_mixedTypesWithEqualNames_isConsistent() {
        func login(_ id: String, _ user: String) -> VaultItem {
            VaultItem(id: id, name: "X", isFavorite: false, isDeleted: false, creationDate: Date(), revisionDate: Date(),
                      content: .login(LoginContent(username: user, password: nil, uris: [], totp: nil, notes: nil, customFields: [])))
        }
        let note = VaultItem(id: "n", name: "X", isFavorite: false, isDeleted: false, creationDate: Date(), revisionDate: Date(),
                             content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
        let note2 = VaultItem(id: "n2", name: "X", isFavorite: false, isDeleted: false, creationDate: Date(), revisionDate: Date(),
                              content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
        // Every input order gives the same order: notes (no username) first in sync order, then
        // logins by username.
        let inputs = [[login("z", "zoe"), note, login("a", "adam"), note2],
                      [note, login("a", "adam"), note2, login("z", "zoe")]]
        for input in inputs {
            XCTAssertEqual(VaultSort.items(input).map(\.id), ["n", "n2", "a", "z"])
        }
    }

    func testCardLastFourDigits_ignoreSpacesAndDashes() {
        XCTAssertEqual(VaultSearchMatcher.lastFourDigits(of: "4242 4242 4242 4242 "), "4242")
        XCTAssertEqual(VaultSearchMatcher.lastFourDigits(of: "4111-1111-1111-42-42"), "4242")
        XCTAssertNil(VaultSearchMatcher.lastFourDigits(of: "12-3"))
    }
}
