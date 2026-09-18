# Adversarial review — reference-aware playback attribution plan

Date: 2026-09-09 (local)
Reviewed artifact: `MEETING_PLAYBACK_ATTRIBUTION_V2_IMPLEMENTATION_PLAN.md` revision 1
Result: revision 2 incorporates the supported findings below. No implementation or production approval is claimed.

## Review execution

All reviewers were instructed to operate read-only and were limited to the plan and relevant FluidVoice capture/scoring source. No recordings, transcript content, logs, model weights, credentials, secrets, or unrelated files were included. The dirty-tree summaries printed by the tools describe the pre-existing shared worktree; all successful review results reported no reviewer edits.

| Requested reviewer | Successful result | Notes |
| --- | --- | --- |
| Claude Opus 5 | Orchestrate heavy route reported `claude · opus`; the response identified `claude-opus-5`; 294.5 s; `editedTree=false` | The first broad call hit the orchestration transport's 300 s timeout. A narrower retry completed. |
| Kimi K3 | `fireworks-ai/accounts/fireworks/models/kimi-k3`; 219.7 s; OpenCode plan mode | Completed on the first call. |
| Grok 4.6 | `grok-4.6`; xAI Grok CLI session `9e315fa8-069f-4ef7-9713-a985e2e01a9c` | Two bounded turns ended at their tool-turn limits; a read-only continuation in the same session returned the final review. |

Timeouts and turn-limit exits contained no review findings and were not counted as approval. The completed responses were reconciled against local source and Apple/WebRTC primary documentation.

## Convergent blockers and dispositions

### 1. Test the VPIO render side before adding WebRTC — accepted

Claude and Grok identified that `MeetingMicrophoneCapture` binds/read-backs audio-unit element 1 (input) but not element 0 (output), has no explicit application render source, and persists `voiceProcessingEnabled: true` as a literal after the setter rather than a readback. Kimi independently asked for exact public property IDs before the AGC/bypass trial.

Revision 2 now makes these the first probe: input/output current-device properties, graph/render activity, `isVoiceProcessingEnabled`, bypass, AGC, mute, and ducking state with exact property/scope/element/`OSStatus`. Element-0 force binding is diagnostic-only until route behavior is understood. The plan still treats missing render reference as a hypothesis until hardware results exist.

### 2. Evaluate the existing SCK paired microphone path before AEC3 — accepted

All three reviewers found that the repository already implements one `SCStream` producing selected-application `.audio` plus `.microphone`. This can provide a rawer microphone input and potentially a simpler clock relationship, but neither property is guaranteed by the public API.

Revision 2 adds this as Phase 0 trial C2 and the leading software-AEC input. It requires measurement of processing, clock relationship, latency, and jitter. It also records the critical product constraint: on speaker routes this path is currently `.unprotected`, so it cannot be called behavior-unchanged shadow mode and needs a separately reviewed capture migration before production.

### 3. A selected-application reference is incomplete — accepted with a privacy boundary

All reviewers noted that the microphone hears the full acoustic output while the current reference contains only the selected window/application and excludes FluidVoice. Other processes, notifications, helper processes, volume changes, and output DSP may be missing or transformed. AEC cannot cancel an absent source.

Revision 2 adds explicit reference scope and `referenceScopeLimited` / `referenceCompletenessUnobservable` outcomes, concurrent-other-process and volume-change trials, corpus cases, and fail-open semantics. It also refuses to make a broader full-system reference an automatic product default: full-mix diagnostic capture must be explicitly authorized, ephemeral, not transcribed, and separately reviewed for scope/retention/privacy. Without it, the feature promises only selected-scope playback suppression.

### 4. Do not prefer VPIO output plus AEC3 — accepted

All reviewers agreed that cascading AEC3 after Apple's nonlinear AEC/NS/AGC is the least identifiable path. Low-level intelligible leakage can have little stable linear coherence, so AEC3 may remain inert or damage quiet overlap.

Revision 2 orders the candidates as Apple configuration repair, SCK-paired mic plus AEC3, exclusive raw diagnostic if it adds information, and VPIO plus AEC3 only as a fallback. It adds convergence/ERLE/inertness rejection criteria and forbids tuning around a non-learnable VPIO residual.

