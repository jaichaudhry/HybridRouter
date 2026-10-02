# HybridRouter

An open-source iOS app, built around a reusable Swift package (`RouterKit`), that sends each turn of a conversation to the right model:

| Route | Model | Used for |
|---|---|---|
| On-device | Apple `SystemLanguageModel` | Simple, private, or offline turns |
| Apple Cloud | Apple Private Cloud Compute | Larger context, moderate reasoning |
| Claude | Anthropic Claude via `ClaudeForFoundationModels` | Complex reasoning, analysis, code |

Every reply shows where it ran, why it went there, and what it cost.

> **Status:** early development. Not ready to use yet.

## Requirements

- Xcode 27, iOS/iPadOS 27
- A device with Apple Intelligence for the on-device model and App Attest. The Simulator works for UI and for Claude with an API key.

## Contributing

Install the gitleaks pre-commit hook after cloning:

```sh
brew install gitleaks
git config core.hooksPath .githooks
```

## License

[Apache-2.0](LICENSE)
