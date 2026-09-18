#!/usr/bin/env python3
"""Local P0 inventory. Read-only inputs; emits no transcript, names, or raw logs.

This is measurement tooling, not speech ground truth or an ASR-quality test.
Output creation is exclusive so an old baseline cannot be silently overwritten.
"""
import argparse
import hashlib
import json
import math
import plistlib
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                            timeout=30, check=False)
    if result.returncode:
        raise ValueError(f"{args[0]} failed (exit {result.returncode}); no raw output retained")
    return result.stdout.strip()


def dependency_revision(path):
    payload = json.loads(Path(path).read_text())
    matches = [pin["state"]["revision"] for pin in payload["pins"]
               if pin.get("identity", "").lower() == "fluidaudio"]
    if len(matches) != 1:
        raise ValueError("expected exactly one FluidAudio pin")
    return matches[0]


def source_inventory(repo):
    """Hash tracked dirty diff, never emit diff contents or untracked private data."""
    repo = Path(repo).resolve(strict=True)
    diff = subprocess.run(["git", "diff", "HEAD", "--binary"], cwd=repo,
                          capture_output=True, timeout=30, check=True).stdout
    swift_revision = dependency_revision(repo / "Package.resolved")
    xcode_revision = dependency_revision(
        repo / "Fluid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    checkout = command("git", "rev-parse", "HEAD", cwd=repo / ".build/checkouts/FluidAudio")
    declaration = re.search(r'FluidAudio\.git"\s*,\s*revision:\s*"([0-9a-f]{40})"',
                            (repo / "Package.swift").read_text())
    declared = declaration.group(1) if declaration else None
    return {
        "head": command("git", "rev-parse", "HEAD", cwd=repo),
        "trackedDirtyDiffSHA256": hashlib.sha256(diff).hexdigest(),
        "trackedDirty": bool(diff),
        "dirtyFingerprintScope": "tracked diff only; explicit tooling hashes recorded separately",
        "fluidAudio": {"declared": declared, "swiftResolved": swift_revision,
                       "xcodeResolved": xcode_revision, "localCheckout": checkout,
                       "allMatch": declared == swift_revision == xcode_revision == checkout},
        "installedBinaryMatchesSource": "unproven",
    }


def installed_inventory(app):
    app = Path(app).resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("unsafe bundle executable name")
    files = []
    for file in sorted((app / "Contents/MacOS").iterdir()):
        if file.is_file() and not file.is_symlink():
            files.append({"name": file.name, "sha256": sha256(file), "bytes": file.stat().st_size})
    # Caller may perform codesign verification with the host trust store separately.
    return {"bundleIdentifier": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "executables": files,
            "signatureVerification": "not performed by this inventory",
            "recordingTimeBuildMatch": "unproven without embedded build manifest"}


def safe_child(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid relative path")
    if relative.startswith("/") or any(p in ("", ".", "..") for p in relative.split("/")):
        raise ValueError("unsafe relative path")
    root = Path(root).resolve(strict=True)
    candidate = (root / relative).resolve(strict=True)
    if not candidate.is_relative_to(root) or candidate == root:
        raise ValueError("path escapes input root")
    return candidate


def session_inventory(session_path):
    path = Path(session_path)
    # Snapshot bytes once so the fingerprint identifies exactly what was analyzed.
    raw = path.read_bytes()
    session = json.loads(raw)
    tracks = []
    for track in session.get("audioTracks", []):
        kind = track.get("kind")
        if kind not in ("microphone", "applicationAudio"):
            raise ValueError("unknown track kind")
        chunks = []
        for chunk in track.get("chunks", []):
            file = safe_child(path.parent, chunk["relativeFilePath"])
            actual = sha256(file)
            chunks.append({"sequence": chunk.get("sequence"), "bytes": file.stat().st_size,
                           "sha256": actual, "storedSHA256Matches": actual == chunk.get("sha256"),
                           "discontinuityCount": len(chunk.get("discontinuities", []))})
        all_segments = session.get("transcriptSegments", [])
        if any("sourceTrackID" not in s for s in all_segments):
            raise ValueError("unknown segment schema: sourceTrackID is required")
        segments = [s for s in all_segments if s["sourceTrackID"] == track["id"]]
        visible = [s for s in segments if not s.get("isLikelyEcho", False)]
        health = track.get("health", {})
        if "droppedSampleCount" not in health:
            raise ValueError("unknown health schema: droppedSampleCount is required")
        tracks.append({"kind": kind, "captureMethod": track.get("captureMethod"),
                       "format": {k: track.get("format", {}).get(k) for k in
                                  ("sampleRate", "channelCount", "codec", "bitRate")},
                       "captureDrops": health["droppedSampleCount"],
                       "chunks": chunks, "segmentCount": len(segments),
                       "visibleSegmentCount": len(visible),
                       "visibleSpeakerCount": len({s["speakerID"] for s in visible if s.get("speakerID") is not None}),
                       "missingVisibleSpeakerIDCount": sum(s.get("speakerID") is None for s in visible),
                       "echoSegmentCount": len(segments) - len(visible)})
    attempts = [{k: a.get(k) for k in ("asrModel", "asrProvider", "diarizationModel",
                                      "pipelineVersion", "languageCode", "stage")}
                for a in session.get("processingAttempts", [])]
    return {"sessionSHA256": hashlib.sha256(raw).hexdigest(), "schemaVersion": session.get("schemaVersion"),
            "mode": session.get("mode"), "tracks": tracks, "processingAttempts": attempts,
            "eventCount": len(session.get("events", [])), "failureCount": len(session.get("failures", [])),
            "groundTruth": "not independently annotated; inventory does not infer recording conditions",
            "warning": "segment counts describe saved output, not verified speech or person counts"}


FLOW = re.compile(r'\[(\d\d):(\d\d):(\d\d\.\d+)\].*?\[live/(APP|MIC)\] flow '
                  r'chunks=(\d+) audio=([\d.]+)s openUtterance=([\d.]+)s '
                  r'partials=(\d+) utterances=(\d+) drops=(\d+)')


def summarize_flows(lines):
    rows = {"APP": [], "MIC": []}
    for line in lines:
        match = FLOW.search(line)
        if not match:
            continue
        h, m, s, kind, chunks, audio, open_seconds, partials, utterances, drops = match.groups()
        time = int(h) * 3600 + int(m) * 60 + float(s)
        row = dict(wallSeconds=time, chunks=int(chunks), audioSeconds=float(audio),
                   openSeconds=float(open_seconds), partials=int(partials),
                   utterances=int(utterances), drops=int(drops))
        if not all(math.isfinite(v) for v in row.values()):
            raise ValueError("nonfinite flow data")
        if rows[kind] and any(row[key] < rows[kind][-1][key] for key in
                              ("wallSeconds", "chunks", "audioSeconds", "partials", "utterances", "drops")):
            raise ValueError("flow counters/time regressed: select exactly one same-day session")
        rows[kind].append(row)
    result = {}
    for kind, samples in rows.items():
        runs = []
        first = None
        previous = None
        for row in samples:
            if previous and row["partials"] == previous["partials"] and row["chunks"] > previous["chunks"]:
                if first is None:
                    first = previous
                runs.append({"observedNoPartialSpanSeconds": round(row["wallSeconds"] - first["wallSeconds"], 3),
                             "audioAdvancedSeconds": round(row["audioSeconds"] - first["audioSeconds"], 3),
                             "partialCount": row["partials"],
                             "dropIncrease": row["drops"] - first["drops"]})
            else:
                first = None
            previous = row
        result[kind] = {"flowSamples": len(samples),
                        "lastCounters": ({k: v for k, v in samples[-1].items() if k != "wallSeconds"} if samples else None),
                        "longestSampledNoPartialRun": max(runs, key=lambda r: r["observedNoPartialSpanSeconds"]) if runs else None,
                        "interpretation": "sampled no-text lower bound, not proof of audible-speech blackout; mic silence is expected in this test"}
    return result


def model_manifest_inventory(manifest_path):
    path = Path(manifest_path)
    raw = path.read_bytes()
    manifest = json.loads(raw)
    records = []
    seen = set()
    repository_name = manifest["modelRepository"]
    repository = safe_child(path.parent, repository_name)
    actual_paths = set()
    for child in repository.rglob("*"):
        if child.is_symlink():
            raise ValueError("symbolic link model artifact")
        if child.is_file():
            actual_paths.add(repository_name + "/" + child.relative_to(repository).as_posix())
    for artifact in manifest.get("artifacts", []):
        relative = artifact["path"]
        if not relative.startswith(repository_name + "/"):
            raise ValueError("artifact outside model repository")
        if relative in seen:
            raise ValueError("duplicate model artifact")
        seen.add(relative)
        file = safe_child(path.parent, relative)
        actual = sha256(file)
        records.append({"path": relative, "sha256": actual,
                        "matchesManifest": actual == artifact.get("sha256")})
    if not records:
        raise ValueError("empty artifact manifest")
    return {"manifestSHA256": hashlib.sha256(raw).hexdigest(),
            "repository": manifest.get("modelRepository"), "artifacts": records,
            "allHashesMatch": all(r["matchesManifest"] for r in records),
            "exactTreeMatch": actual_paths == seen,
            "huggingFaceRevision": "not recorded; content hashes identify local artifacts only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--model-manifest", type=Path, required=True)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--log-first-line", type=int)
    parser.add_argument("--log-last-line", type=int)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"schemaVersion": 1, "createdAt": datetime.now(timezone.utc).isoformat(),
              "scope": "local P0 inventory; no ASR inference, no ground-truth verification",
              "toolSHA256": sha256(Path(__file__)), "source": source_inventory(args.repo),
              "installed": installed_inventory(args.app), "session": session_inventory(args.session),
              "offlineASRArtifacts": model_manifest_inventory(args.model_manifest)}
    if args.log:
        if not args.log_first_line or not args.log_last_line or not 1 <= args.log_first_line <= args.log_last_line:
            parser.error("log requires explicit ordered positive line bounds")
        raw = args.log.read_bytes()
        lines = raw.decode("utf-8", errors="replace").splitlines()
        if args.log_last_line > len(lines):
            parser.error("log range exceeds input length")
        selected = lines[args.log_first_line - 1:args.log_last_line]
        report["historicalFlow"] = {"logSnapshotSHA256": hashlib.sha256(raw).hexdigest(),
                                     "firstLine": args.log_first_line, "lastLine": args.log_last_line,
                                     "selection": "caller-selected same-session range; logs contain no date binding",
                                     "tracks": summarize_flows(selected)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        json.dump(report, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
    print("P0 inventory written; no input changed and no audio/transcript emitted")


if __name__ == "__main__":
    main()
