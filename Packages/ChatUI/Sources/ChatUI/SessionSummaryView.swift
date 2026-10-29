import Charts
import HybridRouterKit
import SwiftUI

/// Route mix and cost for the conversation so far.
public struct SessionSummaryView: View {
    let summary: SessionSummary

    public init(summary: SessionSummary) {
        self.summary = summary
    }

    public var body: some View {
        List {
            Section {
                SummaryHero(summary: summary)
                    .listRowBackground(RouterAurora(weights: summary.routeShare))
            }
            Section("Route mix") {
                ForEach(Route.allCases, id: \.self) { route in
                    LabeledContent {
                        Text((summary.routeShare[route] ?? 0).formatted(.percent.precision(.fractionLength(0))))
                    } label: {
                        RouteLabel(route)
                    }
                }
            }
            Section {
                LabeledContent("Steps", value: "\(summary.stepCount)")
                LabeledContent("Total cost", value: Format.cost(summary.totalCost))
                LabeledContent("If all on the cloud model", value: Format.cost(summary.allCloudCost))
                LabeledContent("Saved", value: Format.cost(summary.saved))
            } header: {
                Text("Cost")
            } footer: {
                if summary.unpricedSteps > 0 {
                    Text("Estimates from each model's reported tokens and the bundled price table. \(summary.unpricedSteps) cloud steps have no listed price and aren't counted.")
                } else {
                    Text("Estimates from each model's reported tokens and the bundled price table.")
                }
            }
        }
        .navigationTitle("Session")
    }
}

/// "$0.42 saved vs. all-Claude" (named for the cloud model), how many steps stayed with Apple,
/// and a route-mix donut.
private struct SummaryHero: View {
    let summary: SessionSummary
    @Environment(\.routeLabels) private var labels

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.saved > 0 ? Format.cost(summary.saved) : "$0")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                Text("saved vs. all-\(labels.cloudName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(appleSteps) of \(summary.stepCount) steps stayed with Apple")
                    .font(.subheadline)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Chart(Route.allCases, id: \.self) { route in
                SectorMark(
                    angle: .value("Share", summary.routeShare[route] ?? 0),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .cornerRadius(3)
                .foregroundStyle(route.fill)
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var appleSteps: Int {
        let share = (summary.routeShare[.onDevice] ?? 0) + (summary.routeShare[.appleCloud] ?? 0)
        return Int((share * Double(summary.stepCount)).rounded())
    }
}
