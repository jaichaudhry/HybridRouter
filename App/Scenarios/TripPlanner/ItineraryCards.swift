import FoundationModels
import SwiftUI

/// Itinerary cards that render whatever has streamed in so far.
struct ItineraryCards: View {
    let itinerary: Itinerary.PartiallyGenerated

    init?(_ content: GeneratedContent) {
        guard let itinerary = try? Itinerary.PartiallyGenerated(content) else { return nil }
        self.itinerary = itinerary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = itinerary.title {
                Text(title)
                    .font(.headline)
            }
            ForEach(Array((itinerary.days ?? []).enumerated()), id: \.offset) { index, day in
                DayCard(number: index + 1, day: day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DayCard: View {
    let number: Int
    let day: Itinerary.Day.PartiallyGenerated

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day \(number)\(day.title.map { ": \($0)" } ?? "")")
                .font(.subheadline.weight(.semibold))
            ForEach(Array((day.items ?? []).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.time ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.place ?? "")
                            .font(.body)
                        if let note = item.note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}
