# Kimi K3 review of microphone-admission plan revision 2

Disposition: revision 3 addresses the six plan findings. A subsequent read-only Stage A code-review request in the same OpenCode session timed out at 180 seconds without findings; do not interpret it as approval. Local Stage A validation passed 20 tests.

Read-only review through OpenCode; amended implementation has not been signed off by this review. The tool's dirty-tree listing includes pre-existing work, not a claim the reviewer authored it.

status: success
sessionID: ses_f7bec653effeM3RqWBphVhxcRv
model: fireworks-ai/accounts/fireworks/models/kimi-k3
agent: plan
elapsed: 211.0s
tokens: {"total":74870,"input":1633,"output":1374,"reasoning":8383,"cache":{"write":0,"read":63480}}
cost: $0.448019
changed files:
Fluid.xcodeproj/project.pbxproj                    | 367 +++++++++++++++++++++
 MEETING_AUDIO_PHASE0_RUNBOOK.md                    |  14 +-
 Sources/Fluid/Persistence/KeychainService.swift    |   8 +-
 Sources/Fluid/Services/FileLogger.swift            |   6 +
 Sources/Fluid/Services/FluidAudioProvider.swift    | 144 +++++++-
 .../LiveTranscription/MeetingLiveTrackEngine.swift | 133 +++++++-
 .../MeetingMicrophoneCaptureTests.swift            |  78 ++++-
 7 files changed, 714 insertions(+), 36 deletions(-)
?? Fluid.xcodeproj/xcshareddata/xcschemes/FluidASRBaseline.xcscheme
?? MEETING_DIARIZATION_V2_IMPLEMENTATION_PLAN.md
?? MEETING_MICROPHONE_ADMISSION_IMPLEMENTATION_PLAN.md
?? MEETING_RELIABILITY_IMPLEMENTATION_PLAN.md
?? MEETING_RELIABILITY_P0_BASELINE.md
?? Sources/Fluid/Services/Meeting/MeetingASRPreparationOwner.swift
?? Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift
?? Tests/FluidASRBaselineHost/
?? Tests/FluidASRBaselineTests/
?? Tests/FluidDictationIntegrationTests/MeetingASRPreparationOwnerTests.swift
?? Tests/FluidDictationIntegrationTests/MeetingProcessingConfigurationTests.swift
?? Tests/FluidDictationIntegrationTests/MeetingProviderOptionsTests.swift
?? fluid_pico_cutB_wingbeat_51s.mp4
?? fluid_pico_cutB_wingbeat_53s.mp4
?? fluid_pico_false_start_10s_prompt.md
?? fluid_pico_false_start_74s.mp4
?? fluid_pico_false_start_prompt.md
?? fluid_pico_false_start_v3.mp4
?? fluid_pico_hero_76s.mp4
?? fluid_pico_sprinter.mp4
?? render_pico.py
?? render_pico_split.py
?? render_pico_v2.py
?? tools/MEETING_DIARIZATION_EVAL.md
?? tools/MEETING_RELIABILITY_P0_ADVERSARIAL_REVIEW.md
?? tools/meeting_reliability_baseline.py
?? tools/test_meeting_reliability_baseline.py

Review complete. Plan rev 2 read against the five permitted source files; findings below, Stage A blockers first.

## Stage A blockers

**1. [High] "Shadow disabled AND enabled" is untestable as written — Stage A defines no enablement mechanism or call site.**
Stage A item 4 specifies a pure shadow decision function with injected evidence, and the exit gate requires behavior unchanged "with shadow disabled AND enabled" — but the `off`/`shadow`/`enforce` mode flag is explicitly Stage D (item 3), and no Stage A item names where the shadow function is invoked (tests only? a debug gate? unconditionally inside `processMicrophoneChunk`?). An implementer must invent the switch, and the cheapest invention is evaluating unconditionally in the live per-chunk path — adding per-turn work and a new failure surface in production alongside the echo scoring `do/catch` at pipeline :1972-2002. Same gap covers the fake temporal-detector implementation (A3): "fake" is undefined, so it could end up wired into the real path returning constants. Minimal correction: state in Stage A that the shadow function and fake detector are invoked only from tests (or a named debug-only gate), are side-effect-free, never persisted, never logged with transcript content, and that any runtime mode flag is out of scope until Stage D.

