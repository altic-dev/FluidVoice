#!/usr/bin/env python3
"""Development-only B3 ablation over numeric sidecars and coarse user labels.

Reads transcript text locally only to count whitespace-delimited words. Output never contains
text, speaker IDs, paths, or segment IDs. It does not mutate sessions or choose a threshold.
"""
import argparse
import hashlib
import json
import math
import uuid
from pathlib import Path


LABELS = {"noNearEndSpeech", "coarseNearEndSpeechRegion"}
THRESHOLDS = [0.0] + [round(i / 100, 2) for i in range(1, 11)] + [round(i / 20, 2) for i in range(3, 20)]
REPORT_THRESHOLDS = [0.01, 0.05, 0.10, 0.50, 0.85, 0.95]
EXPECTED_SPEECH_MODEL_FINGERPRINT = "259aec29878cbca1118f4e4fa1db126676286c90b65903266545f50e9ac4512d"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def seconds(stamp):
    if not isinstance(stamp, dict) or not isinstance(stamp.get("value"), (int, float)):
        raise ValueError("invalid timestamp")
    scale = stamp.get("timescale")
    if not isinstance(scale, (int, float)) or scale <= 0:
        raise ValueError("invalid timescale")
    value = stamp["value"] / scale
    if not math.isfinite(value):
        raise ValueError("non-finite timestamp")
    return value


def label_for(start, end, intervals):
    matches = [item["label"] for item in intervals
               if start >= item["start"] and end <= item["end"]]
    return matches[0] if len(matches) == 1 else None


def validate_annotations(payload):
    if payload.get("schemaVersion") != 1 or not isinstance(payload.get("sessions"), list):
        raise ValueError("unsupported annotation schema")
    seen = set()
    for session in payload["sessions"]:
        session_id = session.get("sessionID")
        try:
            canonical_id = str(uuid.UUID(session_id)).upper()
        except (ValueError, TypeError, AttributeError):
            raise ValueError("invalid session ID")
        sidecar = session.get("sidecar")
        if (canonical_id != session_id or session_id in seen or not isinstance(sidecar, str)
                or Path(sidecar).name != sidecar or "/" in sidecar or "\\" in sidecar):
            raise ValueError("invalid or duplicate session")
        seen.add(session_id)
        intervals = session.get("intervals")
        if not isinstance(intervals, list) or not intervals:
            raise ValueError("session requires at least one annotation interval")
        previous_end = -1.0
        for interval in intervals:
            start, end = interval.get("start"), interval.get("end")
            if (not isinstance(start, (int, float)) or not isinstance(end, (int, float))
                    or not math.isfinite(start) or not math.isfinite(end)
                    or start < 0 or end <= start or start < previous_end
                    or interval.get("label") not in LABELS
                    or not isinstance(interval.get("provenance"), str)
                    or not interval["provenance"]):
                raise ValueError("invalid annotation interval")
            previous_end = end
    return payload


def confusion(rows, accept):
    negative = [r for r in rows if r["label"] == "noNearEndSpeech"]
    coarse = [r for r in rows if r["label"] == "coarseNearEndSpeechRegion"]
    false_accept = sum(accept(r) for r in negative)
    accepted_coarse = sum(accept(r) for r in coarse)
    return {
        "negativeMeasuredFrames": len(negative),
        "falseAcceptedNegativeFrames": false_accept,
        "falseAcceptanceFraction": false_accept / len(negative) if negative else None,
        "coarseScriptRegionMeasuredFrames": len(coarse),
        "acceptedCoarseScriptRegionFrames": accepted_coarse,
        "acceptedCoarseScriptRegionFraction": accepted_coarse / len(coarse) if coarse else None,
        "warning": "Coarse-region acceptance is not speech recall; individual speech/pause frames are unlabelled.",
    }


def session_rows(sidecar, intervals):
    samples, rate = sidecar.get("speechFrameSamples"), sidecar.get("speechFrameSampleRate")
    if samples != 4096 or rate != 16000:
        raise ValueError("unexpected speech frame geometry")
    duration = samples / rate
    rows = []
    coverage = {label: {"labelledFrames": 0, "measuredFrames": 0, "unknownFrames": 0}
                for label in LABELS}
    excluded = {"boundaryStraddlingFrames": 0, "outsideAnnotationFrames": 0}
    frames = sidecar.get("speechFrames")
    if not isinstance(frames, list) or not frames:
        raise ValueError("missing speech frames")
    for record in frames:
        frame = record.get("frame", {})
        probability = frame.get("probability")
        unknown = frame.get("unknown")
        start = frame.get("start")
        if not isinstance(start, (int, float)) or not math.isfinite(start):
            raise ValueError("invalid frame start")
        end = start + duration
        label = label_for(start, end, intervals)
        if label is None:
            if any(end > item["start"] and start < item["end"] for item in intervals):
                excluded["boundaryStraddlingFrames"] += 1
            else:
                excluded["outsideAnnotationFrames"] += 1
            continue
        coverage[label]["labelledFrames"] += 1
        if probability is None:
            if not isinstance(unknown, str) or not unknown:
                raise ValueError("missing probability without unknown reason")
            coverage[label]["unknownFrames"] += 1
            continue
        if unknown is not None or not isinstance(probability, (int, float)) or not math.isfinite(probability):
            raise ValueError("invalid measured probability")
        if not 0 <= probability <= 1:
            raise ValueError("probability outside [0,1]")
        temporal = record.get("temporalState")
        if temporal not in {"supported", "notSupported", "mixed", "unavailable"}:
            raise ValueError("unknown temporal state")
        coverage[label]["measuredFrames"] += 1
        rows.append({"label": label, "probability": probability, "temporal": temporal})
    return rows, {"byLabel": coverage, **excluded, "frameDurationSeconds": duration}


