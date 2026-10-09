import FoundationModels

/// Fields read from a receipt (SPEC §10.2).
@Generable(description: "Details read from a receipt")
struct Receipt {
    @Guide(description: "Store or business name")
    var merchant: String

    @Guide(description: "Purchase date as printed, e.g. 2026-10-09")
    var date: String

    @Guide(description: "Total paid including tax, with currency, e.g. $42.17")
    var total: String

    @Guide(description: "Line items in the order printed")
    var items: [LineItem]

    @Generable
    struct LineItem {
        var name: String
        @Guide(description: "Price with currency")
        var price: String
    }
}

/// A structured summary of a longer document (SPEC §10.2).
@Generable(description: "A summary of a document")
struct DocSummary {
    @Guide(description: "The main points, one short sentence each")
    var keyPoints: [String]

    @Guide(description: "Risks, obligations or red flags; empty if none")
    var risks: [String]

    @Guide(description: "Concrete next steps for the reader; empty if none")
    var actionItems: [String]
}
