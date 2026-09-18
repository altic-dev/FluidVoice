# Adversarial review — playback echo-cancellation execution plan

Date: 2026-09-10 (local)
Reviewed artifact: `MEETING_PLAYBACK_ECHO_CANCELLATION_EXECUTION_PLAN.md` revision 1
Current artifact: revision 3 incorporates the completed Grok 4.6 and Claude Opus 5 findings below
Status: both requested adversarial reviews completed and reconciled. No implementation or production approval is claimed.

## Review execution

Reviewers were instructed to remain read-only and not access recordings, transcripts, secrets, hardware, or unrelated files.

| Requested reviewer | Result | Disposition |
| --- | --- | --- |
| Grok 4.6 | Initial Orchestrate run ended before findings. Direct xAI Grok session `fe468faa-c9ff-435d-aee8-554a54654f49` reached its first turn cap; a no-more-tools continuation completed with a structured `REVISE` review. | Counted as a completed adversarial review. The CLI's “changed files” listing was the pre-existing dirty worktree inventory, not reviewer edits. |
| Claude Opus 5 | The first dispatch was rejected by the repository provider boundary. After the user explicitly authorized Anthropic disclosure with that conflict disclosed, a broad run ended after 281.3 s with no findings; a plan-only retry completed in 167.9 s through `heavy (claude · opus)`, returned `REVISE`, and reported `editedTree=false`. | Counted only the completed plan-only result. No recordings, transcripts, embeddings, secrets, or unrelated files were sent. |

Timeouts, partial work logs, and rejected dispatches are not reviews or approvals.

## Grok 4.6 verdict

`REVISE`: do not begin AEC3 dependency work until the paired-SCK signal domain is proven learnable and the delay/admission ownership boundaries are executable gates.

## Findings and revision-2 dispositions

### P0. Paired-SCK delivery is not acoustic learnability — accepted

The draft promoted paired-SCK plus AEC3 even though C2 measured delivery metadata only. Revision 2 makes AEC3 conditional and adds Stage 0.5 before dependency work. That stage requires real paired render/capture evidence for signed delay, drift, jitter, frequency-dependent coherence, path stability, excitation, and likely preprocessing. C2 metadata and synthetic FIR fixtures explicitly cannot satisfy the gate.

### P0. Bulk-delay ownership was ambiguous — accepted

The synchronizer and AEC3 could otherwise compensate the same delay or leave it unowned. Revision 2 assigns clock/epoch/mask mapping to `MeetingReferenceSynchronizer` without acoustic time-shifting. AEC3 alone owns acoustic bulk delay; chronological render precedes capture and at most one bounded measured hint seeds the engine.

### P0. An empty residual could erase genuine speech — accepted

Revision 2 adds the same rule to replay and enforcement: residual-empty plus original speech activity, mixed attribution, exact repetition, or timing disagreement becomes `mixedOrUncertain`; it cannot become playback-only merely because the canceller emitted silence. Original text/audio remains recoverable.

### P0. Capture protection and offline admission could diverge — accepted

Revision 2 forbids rewriting an original `.unprotected` capture era. Successful processing is immutable derived provenance. Before migration, the implementation must inventory capture-era admission, live admission, offline interval admission, retries, whole-chunk fallback, trusted observations, stitching, all transcript consumers, and profile persistence. Offline consumers must share one persisted interval decision.

### P1. Selected-app reference incompleteness was not operational — accepted with scoped semantics

Revision 2 distinguishes reference-scope provenance from interval ownership. Known helper/out-of-scope playback and route/volume/DSP transitions cannot become accepted near-end speech. The signal-domain and corpus stages now include helper-process, other-process, and volume-change cases. The plan retains the privacy boundary: it does not silently broaden to full-system capture, and its selected-app guarantee remains explicitly scoped.

### P1. Combined bake-off preceded the independent guard — accepted

The observational multiband attribution guard is now Stage 4; corpus acquisition and combined bake-off are Stage 5. The existing B1 detector remains a fixed baseline rather than being tuned until it appears useful.

### P1. Abstention could game the acceptance metric — accepted without inventing speech thresholds

Revision 2 counts accepted, uncertain, scope-limited, and fail-open original microphone words in playback-only leak totals. It adds a pre-registered 99% eligible-session timing/reference coverage floor, individual-session enforcement, identity-coverage reporting, and rejection of empty-residual conflicts. It deliberately does not set one global cap on `mixedOrUncertain`, because legitimate double-talk populates that outcome; condition-specific caps must be registered before tuning.

### P1. AEC3 extraction can become an unbounded dependency project — accepted

The spike remains out-of-tree and abortable. Revision 2 explicitly pins suppressor, comfort noise, high-pass, field trials, SIMD policy, and every APM submodule. Failure of the time/size/maintenance gate leaves the speaker-route microphone `.unprotected`; it does not authorize a home-grown canceller or mutable prebuilt binary.

### P1. Historical centroid and fallback bypasses were missing — accepted

Revision 2 requires quarantine of pre-existing centroids without clean provenance and tests original-PCM retries/fallbacks, shared observations, global stitching, and every transcript/profile consumer against the same interval decision. First-release profiles remain restricted to independently accepted no-playback original-microphone intervals.

### P1/P2. Route and channel policies were underspecified — accepted

The first enforcement matrix is now exactly built-in output plus built-in microphone. Every route/device change ends the era and resets synchronizer, AEC, and guard state. Headphones, Bluetooth, HDMI, aggregate, external, and mixed routes are separate domains. The wrapper stage now freezes and measures a versioned stereo/multichannel render-downmix policy.

### P2. Frozen invalid VPIO evidence should not permanently close Apple paths — accepted narrowly