### 5. Export both linear and suppressed AEC3 outputs — accepted

Claude and Grok noted that listening-optimized nonlinear suppression can damage quiet double-talk and that `EchoCanceller3` can expose a linear-filter output separately. Revision 2 requires both outputs, pins suppressor/comfort-noise/high-pass/field-trial configuration, and makes the linear output the first ASR-preservation candidate. Neither output is assumed safe until the bake-off.

### 6. Residual speech is not automatically near-end speech — accepted

Grok required the independent multi-band attribution candidate (or equivalent guard) for enforcement rather than making it optional. Revision 2 adopts that requirement. VAD, residual energy, AEC validity, or ASR text alone cannot produce a playback-only/near-end conclusion.

### 7. Restore the parent reliability gates — accepted

Kimi and Claude found that revision 1's suggested 95% reduction and five-point WER margin weakened the existing reliability plan. Revision 2 restores the binding parent gates: zero false accepted mic words/identities on the curated negative regression set, one-point missed-speech/WER non-inferiority margins, 12 negative sessions, 30 annotated minutes per populated positive condition, 100 short replies, recording/device/speaker splits, and recording-level uncertainty. Unscored/fail-open intervals remain in leak totals so abstention cannot pass.

### 8. Time-box and front-load AEC3 build feasibility — accepted

All reviewers warned that a “minimal AEC3 subset” still pulls substantial WebRTC infrastructure. Revision 2 names expected dependency families, requires an out-of-tree reproducible two-architecture smoke artifact before in-tree code, pins field-trial behavior, and defines failure to produce it within an approved time box as an abort outcome rather than permission to vendor the full tree or fetch a mutable binary.

### 9. Tighten synchronizer semantics — accepted

The reviews called out three distinct clocks/timelines, signed acoustic delay, ppm drift, codec priming/remainder, converter delay, multi-channel render policy, and valid samples with synthesized timing. Revision 2 explicitly models those, freezes adaptation across synthesized-timing spans, preserves masks instead of zero-fill, and scopes deterministic equality to the same binary/architecture/configuration.

### 10. Avoid residual-embedding domain drift — accepted with a safer first-release rule

Claude noted that AEC residual embeddings may be out-of-domain relative to existing natural-speech profiles. Revision 2 adds an embedding-domain metric, but does not make a residual embedding the first-release default. Profile learning is limited to independently admitted, verified no-playback intervals using original microphone PCM; overlap residuals do not enroll profiles.

## Findings adopted with modification

### Original-versus-residual ASR disagreement

Kimi proposed retaining an interval when original ASR has words and residual ASR is empty. Applied literally, that would restore the exact playback words a successful canceller removed. Revision 2 instead degrades to `mixedOrUncertain` only when the empty residual conflicts with residual-side speech activity, independent attribution, or timing evidence. Original/residual ASR remains a diagnostic pair; neither wins solely because it emitted words.

### Full-system reference

Claude suggested a second full-system SCK stream as the better AEC reference. Technically it may improve completeness, but silently capturing unrelated applications would expand user-authorized scope. Revision 2 includes an opt-in diagnostic comparison and requires a separate privacy/product decision before any production use. The selected-app-only limitation remains visible rather than being hidden by implementation convenience.

### SCK paired streams and clock sharing

Reviewers described the paired stream as the topology most likely to share a useful clock. Revision 2 does not promote that expectation to fact; Phase 0 measures PTS relationship, latency, drift, and jitter.

## Overall disposition

The three reviews agree on the durable design principles: preserve originals, run post-capture first, fail open, never use VAD/text as source identity, do not lower the B1 correlation threshold, keep live processing out of the first release, and gate speaker-profile learning more strictly than transcript fallback.

They also agree that revision 1 moved to AEC3 too quickly. Revision 2 therefore approves only the Apple/SCK reference probe, synchronizer harness, and conditional out-of-tree AEC3 feasibility spike. It does **not** approve an AEC3 dependency, raw-microphone capture migration, production suppression, profile enforcement, or app reinstall.
