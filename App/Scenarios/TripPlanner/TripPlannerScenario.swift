import FoundationModels
import HybridRouterKit
import SwiftUI

/// Brainstorm on-device, build itineraries on Apple Cloud, weigh hard trade-offs on Claude.
struct TripPlannerScenario: Scenario {
    let id = "trip-planner"
    let title = "Trip Planner"
    let symbolName = "airplane"
    let instructions = """
        You are a friendly travel planner. Keep answers practical and concise.
        When building an itinerary, call findPlaces once for the destination, then write the itinerary using what it returns.
        Consider travelers' ages, pace and travel time between places.
        """
    let samplePrompts = [
        "Give me 5 weekend trip ideas from Seattle",
        "Make a 3-day Kyoto itinerary for a family with two kids",
        "Is this plan realistic with jet lag and a 4-year-old? What would you cut?",
        "Rewrite day 2 as a short text to my partner",
        "Plan a 2-day Seattle weekend with a museum and a ferry ride",
        "Should we base ourselves in Kyoto or Osaka with kids? Weigh the trade-offs",
        "Make a packing list for the kids",
    ]

    var tools: [any Tool] { [PlacesTool()] }

    var structuredOutputs: [StructuredOutput] {
        [StructuredOutput(schema: Itinerary.generationSchema, tasks: ["plan"], matchesPrompt: Self.asksForItinerary)]
    }

    /// Day cards only when the message asks for days or an itinerary. On newer iPhones "Give me
    /// 5 weekend trip ideas" is labeled planning too, and forcing it into an itinerary lost
    /// the list of ideas.
    nonisolated static func asksForItinerary(_ prompt: String) -> Bool {
        prompt.range(of: #"\b(itinerary|day-by-day|schedule|\d+[- ]?days?|weekend|day trip)\b"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
            && prompt.range(of: #"\bideas?\b"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    func card(for content: GeneratedContent) -> AnyView {
        if let cards = ItineraryCards(content) {
            AnyView(cards)
        } else {
            AnyView(Text(content.jsonString).font(.caption.monospaced()))
        }
    }
}