Revision 2 keeps current VPIO plus an external reference as a last comparison only when existing valid evidence shows a coherent, learnable residual. It does not reopen generic Trial B or reinterpret the frozen invalid runs as proof either way.

## Missing evidence retained as gates

- Real paired-SCK acoustic learnability with excited reference and microphone capture.
- Executable render-before-capture and single-delay-owner behavior.
- Residual-empty conflict cases covering exact repetition, quiet double-talk, and path changes.
- One-consumer-matrix proof across transcript, UI, export, summary, search, retry, stitching, and profiles.
- Helper/out-of-scope playback and volume/DSP transition behavior.
- AEC3 dependency feasibility, sanitizers, universal build/signing, and resource bounds.
- Topology-matched development and held-out corpus results.

None of these is represented as completed evidence.

## Invariants retained unchanged

- Original application and microphone tracks are immutable.
- Captured application audio is never played back by FluidVoice.
- AEC transforms samples; it does not decide identity or visibility.
- VAD, ASR text, ERLE, residual energy, and voice-processing flags cannot prove near-end speech.
- Invalid or missing samples never become silence; adaptation freezes and the result is explicit.
- Default is `off`; shadow mode changes no user-visible output or profile.
- Raw paired-SCK live admission remains closed in the first release.
- Profile enrollment uses only independently accepted, no-playback original microphone intervals.
- Failed AEC3 feasibility means no AEC3 and no improvised substitute.

## Claude Opus 5 verdict

`REVISE`: Stage 0/0.5 may proceed after tightening causality and gate semantics; later stages were internally gameable or unreachable until the findings below were resolved.

## Opus findings and revision-3 dispositions

### P0. Negative/out-of-range delay could make AEC3 non-causal — accepted

Revision 3 permits one measured, constant render-lead pre-roll owned by the synchronizer, while AEC3 remains the sole adaptive acoustic-delay owner. Stage 0.5 now requires p50/p95/p99 signed-delay distributions, a frozen lead budget and safety margin, and a causal p99 inside the pinned candidate's buffer/search range. Out-of-range eras are `unscored`.

### P0. Recoverable uncertain text could game both leak and recall metrics — accepted

Revision 3 defines one default final-transcript projection for every outcome. `mixedOrUncertain`, `unscored`, and `scopeLimited` fail open visibly; only `likelyPlaybackOnly` is hidden. Playback leak, missed-speech, and WER are computed from that same artifact, with condition-specific uncertain-duration ceilings frozen before tuning.

### P0. First-release profile enrollment was structurally starved — accepted by splitting releases

Revision 3 does not relax the verified-no-playback original-microphone rule. New profile enrollment from cleaned paired-SCK speaker eras is deferred to a separately gated later stage. First transcript enforcement keeps profile matching read-only and gates identity output against the existing baseline without mutating profiles to pass.

### P1. Eligibility and zero-defect gates were gameable — accepted

Stage 0.5 must pre-register the exact eligibility predicate, allowed reasons, maximum ineligible fraction, minimum exposure, and per-condition ceilings. Stage 5/8 require a one-sided upper confidence bound on leakage per exposure-hour; zero observations without sufficient independent exposure returns `insufficientEvidence`.

### P1. Runtime SIMD invalidated replay/cache identity — accepted

Revision 3 pins a portable SIMD baseline, forbids uncontrolled fast-math/FP contraction, and records CPU features, ABI, compiler, deployment target, and native/Rosetta mode in engine and cache identity. Bit identity is required only on a declared reference configuration; supported cross-machine runs require tolerance-bounded metrics and identical interval decisions.

### P1. Clock drift was measured but unowned — accepted

Continuous versioned de-drift resampling belongs to the synchronizer and is explicitly separate from constant render lead and AEC3 adaptive delay. The manifest freezes ppm/cumulative-offset budgets. A one-hour synthetic ramp must prove de-drift and AEC delay do not oscillate or repeatedly reconverge.

### P1. Profile quarantine contradicted rollback — accepted

Quarantine is now reversible and non-destructive. Stage 0 hashes profile/centroid state, retains original embeddings, binds quarantine to provenance, and requires the kill switch to restore the exact baseline hash.

### P1. Evaluation PCM privacy was underspecified — accepted

No report, diagnostic, crash, or sanitizer artifact may contain PCM, text, embeddings, absolute paths, window titles, or speaker labels. The opt-in derived-audio workspace is mode 0700, backup/index excluded, protected at least like source recordings, defaults to a 24-hour TTL with a seven-day maximum, and is destroyed when the gate closes or is cancelled. Corpus admission requires per-recording consent provenance.

### P2. Guard and held-out sequencing was circular — accepted

Stage 4 exits only on development evidence and structural invariants. Stage 5 records a one-time held-out unlock; any earlier access reclassifies the affected data as development and requires a fresh held-out split.

### P2. Comfort noise and asymmetric gaps corrupted evidence — accepted

Energy/coherence attribution and residual-empty conflict checks use original/reference/linear-filter signals only. The suppressed output is ASR-only and its comfort-noise floor is measured separately. One render block is required per capture block; asymmetric gaps beyond the frozen tolerance reset the engine and produce `unscored`, never zero-filled adaptation.

## Combined disposition

Both reviewers rejected immediate AEC3 implementation. Revision 3 therefore authorizes no dependency or production change. The first executable unit is Stage 0/0.5 only: freeze baseline/profile state and establish a real, causal, drift-bounded, learnable paired-SCK signal domain. Failure leaves the current speaker-route microphone `.unprotected`; it does not authorize threshold relaxation or a home-grown canceller.
