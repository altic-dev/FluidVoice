# Pill microphone meter

Fresh upstream base: `a078787680a9554e4189464010faaf9f92f3287a` (`main`).

The live Pill observes the existing accepted 16 kHz mono PCM. It does not change
capture, resampling, recognition, or the scalar publisher used by other views.
The upstream `AudioSpectrumMeter` continues serving other styles; the Pill uses
one dedicated serial analyzer, rather than running both for the same Pill audio.
Native-rate monitoring now passes its real sample rate to the upstream meter.

## Ownership and latency

`AudioCapturePipeline` serializes the producer, attempt changes, and PCM acceptance
with its existing lock. Offering PCM adds only a bounded copy into a C11 atomic
SPSC queue: eight slots of at most 4096 floats. Full queues drop visualization
packets. Slots are never reused before the consumer releases them. Capture never
allocates FFT state, takes a new lock, publishes UI state, or dispatches per-packet
work for this feature.

A serial worker polls at 8 ms while a recording Pill is visible. It drains at most
one ring capacity in FIFO order, appends every fresh packet, then computes one FFT
from the newest complete window. Normal packet batching does not reset history.
Queued work older than 100 ms is rejected. Epoch/sequence/rate/real discontinuity
changes reset analysis history. The
transport lifetime exceeds both producers and consumers. C atomics synchronize
slots and epochs; an independent lock protects the small immutable latest frame
between worker and presentation. `@unchecked Sendable` documents that ownership;
it does not replace either synchronization mechanism.

A Hann-windowed FFT measures eight overlapping log-frequency windows centered at
220/400/700/1200/2000/3200/4300/5500 Hz within 120–6000 Hz. Adjacent triangular
power weights sum to one, so formants cross boundaries continuously without
inventing energy or assigning movement to a fixed bar. The window is approximately 32 ms,
rounded to a power of two at the actual sample rate. Pill-specific frequency weighting reduces voiced fundamentals by 15 dB through
220 Hz, tapering to unity at 1.6 kHz, and adds up to 12 dB of presence above 800 Hz
(9 dB/octave). It is applied to FFT power before pooling, independently of bar count.

Loudness and shape are then separated: a bounded body level follows spectral peak
energy, while each band's relative contrast supplies the shape. Unweighted RMS
must pass an absolute activity gate before this normalization; each band also has
an absolute gate. Quiet hiss cannot be normalized to a full-height pattern, and
unvoiced high-frequency speech can activate the meter without voiced energy.
Max pooling preserves narrow peaks in 3–8 bars. Lower sensitivity-control values
remain more sensitive; the preference and other visualizers are not retuned.

A MainActor timer advances one exponential envelope (25 ms attack, 95 ms release)
at approximately 60 Hz using monotonic time. Body and Canvas evaluation only read
state. Quiet bars reach exact stationary dots; the timer still checks for new
speech without redrawing unchanged silence. The live child and worker stop on
processing/hide. A short visualization gap resets DSP history but releases from
the currently displayed heights instead of flashing to dots. New epochs still
reset all presentation state immediately. Presentation rejects old epochs and frames older than 150 ms.
The original capture host timestamp is retained separately from publication time.
Capture batching, analysis time, and publication-to-presentation time are distinct.

## Geometry and loading

Six live bars occupy 26 pt: 8/3 pt wide, 2 pt gaps, dot resting height, 28 pt maximum
bounded by the existing 30 pt area. The common centerline and shell do not move.
Only horizontal dimensions shrink if a selected count exceeds the 32 pt Spoken
Send slot. Normal live counts are 3–8; the default is six. Optional backup data
preserves older backup decoding and explicit current selections when the field is
absent; unset values default to six. Explicit imported counts are validated.

The existing `CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)`, its white
opacity, shadow, mask, and component are retained directly. Loading still uses
upstream eight 3 pt bars with 2.5 pt gaps and 4 pt height (six for Spoken Send).
Live geometry never changes this mask. A stop latch bridges accepted stop to all
processing phases without waiting for audio or a result. It clears with the
existing hide cleanup or a new show. No artificial processing delay or minimum
loading duration is added. The upstream shimmer implementation and accessibility/
Reduce Motion behavior are unchanged.

## Local verification

Build with `./build.sh unsigned`. Use only the repository's `DerivedData`.

```sh
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  -only-testing:FluidDictationIntegrationTests/PillSpectrumTests \
  -only-testing:FluidDictationIntegrationTests/PillTransportTests \
  -only-testing:FluidDictationIntegrationTests/PillLoadingContinuityTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

mkdir -p DerivedData/PillChecks
clang -std=c11 -Wall -Wextra -Werror -fsanitize=thread -g \
  -I Sources/CoreAudioCaptureSupport/include \
  Sources/CoreAudioCaptureSupport/PillPCMTransport.c Tests/PillTransportTests.c \
  -o DerivedData/PillChecks/transport-tsan
DerivedData/PillChecks/transport-tsan
```

Launch the isolated Debug lab with `FLUIDVOICE_PILL_DEMO=1`.
The lab is intentionally separate from the normal application's menu and dictation
services, so fixtures cannot interfere with a real recording. Set `FLUIDVOICE_PILL_FIXTURE_SECTION_SECONDS=5`
for a slower visual inspection of each sound. `FLUIDVOICE_PILL_PCM_FILE` accepts
an existing mono 16 kHz audio fixture (up to two minutes) for silent same-audio
meter replay. This does not add a microphone tap or alter normal capture.
The opt-in fixture uses known PCM, the production live
renderer, and the real overlay loading/dismissal methods. It exercises readiness,
vowels, sibilants, silence, a sweep, pending stop, and multiple processing phases.
Its intentional fixture durations do not affect production behavior. The separate
microphone check uses the existing capture/ASR path only if macOS permission is
already granted, and does not insert text or save history. Close the lab and use
the normal app for ordinary dictation. Synthetic PCM is never used in normal runs.
