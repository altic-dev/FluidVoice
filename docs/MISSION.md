# Voix — Mission

## What this is

Voix is a macOS app for **practicing spoken communication**. You record a speech, a pitch, a
standup update, or a difficult conversation you're rehearsing. Voix transcribes it on-device,
measures how you actually delivered it from the raw audio, and returns coaching that talks about
both what you said and how you said it.

The distinguishing claim is the second half. Transcription is a commodity, and an LLM will happily
critique a transcript. But a transcript cannot tell you that you paced at 178 words per minute, ran
eleven seconds without a single pause, and flattened to a 12 Hz pitch range through your closing
argument. Those numbers come out of the audio, and Voix puts them in front of the coach so the
feedback cites measurements instead of guessing at delivery from word choice.

## Why fork FluidVoice instead of starting fresh

FluidVoice is a mature GPLv3 dictation app that already solved the parts of this problem that are
tedious and easy to get subtly wrong: hardened audio capture with Bluetooth route recovery, seven
local ASR engines behind one interface, a multi-provider LLM layer with key management and routing,
Accelerate/vDSP already in the build, live RMS metering, and a persistence pattern to clone.

Building that from zero would take months and produce something worse. The fork inherits it and
spends its effort on the part that is actually new: acoustic analysis and coaching.

The corollary is a discipline. Voix is a *thin, well-placed addition* to a codebase we did not
write. The v1 plan touches four existing files for a combined ~15 lines and adds four new ones. We
do not refactor the monolith, rename targets, or restyle inherited code. Every line of upstream code
we leave untouched is a line we can still take fixes for.

## What v1 delivers

One loop, end to end:

1. **Record** a practice speech through the inherited capture stack.
2. **Transcribe** locally — no audio leaves the machine.
3. **Measure** delivery from the raw 16 kHz mono PCM buffer: pauses (count, length, placement,
   speaking-to-silence ratio), pace (overall WPM *and* articulation rate excluding pauses), filler
   words per type and per minute, pitch (mean, range, variance as a monotone score, contour), and
   volume dynamics (mean level, dynamic range, variety, energy timeline).
4. **Coach** — an LLM receives the verbatim transcript plus the measured numbers and returns
   structured feedback: core message, what's working, content critique (structure, clarity,
   persuasiveness, unsupported claims), delivery critique against speaking norms citing the actual
   measurements, concrete improvements including one delivery drill, and a revised outline.
5. **Keep** the session so you can see whether the next attempt is better.

The architectural commitment underneath: **all acoustic metrics are computed provider-agnostically
from the PCM buffer `ASRService` already accumulates.** No ASR provider is modified. Switching from
Parakeet to Whisper to Apple Speech changes transcription quality and nothing else about the
analysis.

## Non-goals

Voix is not a dictation app. It is not a meeting recorder. It does not type into other applications,
run shell commands from voice, or live in a global hotkey overlay. That machinery is inherited and
mostly left dormant rather than deleted — deleting it is churn with no functional payoff, and
dormant code merges cleanly with upstream.

Explicitly deferred, with the reason:

| Deferred | Until |
|---|---|
| Word-aligned metrics (rolling WPM, filler timestamps) | v2 — needs Parakeet `tokenTimings` surfaced through `ASRTranscriptionResult` |
| Trend charts across sessions | v2 — per-session metrics ship first, trends need sessions to exist |
| Per-session audio retention and playback | v1.1 — analysis is persisted; the WAV plumbing already exists when we want it |
| ML VAD, YIN pitch refinement | When energy-threshold VAD and autocorrelation F0 measurably fail in a noisy room |
| Editable coaching prompt | After the hardcoded prompt has been iterated against real recordings |
| Renaming `Sources/Fluid`, targets, branding, README | Never, probably — 143 files of churn for zero function |

## Privacy posture

This is a product where people rehearse things they are nervous about saying. That deserves a stated
position, not an inherited default.

Recording and transcription are fully local. The only outbound traffic in v1 is the coaching call to
whichever LLM provider the user configured — and with Ollama configured, there is none at all.
Phase 0 blanks the inherited PostHog analytics key, removes the auto-updater that would otherwise
replace the app with upstream FluidVoice, and removes the feedback button that posts transcripts to
a third-party endpoint. A network audit confirming exactly one possible outbound destination is a
release gate, not a nice-to-have.

## License and upstream obligations

Voix is GPLv3, inherited and non-negotiable. The `LICENSE` file stays. If Voix is distributed in any
form, complete corresponding source must be available under the same terms. Upstream FluidVoice
retains its copyright on everything it wrote; we hold copyright only on what we add.

See [BRANCHING.md](BRANCHING.md) for how upstream changes are pulled in.

## v1 is done when

- `./build.sh unsigned` builds clean.
- Analysis unit tests pass on synthetic PCM: a 440 Hz sine recovers F0 ≈ 440 Hz; two inserted 1 s
  silence gaps produce exactly two pauses at the right timestamps; a constant tone scores near-zero
  pitch variance; a known filler transcript yields correct per-type counts.
- The existing test target still passes — the only change to the monolith is an additive default
  parameter.
- End to end on a real 60-second pitch: transcript, metrics cards, contour chart, and coaching
  feedback all render, and the feedback quotes the measured numbers. Quit and relaunch, the session
  is still there.
- Network audit shows the configured LLM endpoint and nothing else.
