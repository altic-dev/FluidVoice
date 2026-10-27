#!/usr/bin/env python3
"""Freeze/verify the playback-echo Stage 0 baseline without emitting private content.

The checked-in report contains hashes and bounded numeric inventory only. It never
copies audio, transcript text, speaker names/IDs, embeddings, device identifiers,
window titles, or absolute paths. Source meeting sessions are read-only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any


UUID_RE = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ISO8601_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SUPPORTED_TRACK_KINDS = {"applicationAudio", "microphone"}
LOSSLESS_CODECS = {"alac", "flac", "lpcm", "pcm-f32", "pcm-s16", "pcm-s24", "pcm-s32"}
CONTROLLED_SPEAKER_SESSIONS = {
    "720AB8CD-842E-4D25-97A1-9CAAFBC28E74",
    "C102F9B6-C61F-48EB-8F8B-A36451C712B8",
    "4734B958-A92F-4AEB-954C-7A9AC91DE457",
    "51507DB8-FD6B-48CD-9996-70AED789BDF5",
    "990EDF30-4BDD-420F-B78C-4CB5D430F998",
}
LEGACY_AGGREGATE = "fv-admission-b3-controlled-v3.json"


def reject_nonfinite(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def load_json(path: Path) -> tuple[bytes, Any]:
    raw = path.read_bytes()
    return raw, json.loads(raw, parse_constant=reject_nonfinite)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return sha256_bytes(payload)


def safe_child(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("invalid relative path")
    components = relative.split("/")
    if relative.startswith("/") or any(part in ("", ".", "..") for part in components):
        raise ValueError("unsafe relative path")
    root = root.resolve(strict=True)
    candidate = (root / relative).resolve(strict=True)
    if candidate == root or not candidate.is_relative_to(root):
        raise ValueError("path escapes session root")
    return candidate


def media_seconds(value: Any) -> float:
    if not isinstance(value, dict):
        raise ValueError("media time must be an object")
    numerator = value.get("value")
    denominator = value.get("timescale")
    if not isinstance(numerator, int) or not isinstance(denominator, int) or denominator <= 0:
        raise ValueError("invalid media time")
    result = numerator / denominator
    if not math.isfinite(result):
        raise ValueError("non-finite media time")
    return result


def finite_number(value: Any, name: str, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (minimum is not None and result < minimum):
        raise ValueError(f"invalid {name}")
    return result


def track_inventory(session_root: Path, track: dict[str, Any]) -> dict[str, Any]:
    kind = track.get("kind")
    if kind not in SUPPORTED_TRACK_KINDS:
        raise ValueError("unknown track kind")
    audio_format = track.get("format")
    if not isinstance(audio_format, dict):
        raise ValueError("missing track format")
    codec = audio_format.get("codec")
    if not isinstance(codec, str) or not codec:
        raise ValueError("invalid codec")
    sample_rate = finite_number(audio_format.get("sampleRate"), "sample rate", minimum=1)
    channels = audio_format.get("channelCount")
    if not isinstance(channels, int) or isinstance(channels, bool) or not 1 <= channels <= 32:
        raise ValueError("invalid channel count")

    chunks = track.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        raise ValueError("baseline recording track has no chunks")
    expected_sequence = 0
    chunk_inventory = []
    total_duration = 0.0
    total_bytes = 0
    for chunk in chunks:
        if not isinstance(chunk, dict) or chunk.get("sequence") != expected_sequence:
            raise ValueError("chunk sequence is not contiguous")
        expected_sequence += 1
        file_path = safe_child(session_root, chunk.get("relativeFilePath"))
        actual_hash = sha256_file(file_path)
        stored_hash = chunk.get("sha256")
        if not isinstance(stored_hash, str) or not SHA256_RE.fullmatch(stored_hash):
            raise ValueError("invalid stored chunk hash")
        if actual_hash != stored_hash:
            raise ValueError("chunk hash mismatch")
        start = media_seconds(chunk.get("presentationStart"))
        end = media_seconds(chunk.get("presentationEnd"))
        if end <= start:
            raise ValueError("non-positive chunk duration")
        byte_count = file_path.stat().st_size
        if byte_count <= 0 or byte_count != chunk.get("byteCount"):
            raise ValueError("chunk byte count mismatch")
        if chunk.get("finalizationState") != "finalized":
            raise ValueError("baseline chunk is not finalized")
        discontinuities = chunk.get("discontinuities", [])
        if not isinstance(discontinuities, list):
            raise ValueError("invalid discontinuity inventory")
        duration = end - start
        total_duration += duration
        total_bytes += byte_count
        chunk_inventory.append(
            {
                "sequence": chunk["sequence"],
                "sha256": actual_hash,
                "storedSHA256Matches": actual_hash == stored_hash,
                "bytes": byte_count,
                "presentationStartSeconds": start,
                "presentationEndSeconds": end,
                "discontinuityCount": len(discontinuities),
            }
        )

    health = track.get("health")
    if not isinstance(health, dict) or not isinstance(health.get("droppedSampleCount"), int):
        raise ValueError("missing capture-drop inventory")
    if health["droppedSampleCount"] < 0:
        raise ValueError("negative capture-drop count")
    eras = track.get("captureEras", [])
    if not isinstance(eras, list):
        raise ValueError("invalid capture-era inventory")
    era_inventory = []
    for era in eras:
        if not isinstance(era, dict):
            raise ValueError("invalid capture era")
        start = finite_number(era.get("startSeconds"), "era start")
        era_inventory.append(
            {
                "method": era.get("method"),
                "echoProtection": era.get("echoProtection"),
                "startSeconds": start,
                "hasSettledVoiceProcessingConfig": era.get("settledConfig") is not None,
                "hasClockDriftRecord": era.get("clockDrift") is not None,
            }
        )

    return {
        "kind": kind,
        "captureMethod": track.get("captureMethod"),
        "format": {"codec": codec, "sampleRate": sample_rate, "channelCount": channels},
        "chunkCount": len(chunk_inventory),
        "bytes": total_bytes,
        "presentationDurationSeconds": total_duration,
        "captureDrops": health["droppedSampleCount"],
        "chunks": chunk_inventory,
        "captureEras": era_inventory,
    }


def topology_for(tracks: list[dict[str, Any]]) -> str:
    by_kind = {track["kind"]: track for track in tracks}
    if set(by_kind) != SUPPORTED_TRACK_KINDS:
        raise ValueError("online baseline requires exactly application and microphone tracks")
    application = by_kind["applicationAudio"]
    microphone = by_kind["microphone"]
    if application["captureMethod"] != "screenCaptureKit":
        return "unsupported"
    if microphone["captureMethod"] == "screenCaptureKit":
        return "pairedSCKSingleStream"
    if microphone["captureMethod"] == "voiceProcessing":
        return "selectedApplicationSCKPlusVPIOMicrophone"
    return "selectedApplicationSCKPlusOtherMicrophone"


def stage05_reasons(recording: dict[str, Any]) -> list[str]:
    reasons = []
    if recording["topology"] != "pairedSCKSingleStream":
        reasons.append("notRawPairedSCKTopology")
    if any(track["format"]["codec"].lower() not in LOSSLESS_CODECS for track in recording["tracks"]):
        reasons.append("lossySourceCodec")
    if recording["route"] != "builtInSpeakersPersisted":
        reasons.append("exactBuiltInRouteNotPersisted")
    reasons.extend(
        [
            "excitationNotIndependentlyAnnotated",
            "consentProvenanceNotRecordedForSignalDomainCorpus",
            "recordingBuildNotCryptographicallyBound",
        ]
    )
    return sorted(set(reasons))


def profile_state_inventory(
    sessions_root: Path, frozen_session_ids: list[str] | None = None
) -> dict[str, Any]:
    projections = []
    speaker_count = 0
    embedding_count = 0
    dimensions = set()
    if frozen_session_ids is None:
        session_paths = sorted(sessions_root.glob("*/session.json"))
    else:
        if len(frozen_session_ids) != len(set(frozen_session_ids)):
            raise ValueError("duplicate profile-state session ID")
        session_paths = []
        for session_id in frozen_session_ids:
            if not isinstance(session_id, str) or not UUID_RE.fullmatch(session_id):
                raise ValueError("invalid profile-state session ID")
            session_paths.append(safe_child(sessions_root, f"{session_id}/session.json"))
        session_paths.sort()
    source_session_ids = []
    for session_path in session_paths:
        raw, session = load_json(session_path)
        session_id = session.get("id")
        if not isinstance(session_id, str) or not UUID_RE.fullmatch(session_id):
            raise ValueError("invalid session ID in profile inventory")
        source_session_ids.append(session_id)
        speakers = session.get("speakers", [])
        if not isinstance(speakers, list):
            raise ValueError("invalid speaker state")
        speaker_count += len(speakers)
        for speaker in speakers:
            if not isinstance(speaker, dict):
                raise ValueError("invalid speaker record")
            embedding = speaker.get("diarizationEmbedding")
            if embedding is not None:
                if not isinstance(embedding, list) or not all(
                    isinstance(value, (int, float))
                    and not isinstance(value, bool)
                    and math.isfinite(float(value))
                    for value in embedding
                ):
                    raise ValueError("invalid diarization embedding")
                dimensions.add(len(embedding))
                if embedding:
                    embedding_count += 1
        # The private values participate in the digest but never leave this process.
        projections.append(
            {
                "sessionID": session_id,
                "speakers": speakers,
            }
        )
    return {
        "sourceSessionCount": len(projections),
        "sourceSessionIDs": sorted(source_session_ids),
        "speakerRecordCount": speaker_count,
        "speakerRecordsWithEmbedding": embedding_count,
        "embeddingDimensions": sorted(dimensions),
        "canonicalProfileStateSHA256": canonical_sha256(projections),
        "snapshotSemantics": (
            "Private speaker/profile values remain only in original session manifests; future "
            "quarantine must be an overlay, so rollback removes the overlay and verifies this digest."
        ),
        "duplicatePrivateSnapshotCreated": False,
    }


def recording_inventory(
    sessions_root: Path, annotation: dict[str, Any], annotation_set: str
) -> dict[str, Any]:
    session_id = annotation.get("sessionID")
    if not isinstance(session_id, str) or not UUID_RE.fullmatch(session_id):
        raise ValueError("invalid annotated session ID")
    session_path = safe_child(sessions_root, f"{session_id}/session.json")
    raw, session = load_json(session_path)
    if session.get("id") != session_id:
        raise ValueError("session manifest ID mismatch")
    if session.get("mode") != "onlineCall":
        raise ValueError("playback baseline recording is not an online call")
    audio_tracks = session.get("audioTracks")
    if not isinstance(audio_tracks, list) or len(audio_tracks) != 2:
        raise ValueError("baseline recording must contain exactly two tracks")
    tracks = sorted(
        (track_inventory(session_path.parent, track) for track in audio_tracks),
        key=lambda item: item["kind"],
    )
    topology = topology_for(tracks)
    intervals = annotation.get("intervals")
    if not isinstance(intervals, list) or not intervals:
        raise ValueError("baseline recording has no annotations")
    annotation_counts: dict[str, int] = {}
    for interval in intervals:
        if not isinstance(interval, dict) or not isinstance(interval.get("label"), str):
            raise ValueError("invalid annotation interval")
        start = finite_number(interval.get("start"), "annotation start", minimum=0)
        end = finite_number(interval.get("end"), "annotation end", minimum=0)
        if end <= start:
            raise ValueError("non-positive annotation interval")
        label = interval["label"]
        annotation_counts[label] = annotation_counts.get(label, 0) + 1
    result = {
        "sessionID": session_id,
        "developmentOnly": True,
        "annotationSet": annotation_set,
        "annotationCounts": dict(sorted(annotation_counts.items())),
        "sessionManifestSHA256": sha256_bytes(raw),
        "topology": topology,
        "route": "speakersUserReported" if session_id in CONTROLLED_SPEAKER_SESSIONS else "notPersisted",
        "tracks": tracks,
    }
    result["stage05IneligibilityReasons"] = stage05_reasons(result)
    result["stage05Eligible"] = not result["stage05IneligibilityReasons"]
    return result


def legacy_output_inventory(
    annotations: list[dict[str, Any]],
    legacy_output_root: Path | None,
    frozen_records: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    outputs = []
    names = [annotation.get("sidecar") for annotation in annotations] + [LEGACY_AGGREGATE]
    if legacy_output_root is None and frozen_records is not None:
        if not isinstance(frozen_records, list) or len(frozen_records) != len(names):
            raise ValueError("invalid frozen legacy-output inventory")
        for expected_name, record in zip(names, frozen_records):
            if not isinstance(record, dict) or record.get("basename") != expected_name:
                raise ValueError("frozen legacy-output order/name mismatch")
            digest = record.get("sha256")
            byte_count = record.get("bytes")
            if record.get("availabilityAtFreeze") == "present" and (
                not isinstance(digest, str)
                or not SHA256_RE.fullmatch(digest)
                or not isinstance(byte_count, int)
                or isinstance(byte_count, bool)
                or byte_count <= 0
            ):
                raise ValueError("invalid frozen legacy-output fingerprint")
        return frozen_records
    for name in names:
        if not isinstance(name, str) or Path(name).name != name or name in ("", ".", ".."):
            raise ValueError("unsafe legacy-output basename")
        record: dict[str, Any] = {"basename": name}
        if legacy_output_root is None:
            record["availabilityAtFreeze"] = "notChecked"
        else:
            candidate = legacy_output_root / name
            if candidate.is_file():
                record.update(
                    {
                        "availabilityAtFreeze": "present",
                        "sha256": sha256_file(candidate),
                        "bytes": candidate.stat().st_size,
                    }
                )
            else:
                record["availabilityAtFreeze"] = "missing"
        outputs.append(record)
    return outputs


def build_manifest(
    repo: Path,
    sessions_root: Path,
    annotations_path: Path,
    legacy_output_root: Path | None,
    frozen_at: str,
    frozen_profile_session_ids: list[str] | None = None,
    frozen_legacy_outputs: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    repo = repo.resolve(strict=True)
    sessions_root = sessions_root.resolve(strict=True)
    annotations_path = annotations_path.resolve(strict=True)
    if not isinstance(frozen_at, str) or not ISO8601_UTC_RE.fullmatch(frozen_at):
        raise ValueError("frozen timestamp must be whole-second UTC ISO-8601")
    raw_annotations, annotations = load_json(annotations_path)
    if annotations.get("schemaVersion") != 1 or not isinstance(annotations.get("sessions"), list):
        raise ValueError("unsupported annotation manifest")
    annotation_set = annotations.get("annotationSet")
    if not isinstance(annotation_set, str) or not annotation_set:
        raise ValueError("invalid annotation set")
    recordings = [
        recording_inventory(sessions_root, annotation, annotation_set)
        for annotation in annotations["sessions"]
    ]
    session_ids = [recording["sessionID"] for recording in recordings]
    if len(session_ids) != len(set(session_ids)):
        raise ValueError("duplicate baseline session")
    eligible = sum(recording["stage05Eligible"] for recording in recordings)
    source_files = [
        "MEETING_PLAYBACK_ECHO_CANCELLATION_EXECUTION_PLAN.md",
        "Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift",
        "Sources/Fluid/Services/Meeting/MeetingMicrophoneCapture.swift",
        "Sources/Fluid/Services/Meeting/MeetingModels.swift",
        "Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift",
        "Sources/Fluid/Services/Meeting/MeetingReferenceAttributionContracts.swift",
        "Sources/Fluid/Services/Meeting/MeetingReferenceSynchronizer.swift",
        "tools/MEETING_ADMISSION_B3_DEVELOPMENT_EVAL.md",
        "tools/meeting_admission_b3_annotations.json",
        "tools/meeting_playback_stage0_baseline.py",
    ]
    source_hashes = []
    for relative in source_files:
        path = safe_child(repo, relative)
        source_hashes.append({"path": relative, "sha256": sha256_file(path)})
    return {
        "schemaVersion": 1,
        "frozenAtUTC": frozen_at,
        "scope": "Stage 0 immutable development baseline; no acoustic/AEC claim",
        "privacy": (
            "Hashes and bounded numeric inventory only; no PCM, transcript text, speaker "
            "names/IDs, embeddings, device identifiers, window titles, or absolute paths."
        ),
        "annotations": {
            "schemaVersion": annotations["schemaVersion"],
            "annotationSet": annotation_set,
            "sha256": sha256_bytes(raw_annotations),
            "warning": annotations.get("warning"),
        },
        "sourceArtifacts": source_hashes,
        "recordings": recordings,
        "legacyOutputs": legacy_output_inventory(
            annotations["sessions"], legacy_output_root, frozen_legacy_outputs
        ),
        "profileState": profile_state_inventory(sessions_root, frozen_profile_session_ids),
        "stage05": {
            "eligibleRecordingCount": eligible,
            "ineligibleRecordingCount": len(recordings) - eligible,
            "decision": "proceed" if eligible else "blocked",
            "reason": (
                None
                if eligible
                else "No frozen recording is lossless, raw paired-SCK, route-bound, consent-bound, and independently excitation-annotated."
            ),
            "forbiddenSubstitutes": [
                "C2MetadataOnly",
                "syntheticFIR",
                "VPIOMicrophonePlusExternalReference",
                "frozenInvalidTrialB",
                "unexcitedTrialA",
            ],
            "aec3DependencyAuthorized": False,
        },
        "dispositions": {
            "trialB": "frozenInvalidOrInconclusiveNoFurtherGenericRun",
            "c2": "deliveryMetadataOnlyNoAcousticClaim",
            "trialA": "unexcitedOrPreflightClosedNoAcousticClaim",
            "productionBehaviorChanged": False,
        },
    }


def validate_manifest_shape(manifest: dict[str, Any]) -> None:
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported baseline schema")
    recordings = manifest.get("recordings")
    if not isinstance(recordings, list) or not recordings:
        raise ValueError("empty baseline")
    if any(not recording.get("developmentOnly") for recording in recordings):
        raise ValueError("baseline recording is not development-only")
    stage05 = manifest.get("stage05")
    if not isinstance(stage05, dict) or stage05.get("aec3DependencyAuthorized") is not False:
        raise ValueError("Stage 0 manifest cannot authorize AEC3")
    serialized = json.dumps(manifest, allow_nan=False)
    forbidden = ["transcriptSegments", "diarizationEmbedding", "displayName", "/Users/", "file://"]
    if any(token in serialized for token in forbidden):
        raise ValueError("private or disallowed field leaked into baseline")
    pending = [manifest]
    while pending:
        value = pending.pop()
        if isinstance(value, dict):
            pending.extend(value.keys())
            pending.extend(value.values())
        elif isinstance(value, list):
            pending.extend(value)
        elif isinstance(value, str):
            if value.startswith(("/", "~")) or "://" in value:
                raise ValueError("absolute path or URL leaked into baseline")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--sessions-root", type=Path, required=True)
    parser.add_argument("--annotations", type=Path, required=True)
    parser.add_argument("--legacy-output-root", type=Path)
    parser.add_argument("--frozen-at")
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--output", type=Path)
    destination.add_argument("--verify-manifest", type=Path)
    args = parser.parse_args()
    try:
        frozen_profile_session_ids = None
        frozen_legacy_outputs = None
        frozen_at = args.frozen_at
        expected_existing = None
        if args.verify_manifest is not None:
            _, expected_existing = load_json(args.verify_manifest)
            validate_manifest_shape(expected_existing)
            frozen_at = expected_existing.get("frozenAtUTC")
            profile_state = expected_existing.get("profileState")
            if not isinstance(profile_state, dict) or not isinstance(profile_state.get("sourceSessionIDs"), list):
                raise ValueError("baseline lacks frozen profile-state session IDs")
            frozen_profile_session_ids = profile_state["sourceSessionIDs"]
            frozen_legacy_outputs = expected_existing.get("legacyOutputs")
        if not isinstance(frozen_at, str) or not frozen_at:
            raise ValueError("missing frozen timestamp")
        manifest = build_manifest(
            args.repo,
            args.sessions_root,
            args.annotations,
            args.legacy_output_root,
            frozen_at,
            frozen_profile_session_ids,
            frozen_legacy_outputs,
        )
        validate_manifest_shape(manifest)
        if expected_existing is not None:
            if canonical_sha256(manifest) != canonical_sha256(expected_existing):
                raise ValueError("frozen baseline changed")
            legacy_scope = "including legacy output files" if args.legacy_output_root else "with frozen legacy-output hashes retained"
            print(
                f"Stage 0 baseline verified {legacy_scope}; no private values were emitted"
            )
        else:
            assert args.output is not None
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x", encoding="utf-8") as stream:
                json.dump(manifest, stream, indent=2, sort_keys=True, allow_nan=False)
                stream.write("\n")
            print(
                "Stage 0 baseline written; inputs unchanged; no audio, transcript, profile values, or absolute paths emitted"
            )
    except (OSError, UnicodeError, ValueError, KeyError, TypeError):
        parser.exit(2, "error: Stage 0 baseline failed closed; private input details omitted\n")


if __name__ == "__main__":
    main()
