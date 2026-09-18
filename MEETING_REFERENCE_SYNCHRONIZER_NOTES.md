# Offline synchronizer first slice

`MeetingReferenceSynchronizer` is a production-inert, deterministic in-memory fixture
API. It converts microphone and ScreenCaptureKit-style reference PCM into 10 ms analysis
frames, preserving valid-sample masks and carrying the microphone source, reference PTS,
and derived session-monotonic timelines.

The slice implements versioned linear conversion metadata, explicit converter delay
compensation, codec priming/remainder/edit-list offsets, bounded input/output budgets,
epoch boundaries, scope/completeness reasons, and synthesized microphone timing freeze and
resynchronization metadata. Missing coverage is represented by masks and unknown reasons;
it is never zero-filled as measured silence.

Frames are consumed in caller arrival order. The first arrival for a sequence number wins;
duplicates and lower-than-the-latest sequence numbers are dropped and counted without adding a
gap or overwriting accepted samples. A forward sequence jump creates an epoch/reset boundary. A
positive interval between the prior accepted end and the current start is marked as unknown gap;
contiguous sample times receive only the boundary marker, so the valid current frame is not
misclassified as missing. Rejected frames consume their sequence number and event insertion is
deduplicated, preventing one malformed frame from manufacturing multiple epochs. Repeated or
overlapping source timestamps are dropped and counted as late/duplicate input. Empty and
pre-origin invalid frames are dropped without claiming a source origin; only a midstream empty
block contributes one inferred unknown interval.

Microphone source origin is established only by the first valid frame. Reference drift maps both
segment starts and segment durations through the same affine scale; output resampling uses the
corresponding session rate so multi-frame placement remains consistent. Each domain is anchored to
its own first valid source coordinate for session placement; the original reference PTS remains in
the source timeline. The exposed lag is configured/mapped alignment (the difference between mapped
first-valid starts), not an observed acoustic delay; `.delayUnresolved` remains present because this
offline fixture has no shared-clock calibration. The value preserves priming, converter, edit-list,
and path-offset coordinates while remaining invariant to unrelated absolute clock origins and
without treating independently selected first samples in a partial output frame as a measured
delay. Synthesized microphone timing freezes adaptation until a real host-time boundary;
sequence/gap boundaries reset state but do not themselves claim measured drift or acoustic delay.

Multichannel PCM is expected to be interleaved and divisible by its declared channel count.
The deterministic fixture policy downmixes by arithmetic channel mean before resampling;
channel-layout-aware mixing and a measured downmix error budget are deferred.

Deferred by design: acoustic delay estimation, adaptive drift estimation, AEC/attribution
engines, file readers, callback integration, and production policy wiring. The configured
reference offset and drift are fixture controls for deterministic replay, not a claim that
those quantities have been measured from a recording.

## Offline replay command

`FluidASRBaselineHost` remains inert in its normal launch path. The replay command is
enabled only by an explicit `--offline-synchronizer-replay` argument or by setting
`FLUID_ASR_OFFLINE_REPLAY=1`; without one of those gates it enters the existing host app
path unchanged. Input is a local JSON fixture supplied on stdin, or with
`--input /absolute/path/to/fixture.json` when the explicit gate is present:

```sh
FluidASRBaselineHost.app/Contents/MacOS/FluidASRBaselineHost \
  --offline-synchronizer-replay --input /absolute/path/to/fixture.json
```

The fixture schema is version `1` and contains only synchronizer configuration, enum
strings, frame metadata, and PCM sample numbers. The CLI rejects unknown keys, unknown
enum values, non-finite numbers, malformed channel arrays, invalid ranges, and inputs
outside both the configured and hard safety budgets before invoking the synchronizer.
The result is one bounded JSON summary containing a canonical SHA-256 replay identity,
frame/mask/timeline ranges, epoch and unknown-reason counts, and numeric diagnostics.
It never emits raw PCM arrays, file paths, transcript text, labels, embeddings, or model
artifacts. Failed gate, validation, and synchronizer-open cases return nonzero status;
normal host behavior and production capture/transcription wiring are unchanged.

The host fixture profile is intentionally bounded to roughly 2,000,000 input samples and
6,000 output frames (about 60 seconds at the default 16 kHz/10 ms grid), with a 64 MiB
encoded-input ceiling and a corresponding output-sample allocation cap. These limits are
applied before decoding/normalization to keep replay memory use finite.