def transcript_counts(session, intervals):
    tracks = session.get("audioTracks")
    if not isinstance(tracks, list):
        raise ValueError("invalid tracks")
    mic_ids = [t.get("id") for t in tracks if t.get("kind") == "microphone"]
    if len(mic_ids) != 1:
        raise ValueError("expected one microphone track")
    counts = {label: {"segments": 0, "words": 0, "visibleSegments": 0,
                      "visibleWords": 0, "representedVisibleSpeakers": set()}
              for label in LABELS}
    excluded = {"boundaryStraddlingSegments": 0, "boundaryStraddlingWords": 0,
                "outsideAnnotationSegments": 0, "outsideAnnotationWords": 0}
    for segment in session.get("transcriptSegments", []):
        if segment.get("sourceTrackID") != mic_ids[0]:
            continue
        start, end = seconds(segment.get("start")), seconds(segment.get("end"))
        text = segment.get("text")
        if not isinstance(text, str):
            raise ValueError("invalid transcript text")
        words = len(text.split())
        label = label_for(start, end, intervals)
        if label is None:
            key = "boundaryStraddling" if any(end > item["start"] and start < item["end"] for item in intervals) else "outsideAnnotation"
            excluded[key + "Segments"] += 1
            excluded[key + "Words"] += words
            continue
        item = counts[label]
        item["segments"] += 1
        item["words"] += words
        if not segment.get("isLikelyEcho", False):
            item["visibleSegments"] += 1
            item["visibleWords"] += words
            if segment.get("speakerID") is not None:
                item["representedVisibleSpeakers"].add(segment["speakerID"])
    return {"byLabel": {label: {**values, "representedVisibleSpeakers": len(values["representedVisibleSpeakers"])}
                         for label, values in counts.items()}, "excluded": excluded,
            "warning": "Counts inventory current saved output; coarse-region words are not independently verified and visibility reuses current isLikelyEcho."}


def session_duration(session):
    chunks = [chunk for track in session.get("audioTracks", []) for chunk in track.get("chunks", [])]
    if not chunks:
        raise ValueError("session has no audio chunks")
    starts, ends = [], []
    for chunk in chunks:
        start, end = seconds(chunk.get("presentationStart")), seconds(chunk.get("presentationEnd"))
        if end <= start:
            raise ValueError("invalid chunk interval")
        starts.append(start); ends.append(end)
    return max(ends) - min(starts)


