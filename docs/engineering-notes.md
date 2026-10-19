# Engineering notes

Things found by testing on real hardware, and what the app does about them:

- **Prompts don't transfer between on-device model variants.** The routing instructions tuned on a Mac's AFM 3 Core (4K context) scored 48/50; on an iPhone 17 Pro Max's AFM 3 Core Advanced (8K) they scored 42/50, every miss one level too high. The classifier now picks instructions per variant (46/50 on the iPhone).
- **The on-device model can loop on tool calls.** Given a tool and an output schema, it called `findPlaces` over and over until the context overflowed. Asking it to call the tool once, and saying so in the tool's output, fixed it.
- **An overflow mid-generation doesn't throw the documented error.** It throws a non-public `GenerativeError`, not `LanguageModelError.contextSizeExceeded`, so escalation also matches it by message.
- **Claude refusals and length cut-offs don't throw** through the bridge; the reply just comes back empty or short. The router treats an empty reply as a failure and flags cut-off replies.
- **The iOS Simulator has no `OCRTool` or `BarcodeReaderTool`.** Its SDK doesn't include their overlay, so Document Helper's image tools are compiled in for devices only.
- **Context can mislead the classifier.** Showing it the previous message for every short turn made "Make a packing list for the kids" inherit "complex" from a trade-offs question before it. Context is now added only when a message refers back ("do the same for Osaka").
- **Speech-to-text writes letters and symbols its own way.** Spoken "r's" came out as "hours", and "17 times 24" as "17×24", which changed what the exact-answer rule saw. It now matches "how many … in the word …" and number words like "times", so typed and spoken prompts route the same.
- **iOS 27 deprecates `AVAudioNode.installTap`.** Its replacement, `installAudioTap`, hands the tap a read-only `AVReadOnlyAudioPCMBuffer`; `AVAudioFile` writes it directly, and the speech converter gets a copy.
- **A microphone tap written inside a `@MainActor` type crashes.** Swift 6 makes the closure main-actor isolated, and the tap runs on the audio thread, so the tap lives in its own nonisolated class.
- **Voice is a separate library** because App Store review flags apps whose binaries reference microphone or speech APIs without a purpose string, even when the code is never used.
- **Generating a reason is expensive.** A free-text reason added about 600 ms per classification on an M1 Max, so the badge's reason is derived from the labels instead.

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