**2. [High] The legacy-mapping boundary is ambiguous exactly where the dangerous semantics live: the rescue inside `verdict()`.**
A1/A2 say "rename" plus "a clearly named legacy mapping" without stating whether the mapping wraps the existing `verdict()` output or reimplements the decision. The behavior that must survive is not just the `effectiveEcho` truth table (pinned by `testEffectiveEchoMatrix`); it is the scorer-internal rescue, which (a) runs *before* the coverage gate, so it fires even when `scoreableFraction < 0.5` (scorer :285-289); (b) lets NaN gaps under 0.75 s accumulate through without breaking a low run (:262-267); and (c) is denied only by the conjunctive trivial-run test (scoreable coverage AND median ≥ 0.8 AND lowRunFraction < 0.15, :280-283). A mapping written at the segment/`effectiveEcho` level cannot reproduce (a)-(c); a reimplementation can silently drop one. Minimal correction: mandate that Stage A is a mechanical rename of the enum case with zero logic edits to `verdict()`/`effectiveEcho`, and add characterization tests pinning (a), (b), and (c) before the rename lands.

**3. [Medium] The evidence contract omits the identity keys Stage C's shared-centroid exclusion needs.**
The evidence field list (§3) has interval coverage and embedding provenance but no turn/segment key and no diarization observation key. The contamination unit is the chunk-level label cluster: one `Observation` per `microphone:<chunkID>:<label>`, one centroid, shared by every turn with that label (pipeline :1937-1964, :2027), admitted today by text-only `isLikelyEcho` (:720-726). Turn-granular evidence without the observation key cannot express "rejected sibling ⇒ shared centroid ineligible" (C2), and since the contract is Stage A's deliverable, omitting the keys means reworking a test-pinned contract later. Minimal correction: add mandatory identity fields to the Stage A contract — turn key (`microphone:<chunkID>:<index>`), observation key (`microphone:<chunkID>:<label>`), and capture-epoch identifier — noting the one-to-many observation→turn relationship.

**4. [Medium] Adversarial unit cases (A5) have unspecified expected outcomes.**
"Identical real repetition of playback" is scored `echo` and hidden by the *current* code — that is today's behavior, which Stage A must preserve. If the new tests assert the aspirational outcome, they change behavior; if they assert the current outcome as the policy target, they entrench it. Rule 2 ("low explanation never rescues") deliberately inverts the live rescue, so shadow and legacy disagree by construction on every rescued turn. Minimal correction: each A5 case asserts two explicit expectations — legacy-mapping output equals pre-change output, shadow output marked experimental with its own reason code — and the rescue-removal delta gets a dedicated reason code so Stage B's would-suppress accounting isn't dominated by the deliberate inversion.

## Later-stage concerns

**5. [Medium] The temporal detector's "capture epoch" is undefined relative to existing staleness machinery.**
The plan requires freshness/reset on discontinuities but never binds "capture epoch" to `epochBoundaries` (either-track discontinuities, pipeline :1110-1118) or to the ±`blockSeconds` guard intervals the scorer zeroes/masks (:998-1047). If the detector's epoch is narrower than the delay consensus's, duplicate state can survive the clock jump that invalidated the delay estimate — cross-jump correlation presented as fresh support. Minimal correction (Stage B1): define the detector epoch as the intervals between `epochBoundaries`, mandate state reset plus evidence invalidation at those boundaries, and state whether the scorer's guard-interval policy is reused or replaced.

**6. [Low] "Never scored" and "scored but inconclusive" are collapsed today and will pollute Stage B's unknown reporting.**
`computeEchoVerdicts` returns an empty verdicts dict when no delay resolves (:1199-1201), and the call site folds absence into `.unknown` (`signalVerdictByIndex[index] ?? .unknown`, :2041) — indistinguishable from a fully scored inconclusive turn. Stage A's typed evidence can carry the distinguished values in parallel with the legacy-collapsed one, but the plan doesn't require them as separate reason codes; without that, Stage B's "complete unknown/fallback reporting" exit cannot tell a blind scorer (no lock, no reference) from an inconclusive one. Minimal correction: name distinct reason codes for `noDelayLock`, `referenceUnavailable`, `unscoredCoverage`, and `scoredInconclusive` in the Stage A contract, with the legacy mapping defined as their collapse into `.unknown`.

No findings on the evidence calibration claims themselves; per scope, nothing here asserts the detector will work — finding 5's note that the observed 55-70 ms lag is "a hypothesis to test" is the correct posture.
