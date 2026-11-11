# Shared text normalization

This folder is the canonical macOS implementation of FluidVoice's quantity and spoken-emoji rules. It belongs to FluidVoice, not FluidAudio. It adds no package, binary, network service, Rust runtime, or third-party dependency. The four Swift files use Foundation and build independently of the app with Swift 6.2 or newer.

## Entry point

```swift
let rules = SpokenEmojiRules(data: catalogData)
let normalizer = FluidTextNormalizer(emoji: rules)
let prepared = normalizer.normalize(transcript, phase: .beforeCleanup, languageCode: "en")
let safe = normalizer.preservingLiteralCommands(in: cleanedText, from: prepared, languageCode: "en")
// Apply the host app's capitalization/spacing preferences here, then:
let final = normalizer.normalize(safe, phase: .afterCleanup, languageCode: "en")
```

`catalogData` comes from `Resources/fluid-text-emoji-en.json`. Resource loading belongs to the host app; the core does not read files, access bundles, inspect settings, or call UI/ASR/AI services. A missing or invalid catalog disables only emoji conversion. Quantity rules remain available.

The macOS adapter is `Sources/Fluid/Services/DictationTextNormalizationService.swift`. It loads the catalog once, on its actor rather than the main thread, and returns an immutable formatter snapshot. Each dictation uses that same snapshot before and after cleanup. Emoji rules are selected from that request’s input even when the catalog is already cached; previous dictations cannot change the rules it receives. The final call runs after smart capitalization, so continued text cannot leave `5b` or `7m` in place of `5B` or `7M`.

Normal dictation, prompt testing, and reprocessing use the component. Recording, first audio capture, partial captions, meeting transcripts, rewrite/command instructions, history copying, and dictionary storage do not call it. No settings or persisted user state are added.

## Contract

- Input/output are Unicode strings. `en`, `en-US`, and other English region tags enable the rules; other language codes pass text through. The host selects the language. The current macOS adapter uses the default English rules for explicit English phrases.
- Inputs over 65,536 UTF-8 bytes or containing NUL pass through unchanged. Numeric phrases are bounded to 16 tokens.
- Quantities include explicit currency amounts, B/M parameter counts, and the full phrase `tokens per second`. Bare `pounds` and `cents` remain ambiguous and stay text.
- Emoji conversion requires an exact catalog name or alias followed by `emoji`. Names are limited to five words, case-insensitive, with spaces/tabs/hyphens between words. Existing emoji and unknown names remain untouched. Matches must be standalone words; attached identifiers, paths, and tags stay text. Sentence punctuation remains supported.
- Recognized catalog names longer than five words are explicitly excluded, preventing a shorter suffix from producing the wrong emoji. They are not converted.
- `literal fire emoji` remains explicit before cleanup and becomes the words `fire emoji` after cleanup. If cleanup drops that explicit escape, `preservingLiteralCommands` falls back to the prepared transcription before host formatting. Finalization consumes that escape once; do not run finalization on already delivered text. Ordinary quantity and emoji results are idempotent.
- Code in backticks, URLs, and email addresses are protected. Whitespace and unrelated prose are retained.
- Normalization controls spelling, not AI factual correctness. An AI that changes a value, removes an emoji, cannot be corrected reliably by these rules alone. Explicit literal escapes have the narrow fallback described above.

The JSON schema is versioned independently of behavior. `schemaVersion: 1`, `language: "en"`, and `maximumNameWords: 5` are required. `names` maps canonical phrases and explicit aliases to one emoji grapheme. `unsupportedNames` lists known names excluded by the word limit. Keep aliases explicit so every implementation resolves ambiguity the same way.

The initial names were derived from FV-iOS's `FluidVoice/FluidVoiceKeyboard/Resources/Emoji/emoji-catalog.json`; aliases were taken from its `SpokenEmojiIndex.swift`, with explicit common-name mappings added here. Future edits to this component's catalog belong here; the module does not read another repository at build time or runtime.

## Verify and copy

From the repository root:

```sh
sh Tests/TextNormalization/run.sh
sh Tests/TextNormalization/export.sh /tmp/fluid-text-normalization-export
```

The export refuses to overwrite an existing directory. It includes just the core, catalog, test fixtures, standalone test runner, this guide, and a SHA-256 manifest. It contains no app adapter, model files, or package dependencies. Run `sh Tests/TextNormalization/run.sh` inside the exported directory to verify that it works independently of the checkout.

`Tests/TextNormalization/fixtures.json` is the language-independent behavior contract. Add input/output examples there whenever a rule changes. The runner also verifies every catalog name, malformed resources, cleanup boundaries, input limits, and concurrent calls.

## Other apps

**iOS:** copy this folder and the fixtures from one export, add its Swift files to the app target, and bundle the JSON. Use an iOS resource-loading adapter and call the same API at the cleanup boundaries. FV-iOS already has additional normalization in `FVTextNormalization`, including a native NeMo dependency and broader punctuation rules. Reconcile overlapping rules before replacing anything; installing this folder does not migrate or remove that existing package. No phone changes are part of this work.

**Android, Windows, or another language:** the JSON catalog and fixtures transfer directly. The Swift algorithms do not become callable from Kotlin/C#/JavaScript by copying the folder. A native implementation must pass the same fixtures and catalog checks. If maintaining multiple implementations becomes necessary, move this small core behind a shared compiled interface then; no such bridge or dependency is introduced now. Non-Apple runtime compatibility has not been tested.

Keep FluidVoice as the source of truth for this component for now. Import each update as a whole, keep its manifest, and run the shared tests in the consuming app. Do not edit copied rules independently. A separate repository or package can be introduced later if independent releases become useful.