def evaluate(annotation_path, sessions_root, sidecar_root):
    annotations = validate_annotations(json.loads(Path(annotation_path).read_text()))
    all_rows, session_reports = [], []
    model_identity = None
    for item in annotations["sessions"]:
        session_path = Path(sessions_root) / item["sessionID"] / "session.json"
        sidecar_path = Path(sidecar_root) / item["sidecar"]
        session_bytes, sidecar_bytes = session_path.read_bytes(), sidecar_path.read_bytes()
        session, sidecar = json.loads(session_bytes), json.loads(sidecar_bytes)
        if session.get("id") != item["sessionID"]:
            raise ValueError("session ID mismatch")
        session_hash = hashlib.sha256(session_bytes).hexdigest()
        if sidecar.get("sessionSHA256") != session_hash:
            raise ValueError("sidecar/session hash mismatch")
        if sidecar.get("speechAdapterVersion") != "speech-shadow-b2-v1":
            raise ValueError("unexpected speech adapter")
        hashes = sidecar.get("speechModelHashes")
        if (sidecar.get("version") != "temporal-shadow-b1-v1"
                or sidecar.get("speechModelStatus") != "local-cpu-only-silero-256ms-v6; threshold=0.85; warmup=one-frame"
                or sidecar.get("speechDiagnosticThreshold") != 0.85
                or not isinstance(hashes, dict) or not hashes
                or any(not isinstance(key, str) or not key or not isinstance(value, str)
                       or len(value) != 64 or any(c not in "0123456789abcdef" for c in value)
                       for key, value in hashes.items())):
            raise ValueError("unexpected evidence provenance")
        identity = json.dumps(hashes, sort_keys=True, separators=(",", ":"))
        identity_hash = hashlib.sha256(identity.encode()).hexdigest()
        if identity_hash != EXPECTED_SPEECH_MODEL_FINGERPRINT:
            raise ValueError("unpinned speech model artifact")
        if model_identity is not None and identity != model_identity:
            raise ValueError("mixed speech model artifacts")
        model_identity = identity
        duration = sidecar.get("durationSeconds")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration <= 0:
            raise ValueError("invalid sidecar duration")
        if abs(duration - session_duration(session)) > 1e-6:
            raise ValueError("sidecar/session duration mismatch")
        if any(interval["end"] > duration + 1e-6 for interval in item["intervals"]):
            raise ValueError("annotation exceeds recording")
        rows, coverage = session_rows(sidecar, item["intervals"])
        all_rows.extend(rows)
        frame_ablation = {str(threshold): confusion(rows, lambda row, t=threshold: row["probability"] >= t)
                          for threshold in REPORT_THRESHOLDS}
        session_reports.append({
            "sessionIDPrefix": item["sessionID"].split("-")[0] + "…",
            "sessionSHA256": session_hash,
            "sidecarSHA256": hashlib.sha256(sidecar_bytes).hexdigest(),
            "frameCoverage": coverage,
            "currentTranscript": transcript_counts(session, item["intervals"]),
            "speechOnlyFrameAblation": frame_ablation,
        })
    baseline = confusion(all_rows, lambda _: True)
    temporal = confusion(all_rows, lambda row: row["temporal"] != "supported")
    sweeps = []
    for threshold in THRESHOLDS:
        speech = confusion(all_rows, lambda row, t=threshold: row["probability"] >= t)
        # Current data has no supported duplicate. Keep the ablation explicit rather than
        # multiplying correlated scores or inventing a combined confidence.
        combined = confusion(all_rows, lambda row, t=threshold:
                             row["probability"] >= t and row["temporal"] != "supported")
        sweeps.append({"speechThreshold": threshold, "speechOnly": speech,
                       "speechAndNoSupportedDuplicate": combined})
    transcript_aggregate = {label: {"segments": 0, "words": 0, "visibleSegments": 0,
                                    "visibleWords": 0, "representedVisibleSpeakerSlots": 0}
                            for label in sorted(LABELS)}
    for session in session_reports:
        for label, values in session["currentTranscript"]["byLabel"].items():
            for key in ("segments", "words", "visibleSegments", "visibleWords"):
                transcript_aggregate[label][key] += values[key]
            transcript_aggregate[label]["representedVisibleSpeakerSlots"] += values["representedVisibleSpeakers"]
    return {
        "schemaVersion": 1,
        "status": "development-insufficient-for-selection",
        "warning": "Development recordings, correlated 256ms frames, post-hoc user reports, and coarse speech regions; not word accuracy, recall, WER, or held-out evidence.",
        "annotationSHA256": sha256(annotation_path),
        "speechModelFingerprintSHA256": EXPECTED_SPEECH_MODEL_FINGERPRINT,
        "sessionCount": len(session_reports),
        "independentlyFrameLabelledPositiveRecordingCount": 0,
        "recordingsWithCoarseScriptRegion": sum(any(i["label"] == "coarseNearEndSpeechRegion" for i in s["intervals"])
                                                for s in annotations["sessions"]),
        "recordingsWithNegativeIntervals": sum(any(i["label"] == "noNearEndSpeech" for i in s["intervals"])
                                               for s in annotations["sessions"]),
        "pureNegativeRecordingCount": sum(all(i["label"] == "noNearEndSpeech" for i in s["intervals"])
                                          for s in annotations["sessions"]),
        "mixedLabelRecordingCount": sum(len({i["label"] for i in s["intervals"]}) > 1
                                        for s in annotations["sessions"]),
        "baselineAcceptAllMeasuredFrames": baseline,
        "currentTemporalOnly": temporal,
        "thresholdSweeps": sweeps,
        "thresholdSweepPurpose": "Descriptive development tradeoff only; no threshold ranking, candidate list, or selection gate.",
        "selection": None,
        "selectionReason": "No independently frame-labelled positive audio or held-out set; controlled speech regions remain coarse, and there are no supported temporal windows.",
        "sessions": session_reports,
        "currentTranscriptAggregate": transcript_aggregate,
        "privacy": "Output contains hashes and aggregate counts only; no text, speaker IDs, paths, segment IDs, audio, or embeddings.",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotations", required=True)
    parser.add_argument("--sessions-root", required=True)
    parser.add_argument("--sidecar-root", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists():
        raise SystemExit("refusing to overwrite output")
    result = evaluate(args.annotations, args.sessions_root, args.sidecar_root)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Created aggregate-only development evaluation: {output}")


if __name__ == "__main__":
    main()
