import SwiftUI

// MARK: - LoginDetailView

/// Detail view for Login items (FR-025, FR-029).
///
/// Fields are grouped into labelled card sections to reduce cognitive load
/// when scanning items with multiple URIs, notes, and custom fields.
/// Sections are hidden entirely when their content is nil/empty.
struct LoginDetailView: View {

    let item:  VaultItem
    let login: LoginContent
    let onCopy: (String) -> Void
    /// Creates the tracker for the Verification Code card; nil hides the card (e.g. previews).
    var makeCodesViewModel: (() -> TOTPCodesViewModel)? = nil

    // A Credentials card is only meaningful when at least one credential field is present.
    private var hasCredentials: Bool {
        login.username != nil || login.password != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

                if hasCredentials {
                    DetailSectionCard("Credentials") {
                        if let username = login.username {
                            FieldRowView(
                                label:  "Username",
                                value:  username,
                                itemId: item.id,
                                onCopy: onCopy
                            )
                        }
                        if login.username != nil && login.password != nil {
                            Divider()
                        }
                        if let password = login.password {
                            FieldRowView(
                                label:    "Password",
                                value:    password,
                                itemId:   item.id,
                                isMasked: true,
                                onCopy:   onCopy
                            )
                        }
                    }
                }

                if item.hasTOTPSeed, let makeCodesViewModel {
                    VerificationCodeCard(item: item, makeViewModel: makeCodesViewModel, onCopy: onCopy)
                }

                // A website without an address has nothing to open or copy, so it is not listed.
                let websites = login.addressedURIs
                if Self.showsWebsitesCard(addressedCount: websites.count, hiddenCount: login.hiddenURICount) {
                    DetailSectionCard("Websites") {
                        ForEach(websites.indices, id: \.self) { index in
                            let uri = websites[index]
                            if index > 0 { Divider() }
                            FieldRowView(
                                label:  "Website",
                                value:  uri.uri,
                                itemId: item.id,
                                // Only allow-listed schemes, as in the official apps (safe-uri-launch).
                                url:    URILaunchTarget.url(for: uri),
                                onCopy: onCopy
                            )
                        }
                        if login.hiddenURICount > 0 {
                            if !websites.isEmpty { Divider() }
                            hiddenWebsitesRow
                        }
                    }
                }

                if let notes = login.notes, !notes.isEmpty {
                    DetailSectionCard("Notes") {
                        FieldRowView(label: "", value: notes, itemId: item.id, isMultiLine: true, onCopy: onCopy)
                    }
                }

                if !login.customFields.isEmpty {
                    DetailSectionCard("Custom Fields") {
                        CustomFieldsSection(
                            fields: login.customFields,
                            itemId: item.id,
                            onCopy: onCopy
                        )
                    }
                }
            }
    }

    // MARK: - Websites hidden by the integrity check (uri-checksum-validation, D4)

    /// The notice for `count` websites the read path removed.
    /// The Websites card is shown while it has a website or the notice: an item whose websites
    /// were all hidden still tells the user they existed (uri-checksum-validation, D4).
    static func showsWebsitesCard(addressedCount: Int, hiddenCount: Int) -> Bool {
        addressedCount > 0 || hiddenCount > 0
    }

    static func hiddenWebsitesNotice(count: Int) -> String {
        count == 1
            ? "1 website hidden because it failed an integrity check"
            : "\(count) websites hidden because they failed an integrity check"
    }

    /// Where the hidden websites came from and what happens to them, for the tooltip and VoiceOver.
    static func hiddenWebsitesHint(count: Int) -> String {
        count == 1
            ? "The server or another app changed this entry. Prizm doesn't use it, and the next save of this item removes it."
            : "The server or another app changed these entries. Prizm doesn't use them, and the next save of this item removes them."
    }

    // Never shows the hidden addresses: they may be an attacker's.
    private var hiddenWebsitesRow: some View {
        Label(Self.hiddenWebsitesNotice(count: login.hiddenURICount), systemImage: "exclamationmark.shield")
            .font(Typography.utility)
            .foregroundStyle(.secondary)
            .padding(.vertical, Spacing.rowVertical)
            .padding(.horizontal, Spacing.rowHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Self.hiddenWebsitesHint(count: login.hiddenURICount))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.hiddenWebsitesNotice(count: login.hiddenURICount))
            .accessibilityHint(Self.hiddenWebsitesHint(count: login.hiddenURICount))
            .accessibilityIdentifier(AccessibilityID.Detail.hiddenWebsitesNotice)
    }
}
