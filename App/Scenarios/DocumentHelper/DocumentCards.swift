import ChatUI
import FoundationModels
import HybridRouterKit
import SwiftUI

/// A receipt as it streams in.
struct ReceiptCard: View {
    let receipt: Receipt.PartiallyGenerated

    @Environment(\.replyRoute) private var route

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(receipt.merchant ?? "Receipt")
                    .font(.headline)
                    .foregroundStyle(route?.ink ?? .primary)
                Spacer()
                Text(receipt.total ?? "")
                    .font(.headline)
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let date = receipt.date {
                Text(date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array((receipt.items ?? []).enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.name ?? "")
                    Spacer()
                    Text(item.price ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Key points, risks and action items as they stream in.
struct DocSummaryCard: View {
    let summary: DocSummary.PartiallyGenerated

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummarySection(title: "Key points", systemImage: "list.bullet", items: summary.keyPoints)
            SummarySection(title: "Risks", systemImage: "exclamationmark.triangle", items: summary.risks)
            SummarySection(title: "Action items", systemImage: "checklist", items: summary.actionItems)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SummarySection: View {
    let title: String
    let systemImage: String
    let items: [String]?

    var body: some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.subheadline)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 20, style: .continuous))
        }
    }
}
