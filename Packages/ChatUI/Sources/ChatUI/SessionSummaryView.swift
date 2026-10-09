import RouterKit
import SwiftUI

/// Route mix and cost for the conversation so far (SPEC §9).
public struct SessionSummaryView: View {
    let summary: SessionSummary

    public init(summary: SessionSummary) {
        self.summary = summary
    }

    public var body: some View {
        List {
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
                LabeledContent("If all on Claude", value: Format.cost(summary.allClaudeCost))
                LabeledContent("Saved", value: Format.cost(summary.saved))
            } header: {
                Text("Cost")
            } footer: {
                Text("Estimates from each model's reported tokens and the bundled price table.")
            }
        }
        .navigationTitle("Session")
    }
}
