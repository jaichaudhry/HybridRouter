# Setup

## Run it

```sh
git clone https://github.com/jaichaudhry/HybridRouter.git
open HybridRouter/HybridRouter.xcodeproj
```

Pick an iOS 27 simulator or device and run: no keys or accounts needed for the on-device model. Document Helper's OCR tools need a device; Apple doesn't include them in the Simulator. To run on your own iPhone, copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `DEVELOPMENT_TEAM` and `HR_BUNDLE_ID`.

## Adding Claude in 30 seconds

Either:

- **In the app:** open Settings and paste an Anthropic API key. It's stored in the device's Keychain.
- **For development:** set `ANTHROPIC_API_KEY` in `Config/Secrets.xcconfig`, which is gitignored. Debug builds only; Release builds ignore it. Don't put keys in the scheme's environment variables: the scheme is shared and committed.

## Using Muse Wonder instead

Create a key at [dev.meta.ai](https://dev.meta.ai/api-keys) (Standard mode, so your prompts aren't used for training). Then either paste it in Settings › Muse Wonder, or set `META_API_KEY` in `Config/Secrets.xcconfig` for Debug builds, and pick **Muse Wonder** under Settings › Cloud model. Replies are labelled with the model that wrote them, so a conversation can switch back and forth. Expect slower replies than Claude: Muse reasons before answering and its reply arrives all at once, a median 9.3 s to the first word against 2.2 s for Sonnet (see [Quality vs cost](results.md#quality-vs-cost)). Meta has no App Attest equivalent, so for other people's devices each user brings their own key.

## Shipping with App Attest

For builds that run on other people's devices, don't embed a key. App Attest lets each install prove it's your genuine app and get short-lived Claude tokens:

1. In the [Claude Console](https://platform.claude.com/settings/workspaces/default/app-integrations), open your workspace's **App integrations** and create one with your Apple Team ID and bundle ID. You need the admin or owner role. Copy the client ID (`clid_…`).
2. Register an explicit App ID for your bundle ID with the App Attest capability.
3. In `Config/Secrets.xcconfig`, set `CLAUDE_CLIENT_ID` and `CODE_SIGN_ENTITLEMENTS = Config/AppAttest.entitlements` (or `Config/AppAttestAppleCloud.entitlements` if you also enabled Apple Cloud).
4. Set a spend limit for the workspace in the Claude Console, since every install's usage is billed to you.

App Attest only works on physical devices. In the Simulator, or if attestation fails, the app falls back to a key from Settings or `Secrets.xcconfig`. See Anthropic's [Apple Foundation Models guide](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models).

## Enabling Apple Cloud

Apple Cloud uses Apple's Private Cloud Compute. Apple grants its entitlement to developers in the App Store Small Business Program; see [Accessing Private Cloud Compute](https://developer.apple.com/private-cloud-compute/). Once your team has it, add to `Config/Secrets.xcconfig`:

```
HR_APPLE_CLOUD_ENABLED = YES
CODE_SIGN_ENTITLEMENTS = Config/AppleCloud.entitlements
```

(Use `Config/AppAttestAppleCloud.entitlements` instead if you also use App Attest.)

Without it, the app runs normally and shows Apple Cloud as unavailable. There's no API cost: each user's requests count against their own daily Apple Cloud allowance.

While you wait for the entitlement, Debug builds have **Settings › Developer › Simulate Apple Cloud**, which serves the Apple Cloud route with the on-device model so you can try the three-route flow. Those replies are labeled "Apple Cloud (simulated)" and say nothing about Apple Cloud's real speed or quality. The option doesn't exist in Release builds.

## Project layout and tests

```
Packages/HybridRouterKit   Router, privacy, providers, routed session, Claude auth, telemetry. No UI.
Packages/ChatUI      Streaming chat, route badge, metrics, composer, compare mode.
App/                 The iOS app: scenarios, Settings, on-device benchmarks and checks.
Evals/               Routing cases, the classifier benchmark, the answer-quality benchmark and its results, the Apple evaluation.
Config/              Build settings; Secrets.xcconfig is yours and gitignored.
```

Run the tests on a Mac with Xcode 27:

```sh
swift test --package-path Packages/HybridRouterKit
swift test --package-path Packages/ChatUI
swift test --package-path Evals
```

The router, privacy rules and shared session are tested with fake `LanguageModel`s running through Apple's real `LanguageModelSession`, so no device or network is needed. The evals run the real on-device classifier wherever Apple Intelligence is available and are skipped elsewhere, including CI.

The answer-quality benchmark calls Claude, so it only runs when asked. On an iPhone, use **Settings › Developer › Answer quality**; on a Mac, with a key in `Config/Secrets.xcconfig` (about $9 for the full set, capped at $15):

```sh
HR_RUN_QUALITY_EVAL=1 swift test --package-path Evals --filter answerQuality
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing `project.yml`, run `xcodegen generate`.

## Contributing

Install the gitleaks pre-commit hook after cloning:

```sh
brew install gitleaks
git config core.hooksPath .githooks
```

---

[← Back to the README](../README.md) · [How it works](how-it-works.md) · [Results](results.md) · [HybridRouterKit](hybridrouterkit.md) · [Setup](setup.md) · [Engineering notes](engineering-notes.md)
