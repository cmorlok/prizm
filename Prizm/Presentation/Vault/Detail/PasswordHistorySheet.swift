import AppKit
import SwiftUI

/// The item's password history (openspec change `password-history`, design D3): masked rows,
/// newest first, each revealable with the eye toggle or by holding Option, and copyable with the
/// same clipboard clearing as every other field (`onCopy`).
struct PasswordHistorySheet: View {

    @ObservedObject var viewModel: PasswordHistoryViewModel
    let onCopy: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Password History")
                .font(Typography.sectionHeader)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.top, Spacing.pageMargin)
                .padding(.bottom, Spacing.headerGap)

            content
                .padding(.horizontal, Spacing.pageMargin)

            HStack {
                Spacer()
                // Closes the sheet directly too: `onChange(of: isDismissed)` would not fire for a
                // view model that was already dismissed.
                Button("Close") {
                    viewModel.dismiss()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.History.close)
            }
            .padding(Spacing.pageMargin)
        }
        .frame(minWidth: Spacing.historySheetWidth)
        .accessibilityIdentifier(AccessibilityID.History.sheet)
        .task { await viewModel.load() }
        // However the sheet goes away (Close, Esc, another item, a lock), the entries go with it.
        .onDisappear { viewModel.dismiss() }
        .onChange(of: viewModel.isDismissed) { _, dismissed in
            if dismissed { dismiss() }
        }
        .onChange(of: viewModel.loadState) { _, state in
            if case .failed(let message) = state { announce(message) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.cardBottom)
        case .failed(let message):
            Text(message)
                .font(Typography.bannerText)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.cardBottom)
        case .loaded:
            // The server decides how many entries there are, so a long history scrolls inside the
            // sheet, at a fixed height, instead of growing it past the screen (security review
            // 2026-10-31). A short one keeps its natural height: a sheet has no height of its own
            // to measure a scroll view against.
            if PasswordHistoryViewModel.scrolls(rowCount: viewModel.rows.count) {
                ScrollView { historyCard }
                    .frame(height: Spacing.historyListMaxHeight)
            } else {
                historyCard
            }
        }
    }

    private var historyCard: some View {
        DetailSectionCard {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.rows) { row in
                    if row.id > 0 { Divider() }
                    historyRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ row: PasswordHistoryViewModel.Row) -> some View {
        if row.value != nil {
            FieldRowView(label: row.dateText, value: row.value, itemId: "history-\(row.id)",
                         isMasked: true, onCopy: onCopy,
                         labelFont: Typography.fieldLabel,
                         accessibilityName: row.accessibilityLabel,
                         identifierKey: AccessibilityID.History.rowKey(row.id),
                         copiedThing: "value")
        } else {
            HStack {
                Text(row.dateText).font(Typography.fieldLabel)
                Spacer()
                Text("Entry could not be read")
                    .font(Typography.fieldValue)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.rowVertical)
            .padding(.horizontal, Spacing.rowHorizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.accessibilityLabel), could not be read")
            .accessibilityIdentifier(AccessibilityID.History.row(row.id))
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
