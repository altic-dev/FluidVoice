#!/usr/bin/env python3
"""Local-only, deterministic meeting diarization evaluator.

This tool reads RTTM timelines and optional speaker-attributed transcript JSON. It never uploads,
rewrites, or copies source recordings. Reports contain aggregate metrics and file fingerprints only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEPENDENCY_REVISION = "3fd63887eef1dc25edea8263ce4b44aa854d898b"
DIARIZATION_FINGERPRINT = (
    "FluidAudio-offline-v1@3fd63887eef1dc25edea8263ce4b44aa854d898b;"
    "config=community-default-v1"
)


@dataclass(frozen=True)
class Segment:
    speaker: str
    start: float
    end: float


def resolve(base: Path, value: str) -> Path:
    path = Path(os.path.expanduser(value))
    return path if path.is_absolute() else (base / path).resolve()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_rttm(path: Path) -> list[Segment]:
    segments: list[Segment] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            raise ValueError(f"{path}:{line_number}: expected an RTTM SPEAKER row")
        start, duration = float(fields[3]), float(fields[4])
        if start < 0 or duration <= 0 or not math.isfinite(start + duration):
            raise ValueError(f"{path}:{line_number}: invalid start/duration")
        segments.append(Segment(fields[7], start, start + duration))
    if not segments:
        raise ValueError(f"{path}: contains no speaker segments")
    return sorted(segments, key=lambda item: (item.start, item.end, item.speaker))


def active(segments: list[Segment], midpoint: float) -> set[str]:
    return {segment.speaker for segment in segments if segment.start <= midpoint < segment.end}


def scored_intervals(
    reference: list[Segment], hypothesis: list[Segment], collar: float, score_overlap: bool
) -> list[tuple[float, set[str], set[str]]]:
    boundaries = sorted({point for segment in reference + hypothesis for point in (segment.start, segment.end)})
    reference_boundaries = [point for segment in reference for point in (segment.start, segment.end)]
    intervals: list[tuple[float, set[str], set[str]]] = []
    for left, right in zip(boundaries, boundaries[1:]):
        if right <= left:
            continue
        midpoint = (left + right) / 2
        if collar and any(abs(midpoint - point) < collar for point in reference_boundaries):
            continue
        ref_active, hyp_active = active(reference, midpoint), active(hypothesis, midpoint)
        if not score_overlap and len(ref_active) > 1:
            continue
        intervals.append((right - left, ref_active, hyp_active))
    return intervals


def best_assignment(weights: list[list[float]]) -> list[tuple[int, int]]:
    """Maximum-weight one-to-one assignment; corpus speaker counts are intentionally small."""
    rows = len(weights)
    columns = max((len(row) for row in weights), default=0)
    size = max(rows, columns)
    if size > 12:
        raise ValueError("more than 12 speakers is unsupported by the deterministic evaluator")
    padded = [row + [0.0] * (size - len(row)) for row in weights]
    padded += [[0.0] * size for _ in range(size - rows)]
    @lru_cache(maxsize=None)
    def solve(row: int, used_columns: int) -> tuple[float, tuple[int, ...]]:
        if row == size:
            return 0.0, ()
        best: tuple[float, tuple[int, ...]] | None = None
        for column in range(size):
            if used_columns & (1 << column):
                continue
            remaining_score, remaining_columns = solve(row + 1, used_columns | (1 << column))
            candidate = (padded[row][column] + remaining_score, (column,) + remaining_columns)
            if best is None or candidate[0] > best[0]:
                best = candidate
        assert best is not None
        return best

    _, columns_by_row = solve(0, 0)
    return [(row, column) for row, column in enumerate(columns_by_row) if row < rows and column < columns]


def overlap_matrix(
    intervals: list[tuple[float, set[str], set[str]]], references: list[str], hypotheses: list[str]
) -> list[list[float]]:
    matrix = [[0.0 for _ in hypotheses] for _ in references]
    ref_index, hyp_index = {v: i for i, v in enumerate(references)}, {v: i for i, v in enumerate(hypotheses)}
    for duration, ref_active, hyp_active in intervals:
        for ref in ref_active:
            for hyp in hyp_active:
                matrix[ref_index[ref]][hyp_index[hyp]] += duration
    return matrix


def duration_by_speaker(segments: list[Segment]) -> dict[str, float]:
    return {
        speaker: sum(segment.end - segment.start for segment in segments if segment.speaker == speaker)
        for speaker in sorted({segment.speaker for segment in segments})
    }


def score_timeline(reference: list[Segment], hypothesis: list[Segment], collar: float, score_overlap: bool) -> dict[str, Any]:
    intervals = scored_intervals(reference, hypothesis, collar, score_overlap)
    references = sorted({segment.speaker for segment in reference})
    hypotheses = sorted({segment.speaker for segment in hypothesis})
    matrix = overlap_matrix(intervals, references, hypotheses)
    assignment = best_assignment(matrix)
    hyp_to_ref = {hypotheses[column]: references[row] for row, column in assignment}

    reference_time = miss = false_alarm = confusion = 0.0
    for duration, ref_active, hyp_active in intervals:
        reference_time += duration * len(ref_active)
        miss += duration * max(0, len(ref_active) - len(hyp_active))
        false_alarm += duration * max(0, len(hyp_active) - len(ref_active))
        correct = sum(1 for hyp in hyp_active if hyp_to_ref.get(hyp) in ref_active)
        confusion += duration * max(0, min(len(ref_active), len(hyp_active)) - correct)

    ref_durations = duration_by_speaker(reference)
    hyp_durations = duration_by_speaker(hypothesis)
    mapped_column = {row: column for row, column in assignment}
    jaccard_errors, recovered, coverage_and_purity = [], {}, {}
    for row, speaker in enumerate(references):
        column = mapped_column.get(row)
        intersection = matrix[row][column] if column is not None else 0.0
        hyp_duration = hyp_durations.get(hypotheses[column], 0.0) if column is not None else 0.0
        union = ref_durations[speaker] + hyp_duration - intersection
        jaccard_errors.append(1.0 - intersection / union if union else 0.0)
        coverage = intersection / ref_durations[speaker] if ref_durations[speaker] else 0.0
        purity = intersection / hyp_duration if hyp_duration else 0.0
        coverage_and_purity[speaker] = {"coverage": coverage, "purity": purity}
        recovered[speaker] = coverage >= 0.5 and purity >= 0.5

    buckets = {"<1s": [0, 0], "1-3s": [0, 0], "3-10s": [0, 0], ">10s": [0, 0]}
    for speaker, duration in ref_durations.items():
        bucket = "<1s" if duration < 1 else "1-3s" if duration < 3 else "3-10s" if duration < 10 else ">10s"
        buckets[bucket][1] += 1
        buckets[bucket][0] += int(recovered[speaker])

    # A meaningful overlap link is at least 250 ms and at least 5% of the shorter speaker.
    links: list[tuple[int, int]] = []
    for row, ref in enumerate(references):
        for column, hyp in enumerate(hypotheses):
            threshold = max(0.25, 0.05 * min(ref_durations[ref], hyp_durations[hyp]))
            if matrix[row][column] >= threshold:
                links.append((row, column))
    merge_count = sum(1 for column in range(len(hypotheses)) if len({r for r, c in links if c == column}) > 1)
    split_count = sum(1 for row in range(len(references)) if len({c for r, c in links if r == row}) > 1)

    denominator = reference_time or 1.0
    return {
        "collarSeconds": collar,
        "overlapScored": score_overlap,
        "referenceSpeakers": len(references),
        "hypothesisSpeakers": len(hypotheses),
        "speakerCountError": len(hypotheses) - len(references),
        "mergeCount": merge_count,
        "splitCount": split_count,
        "recoveryByDuration": {
            name: {"recovered": values[0], "total": values[1], "recall": values[0] / values[1] if values[1] else None}
            for name, values in buckets.items()
        },
        "der": (miss + false_alarm + confusion) / denominator,
        "derComponents": {
            "miss": miss / denominator,
            "falseAlarm": false_alarm / denominator,
            "confusion": confusion / denominator,
        },
        "jer": sum(jaccard_errors) / len(jaccard_errors) if jaccard_errors else 0.0,
        "speakerCoverageAndPurity": coverage_and_purity,
    }


def words(text: str) -> list[str]:
    return ["".join(character.lower() for character in token if character.isalnum() or character == "'")
            for token in text.split() if any(character.isalnum() for character in token)]


def edit_distance(left: list[str], right: list[str]) -> int:
    row = list(range(len(right) + 1))
    for left_index, left_word in enumerate(left, 1):
        next_row = [left_index]
        for right_index, right_word in enumerate(right, 1):
            next_row.append(min(next_row[-1] + 1, row[right_index] + 1, row[right_index - 1] + (left_word != right_word)))
        row = next_row
    return row[-1]


def cpwer(reference_path: Path, hypothesis_path: Path) -> dict[str, Any]:
    reference = json.loads(reference_path.read_text(encoding="utf-8"))
    hypothesis = json.loads(hypothesis_path.read_text(encoding="utf-8"))
    ref_texts = [words(value) for _, value in sorted(reference.items())]
    hyp_texts = [words(value) for _, value in sorted(hypothesis.items())]
    size = max(len(ref_texts), len(hyp_texts))
    costs = []
    for ref_index in range(size):
        ref_words = ref_texts[ref_index] if ref_index < len(ref_texts) else []
        costs.append([
            edit_distance(ref_words, hyp_texts[hyp_index] if hyp_index < len(hyp_texts) else [])
            for hyp_index in range(size)
        ])
    # Convert minimum-cost assignment into maximum-weight assignment.
    maximum = max((value for row in costs for value in row), default=0)
    assignment = best_assignment([[maximum - value for value in row] for row in costs])
    errors = sum(costs[row][column] for row, column in assignment)
    count = sum(len(value) for value in ref_texts)
    return {"errors": errors, "referenceWords": count, "cpWER": errors / count if count else 0.0}


def validate_manifest(manifest_path: Path, require_files: bool = True) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"schemaVersion must be {SCHEMA_VERSION}")
    dependency = manifest.get("dependency", {})
    if dependency.get("revision") != DEPENDENCY_REVISION:
        raise ValueError("manifest dependency revision does not match the pinned build")
    if dependency.get("diarizationFingerprint") != DIARIZATION_FINGERPRINT:
        raise ValueError("manifest diarization fingerprint does not match the pinned build")
    fixtures = manifest.get("fixtures", [])
    if not fixtures:
        raise ValueError("manifest must contain at least one fixture")
    ids = [fixture.get("id") for fixture in fixtures]
    if any(not value for value in ids) or len(ids) != len(set(ids)):
        raise ValueError("fixture ids must be present and unique")
    if not any(fixture.get("split") == "heldOut" for fixture in fixtures):
        raise ValueError("manifest must define a heldOut fixture before tuning")
    base = manifest_path.parent
    for fixture in fixtures:
        if fixture.get("split") not in ("development", "heldOut"):
            raise ValueError(f"{fixture['id']}: split must be development or heldOut")
        if fixture.get("status", "annotated") == "annotated":
            for key in ("referenceRTTM", "hypothesisRTTM"):
                if key not in fixture:
                    raise ValueError(f"{fixture['id']}: annotated fixture is missing {key}")
                if require_files and not resolve(base, fixture[key]).is_file():
                    raise ValueError(f"{fixture['id']}: missing {key} file")
    return manifest


def score_manifest(manifest_path: Path) -> dict[str, Any]:
    manifest = validate_manifest(manifest_path)
    base, reports = manifest_path.parent, []
    for fixture in manifest["fixtures"]:
        if fixture.get("status", "annotated") != "annotated":
            inventory_report: dict[str, Any] = {
                "id": fixture["id"],
                "split": fixture["split"],
                "status": "inventory",
                "tags": fixture.get("tags", []),
            }
            expected = fixture.get("expectedSpeakerCount")
            observed = fixture.get("observedRemoteSpeakerCount")
            if isinstance(expected, int):
                inventory_report["expectedSpeakerCount"] = expected
            if isinstance(observed, int):
                inventory_report["observedRemoteSpeakerCount"] = observed
            if isinstance(expected, int) and isinstance(observed, int):
                inventory_report["speakerCountError"] = observed - expected
            for manifest_key, report_key in (
                ("hypothesisRTTM", "hypothesisSHA256"),
                ("runReport", "runReportSHA256"),
            ):
                if fixture.get(manifest_key):
                    path = resolve(base, fixture[manifest_key])
                    if path.is_file():
                        inventory_report[report_key] = sha256(path)
            reports.append(inventory_report)
            continue
        reference_path = resolve(base, fixture["referenceRTTM"])
        hypothesis_path = resolve(base, fixture["hypothesisRTTM"])
        reference, hypothesis = read_rttm(reference_path), read_rttm(hypothesis_path)
        report: dict[str, Any] = {
            "id": fixture["id"], "split": fixture["split"], "tags": fixture.get("tags", []),
            "status": "scored", "referenceSHA256": sha256(reference_path),
            "hypothesisSHA256": sha256(hypothesis_path),
            "comparable": score_timeline(reference, hypothesis, 0.25, False),
            "strict": score_timeline(reference, hypothesis, 0.0, True),
        }
        if fixture.get("referenceSpeakerText") and fixture.get("hypothesisSpeakerText"):
            report["cpWER"] = cpwer(resolve(base, fixture["referenceSpeakerText"]), resolve(base, fixture["hypothesisSpeakerText"]))
        reports.append(report)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "dependency": manifest["dependency"],
        "normalization": manifest.get("normalization", {}),
        "fixtures": reports,
    }


def self_test() -> None:
    reference = [Segment("A", 0, 2), Segment("B", 2, 4)]
    perfect = score_timeline(reference, reference, 0, True)
    assert perfect["der"] == 0 and perfect["mergeCount"] == 0 and perfect["splitCount"] == 0
    merged = score_timeline(reference, [Segment("X", 0, 4)], 0, True)
    assert merged["mergeCount"] == 1 and merged["speakerCountError"] == -1 and merged["der"] == 0.5
    split = score_timeline([Segment("A", 0, 4)], [Segment("X", 0, 2), Segment("Y", 2, 4)], 0, True)
    assert split["splitCount"] == 1 and split["speakerCountError"] == 1 and split["der"] == 0.5
    print("meeting_diarization_eval: self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("self-test")
    validate = subparsers.add_parser("validate")
    validate.add_argument("manifest", type=Path)
    score = subparsers.add_parser("score")
    score.add_argument("manifest", type=Path)
    score.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.command == "self-test":
        self_test()
        return 0
    manifest_path = arguments.manifest.resolve()
    if arguments.command == "validate":
        manifest = validate_manifest(manifest_path)
        print(f"valid manifest: {len(manifest['fixtures'])} fixtures")
        return 0
    report = score_manifest(manifest_path)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
        print(arguments.output)
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
