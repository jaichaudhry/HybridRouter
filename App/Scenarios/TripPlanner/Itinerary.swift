import FoundationModels

/// A day-by-day trip plan, rendered as cards that fill in while it streams.
@Generable(description: "A day-by-day trip itinerary")
struct Itinerary {
    @Guide(description: "Short title, e.g. 3 days in Kyoto with kids")
    var title: String

    @Guide(description: "One entry per day, in order")
    var days: [Day]

    @Generable
    struct Day {
        @Guide(description: "Theme of the day, e.g. Temples and gardens")
        var title: String

        @Guide(description: "Activities in time order")
        var items: [Item]
    }

    @Generable
    struct Item {
        @Guide(description: "Start time, e.g. 9:00")
        var time: String

        @Guide(description: "Where, e.g. Fushimi Inari Shrine")
        var place: String

        @Guide(description: "One short tip or detail")
        var note: String
    }
}
