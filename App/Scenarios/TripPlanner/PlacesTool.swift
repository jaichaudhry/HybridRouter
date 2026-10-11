import FoundationModels

/// Looks up places in a city from canned sample data. No external APIs in v1.
struct PlacesTool: Tool {
    let name = "findPlaces"
    let description = "Finds notable, family-friendly places in a city. Use it when building an itinerary."

    @Generable
    struct Arguments {
        @Guide(description: "City name, e.g. Kyoto")
        var city: String
    }

    func call(arguments: Arguments) async throws -> String {
        let city = arguments.city.trimmingCharacters(in: .whitespaces).lowercased()
        guard let places = Self.places[city] else {
            return "No sample data for \(arguments.city). Suggest well-known places instead."
        }
        let list = places.map { "- \($0)" }.joined(separator: "\n")
        // Without the last line, the on-device model called this tool in a loop until it ran
        // out of context (macOS 27.0).
        return "Places in \(arguments.city):\n\(list)\nYou now have the places. Don't call findPlaces again; write the answer."
    }

    static let places: [String: [String]] = [
        "kyoto": [
            "Fushimi Inari Shrine: thousands of red gates; go before 8:00 to avoid crowds",
            "Arashiyama Bamboo Grove: short, stroller-friendly path",
            "Kyoto Railway Museum: hands-on trains, great for kids",
            "Nishiki Market: food stalls; busy around noon",
            "Kinkaku-ji (Golden Pavilion): quick visit, about 45 minutes",
            "Kyoto Aquarium: next to the railway museum",
        ],
        "seattle": [
            "Pike Place Market: original Starbucks and fish throwers",
            "Space Needle and Chihuly Garden and Glass",
            "Museum of Pop Culture",
            "Bainbridge Island ferry: 35-minute crossing with skyline views",
            "Discovery Park: beach and lighthouse trail",
        ],
        "tokyo": [
            "teamLab Planets: immersive art, book ahead",
            "Ueno Zoo and park",
            "Asakusa Senso-ji Temple",
            "Ghibli Museum: tickets sell out a month ahead",
        ],
        "portland": [
            "Oregon Museum of Science and Industry",
            "International Rose Test Garden",
            "Powell's City of Books",
        ],
    ]
}
