import Testing
@testable import HybridRouterKit

struct TranscriptScoreTests {
    @Test func identicalTextIsPerfectWhateverTheCaseAndPunctuation() {
        let score = TranscriptScore(reference: "How many r's are in strawberry?", transcript: "how many R's are in strawberry")
        #expect(score.wordErrors == 0)
        #expect(score.referenceWords == 6)
        #expect(score.wordErrorRate == 0)
    }

    @Test func substitutionsInsertionsAndDropsEachCountOnce() {
        // "ours" for "r's" (1), "the" dropped (1), "um" inserted (1).
        let score = TranscriptScore(reference: "How many r's are in the word strawberry", transcript: "um how many ours are in word strawberry")
        #expect(score.wordErrors == 3)
        #expect(score.referenceWords == 8)
        #expect(score.wordErrorRate == 3.0 / 8)
    }

    @Test func numbersUnitsAndDecimalsStayMeaningful() {
        #expect(TranscriptScore.words("Convert 72°F to Celsius.") == ["convert", "72", "degrees", "fahrenheit", "to", "celsius"])
        #expect(TranscriptScore.words("Add 2.5 and 15%") == ["add", "2.5", "and", "15", "percent"])
        #expect(TranscriptScore(reference: "Convert 72°F", transcript: "Convert 27°F").wordErrors == 1)
    }

    /// The formatting differences from the first iPhone speech check, which aren't mistakes.
    @Test(arguments: [
        ("What is 17 times 24?", "What is 17×24?"),
        ("Convert 72 degrees Fahrenheit to Celsius.", "Convert 72°F to Celsius"),
        ("If I save 250 dollars a month", "If I save $250 a month"),
        ("Summarize the pros and cons", "Summarise the pros and cons"),
        ("Give me three ideas", "Give me 3 ideas"),
        ("What's 18 percent of 350?", "What's 18% of 350?"),
        ("My favorite color", "My favourite colour"),
        ("Meet at the theater center", "Meet at the theatre centre"),
        ("It costs 1200 dollars", "It costs $1,200"),
    ])
    func formattingIsNotAMistake(typed: String, heard: String) {
        #expect(TranscriptScore(reference: typed, transcript: heard).wordErrors == 0)
    }

    @Test func realMistakesStillCount() {
        #expect(TranscriptScore(reference: "How many r's are in the word strawberry?", transcript: "How many hours are in the word strawberry?").wordErrors == 1)
        #expect(TranscriptScore(reference: "Email jai@example.com", transcript: "Email j@example.com").wordErrors == 1)
        #expect(TranscriptScore(reference: "What is 17 times 24?", transcript: "What is 17×42?").wordErrors == 1)
        // A phone number's dashes aren't minus signs.
        #expect(TranscriptScore.words("415-555-0132") == ["415", "555", "0132"])
    }

    @Test func curlyApostrophesMatchStraightOnes() {
        #expect(TranscriptScore(reference: "What's next?", transcript: "What’s next").wordErrors == 0)
    }

    @Test func emptyInputs() {
        #expect(TranscriptScore(reference: "", transcript: "").wordErrorRate == 0)
        #expect(TranscriptScore(reference: "hello there", transcript: "").wordErrors == 2)
        #expect(TranscriptScore(reference: "", transcript: "noise").wordErrors == 1)
    }
}
