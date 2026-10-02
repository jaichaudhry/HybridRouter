# HybridRouter

An open-source iOS app, built around a reusable Swift package (`RouterKit`), that sends each turn of a conversation to the right model:

| Route | Model | Used for |
|---|---|---|
| On-device | Apple `SystemLanguageModel` | Simple, private, or offline turns |
| Apple Cloud | Apple Private Cloud Compute | Larger context, moderate reasoning |
| Claude | Anthropic Claude via `ClaudeForFoundationModels` | Complex reasoning, analysis, code |

All three share one conversation, so a chat can move from on-device to Apple Cloud to Claude and back without losing history. Every reply shows where it ran, why it went there, and what it cost.

> **Status:** early development. Manual routing works. Automatic routing and the two scenarios (Trip Planner, Document Helper) are next.

## Requirements

- Xcode 27, iOS/iPadOS 27
- A device with Apple Intelligence for the on-device model. The Simulator works for the UI and for Claude with an API key.

## Run it

```sh
git clone https://github.com/jaichaudhry/HybridRouter.git
open HybridRouter/HybridRouter.xcodeproj
```

Pick an iOS 27 simulator and run. That's all the setup on-device needs. To run on your own iPhone, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `DEVELOPMENT_TEAM` and `HR_BUNDLE_ID`.

## Adding Claude in 30 seconds

Either:

- **In the app:** open Settings and paste an Anthropic API key. It's stored in the device's Keychain.
- **For development:** set `ANTHROPIC_API_KEY` in `Config/Secrets.xcconfig` or in the scheme's environment variables. Debug builds only; Release builds ignore it.

For builds you give to other people, use App Attest instead of a key: set `CLAUDE_CLIENT_ID` to a client ID from the Claude Console (Settings › App integrations). See Anthropic's [Apple Foundation Models guide](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models).

## Enabling Apple Cloud

Apple Cloud uses Apple's Private Cloud Compute. Apple grants its entitlement to developers in the App Store Small Business Program; see [Accessing Private Cloud Compute](https://developer.apple.com/private-cloud-compute/). Once your team has it, add to `Config/Secrets.xcconfig`:

```
HR_APPLE_CLOUD_ENABLED = YES
CODE_SIGN_ENTITLEMENTS = Config/AppleCloud.entitlements
```

Without it, the app runs normally and shows Apple Cloud as unavailable. There's no API cost: each user's requests count against their own daily Apple Cloud allowance.

## Layout

```
Packages/RouterKit   Providers, routed session, Claude auth, telemetry. No UI. Tested with swift test.
Packages/ChatUI      Streaming chat, route badge, metrics sheet, composer.
App/                 The iOS app and Settings.
Config/              Build settings; Secrets.xcconfig is yours and gitignored.
```

Run the tests on a Mac with Xcode 27:

```sh
swift test --package-path Packages/RouterKit
swift test --package-path Packages/ChatUI
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing `project.yml`, run `xcodegen generate`.

## Contributing

Install the gitleaks pre-commit hook after cloning:

```sh
brew install gitleaks
git config core.hooksPath .githooks
```

## License

[Apache-2.0](LICENSE)
