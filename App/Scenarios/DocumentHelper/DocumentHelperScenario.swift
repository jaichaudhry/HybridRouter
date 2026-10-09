import FoundationModels
import RouterKit
import SwiftUI
import Vision

/// Read receipts and notes privately on-device, summarize long documents, get advice from Claude.
struct DocumentHelperScenario: Scenario {
    let id = "document-helper"
    let title = "Document Helper"
    let symbolName = "doc.text.viewfinder"
    let instructions = """
        You help people understand receipts, notes and documents. Be accurate and concise.
        When an image is attached, call getText with its label to read it, then answer from what it returns.
        Only call readBarcodes when the user asks about a barcode or QR code.
        Never invent amounts, dates or names that aren't in the document.
        """
    /// Chips fill the text field so the user can attach a document first.
    let samplePrompts = [
        "Extract the total and merchant",
        "Explain this in plain English",
        "Summarize the key risks",
        "What should I push back on in negotiation?",
        "List every deadline in this document",
        "What does this barcode say?",
    ]
    let samplePromptsFillDraft = true
    let imagesArePrivate = true

    /// OCRTool and BarcodeReaderTool find images by attachment label, which the Claude bridge
    /// doesn't forward, so they're only offered on Apple routes (API_NOTES §9). The iOS 27
    /// Simulator SDK doesn't ship their overlay, so there the model reads images itself.
    var appleOnlyTools: [any Tool] {
        #if canImport(_Vision_FoundationModels)
        [OCRTool(), BarcodeReaderTool()]
        #else
        []
        #endif
    }

    var structuredOutputs: [StructuredOutput] {
        [
            StructuredOutput(schema: Receipt.generationSchema, tasks: ["extract"], complexities: ["simple", "moderate"]),
            StructuredOutput(schema: DocSummary.generationSchema, tasks: ["summarize"]),
        ]
    }

    func card(for content: GeneratedContent) -> AnyView {
        // The two schemas don't share property names, so the keys tell them apart.
        let json = content.jsonString
        if json.contains("\"merchant\"") || json.contains("\"total\""), let receipt = try? Receipt.PartiallyGenerated(content) {
            return AnyView(ReceiptCard(receipt: receipt))
        }
        if let summary = try? DocSummary.PartiallyGenerated(content) {
            return AnyView(DocSummaryCard(summary: summary))
        }
        return AnyView(Text(json).font(.caption.monospaced()))
    }
}
