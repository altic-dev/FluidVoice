# Fluid WebRTC Audio Processing package

This local Swift package contains FluidVoice's pinned WebRTC Audio Processing Module/AEC3 bridge.
It is built from Google WebRTC revision
`d9bd07ba5f614156021df666ba4052ac73cf7953` and statically linked for macOS 15 on `arm64` and
`x86_64`.

The product build consumes the checked-in static XCFramework and therefore needs neither a WebRTC
checkout nor network access. The XCFramework was built locally from the pinned source; it is not a
downloaded framework. `UpstreamSources` contains every upstream and generated compile input used by
the archive members that the bridge executable actually linked. `Metadata` records the full
recursive GN target closure, selected archive-object dependency graph, exact checkout revisions,
build settings, and SHA-256 hashes. `BridgeSources` contains the C ABI implementation and its
standalone probe.

The full GN closure is intentionally larger than the final static archive. WebRTC's APM graph still
contains build-time Perfetto/protobuf generator edges even with `rtc_enable_protobuf=false`. The
link-map-derived archive contains no protobuf or Perfetto object, no concrete AEC dump writer, and
uses WebRTC's null AEC dump factory. All public app-facing declarations are C ABI; WebRTC C++
headers are not exposed by the package product.

Run `Scripts/verify.sh` to verify hashes, architectures, symbols, revision/configuration strings,
and a clean SwiftPM link. `Scripts/refresh.sh` documents and automates the reproducible rebuild from
an exact gclient checkout plus depot_tools. The refresh script rejects any revision mismatch.
`Scripts/benchmark.sh` builds an optimized, current-architecture harness and processes a
30-minute deterministic synthetic stream after warm-up. It enforces p99 below 5 ms, every call
below 10 ms, bounded RSS variation, and no monotonic RSS growth.

Licenses and required attribution for WebRTC and linked third-party source are in `Notices`.
