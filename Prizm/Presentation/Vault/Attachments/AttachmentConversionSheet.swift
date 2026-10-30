import SwiftUI

// MARK: - AttachmentConversionSheet

/// The "Convert all" sheet shown after a sync when attachments need converting
/// (openspec change fix-attachment-file-format, D5): the notice with "Convert all" and "Later",
/// then the progress (`n of N`) with Cancel, then the result with the failures and Done.
///
/// All state flows from `AttachmentConversionViewModel`.
struct AttachmentConversionSheet: View {

    let viewModel: AttachmentConversionViewModel

    static let conversionExplanation = "Converting uploads each file again in the standard format and removes the old copy."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Convert Attachments")
                .font(Typography.pageTitle)
                .padding(.top, Spacing.pageTop)
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.bottom, Spacing.pageHeaderBottom)

            Divider()

            content
                .padding(.horizontal, Spacing.pageMargin)
                .padding(.vertical, Spacing.cardTop)
        }
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Attachment.conversionSheet)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .notice, nil:
            VStack(alignment: .leading, spacing: Spacing.cardTop) {
                // One element, so VoiceOver can move back to the message from the buttons; it is
                // also announced when the sheet opens, because focus starts on a button
                // (VoiceOver check 2026-10-30).
                VStack(alignment: .leading, spacing: Spacing.cardTop) {
                    Text(viewModel.noticeText)
                        .font(Typography.fieldValue)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.conversionExplanation)
                        .font(Typography.fieldLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .onAppear {
                    AccessibilityNotification.Announcement(viewModel.noticeText + " " + Self.conversionExplanation).post()
                }
                HStack {
                    Spacer()
                    Button("Later") { viewModel.later() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Keeps the files as they are. Prizm asks again after you next unlock.")
                        .accessibilityIdentifier(AccessibilityID.Attachment.conversionLater)
                    Button("Convert All") { Task { await viewModel.convertAll() } }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Converts the files one at a time. You can cancel between files.")
                        .accessibilityIdentifier(AccessibilityID.Attachment.convertAllButton)
                }
            }
        case .converting(let done, let total):
            VStack(alignment: .leading, spacing: Spacing.cardTop) {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Converting \(done + 1) of \(total)")
                        .font(Typography.fieldValue)
                }
                .accessibilityValue("\(done + 1) of \(total)")
                .accessibilityIdentifier(AccessibilityID.Attachment.conversionProgress)
                HStack {
                    Spacer()
                    Button("Cancel") { viewModel.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Stops after the current file.")
                        .accessibilityIdentifier(AccessibilityID.Attachment.conversionCancel)
                }
            }
        case .finished(let converted, let failures):
            VStack(alignment: .leading, spacing: Spacing.cardTop) {
                Text(converted == 1 ? "1 attachment converted." : "\(converted) attachments converted.")
                    .font(Typography.fieldValue)
                if !failures.isEmpty {
                    Text("Not converted:")
                        .font(Typography.fieldLabel)
                        .foregroundStyle(.secondary)
                    ForEach(failures, id: \.self) { failure in
                        Text(failure)
                            .font(Typography.fieldLabel)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Done") { viewModel.done() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier(AccessibilityID.Attachment.conversionDone)
                }
            }
        }
    }
}
