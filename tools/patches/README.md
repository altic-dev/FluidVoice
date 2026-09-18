# FluidAudio Nemotron compatibility patch

Base FluidAudio revision: `3fd63887eef1dc25edea8263ce4b44aa854d898b`.

`fluidaudio-nemotron-compatibility.patch` preserves the independent dependency work. The current
development workspace points the app at that maintained local checkout; this must become a
published immutable fork revision before merge. Apply the patch at the base revision with
`git apply --check` followed by `git apply`. Do not patch Xcode DerivedData.
The current working checkout is `.local-dependencies/FluidAudio`, branch `codex/nemotron-diarization`;
that workspace is ignored, and this patch includes all nine changed/new source and test files.

Implemented: configurable speaker count, explicit Nemotron tensor geometry, strict shape/dtype and
length validation, Float16 output decoding, caller-controlled compute configuration, local compiled
model loading, cancellation checks around loading, and overflow-checked dimension validation.
The Nemotron factory preserves the explicitly supplied update cadence, including 300, rather than
silently applying the older Sortformer clamp to 340. Cache scoring parameters remain explicit. The
host mel ABI is frozen per model family: Nemotron uses the checked-in NeMo settings and frame-count
semantics, while legacy Sortformer retains its existing framing behavior. Complete-file Nemotron
processing emits the final core tail instead of leaving it as right-context-only audio. Streaming
state rejects inconsistent buffers and invalid reported embedding lengths.

Verified: the 67-test Sortformer/legacy integration selection passed, and the 10-test Nemotron
compatibility suite passed with the actual local CoreML artifact. The real-model suite loads the
model and runs one complete fixed window plus its final core tail end-to-end. It is enabled with
`NEMOTRON_DIARIZATION_MODEL_PATH` pointing to an `.mlpackage` or `.mlmodelc` directory. No model weights
are included in the patch or the DMG.

This establishes the Swift runtime contract and end-to-end execution. Model quality and performance
measurements are intentionally out of scope because they were completed separately. Once the
dependency changes are committed to the maintained fork, update the app's Xcode and Swift package
pins together.
