#!/usr/bin/env python3
"""Privacy-safe Stage 0.5 signal-domain gate.

The command accepts only an explicit JSON manifest and private corpus root.  PCM is decoded
transiently for bounded numeric checks; the emitted JSON never contains artifact paths, PCM,
transcripts, labels, or identities.  It intentionally supports PCM WAV only: compressed or
metadata-only inputs fail closed before acoustic evidence is claimed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import statistics
import struct
import sys
import wave
from dataclasses import dataclass
from pathlib import Path

LOSSLESS_CODECS = {"pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"}
MAX_PCM_SAMPLES = 1_000_000
EXPECTED_FIXTURE_SHA256 = "a102f086a6ba1703c13f6a0707ab78c030a167aecf73f317e7b0b73921be861d"
EXPECTED_OPERATOR_MEDIA_FIXTURE_SHA256 = "fbf7a7c40c0a491975de45ff18a7fec7e13135ea01f9821db27f6611ba42eda0"
ALLOWED_PRIVATE_PROVENANCE_FIXTURE_SHA256 = frozenset({
    EXPECTED_FIXTURE_SHA256,
    EXPECTED_OPERATOR_MEDIA_FIXTURE_SHA256,
})
REASONS = ["invalidManifest", "missingConsent", "unsupportedTopology", "unsupportedRoute",
           "nonLossless", "unsupportedCodec", "sourceHashMismatch", "metadataOnly",
           "invalidTiming", "insufficientCoverage", "excessiveDrift", "delayNonCausal",
           "delayOutsideSearchRange", "lowExcitation", "unstablePath", "clipping",
           "linearPathUnlearnable", "referenceScopeLimited", "referenceCompletenessUnobservable",
           "noEligibleSessions", "invalidThresholds", "duplicateOrdinal", "inconsistentGeometry",
           "missingArrivalMetadata", "gapDetected", "overlappingBlocks", "driftUnscored",
           "linearPathUnscored", "delayUnresolved", "insufficientTimingObservations",
           "analysisResourceLimitExceeded"]

DEFAULT_THRESHOLDS = {
    "minimumValidCoverageFraction": 0.99, "maximumDriftPPM": 100.0,
    "maximumUncorrectedOffsetSeconds": 0.020, "maximumRenderLeadSeconds": 0.100,
    "maximumSearchDelaySeconds": 0.500, "safetyMarginSeconds": 0.020,
    "minimumBandCoherence": 0.10, "minimumExcitationRMS": 0.001,
    "maximumClippingFraction": 0.010, "maximumHeldOutLinearResidualFraction": 0.75,
    "maximumIneligibleSessionFraction": 0.25, "minimumExposureSeconds": 1.0,
    "minimumPathStabilityFraction": 0.5, "minimumDelayObservationCount": 3,
    "minimumTimingBlockCount": 3, "maximumPCMSamples": MAX_PCM_SAMPLES,
    "requireDeliveryJitter": True,
}


@dataclass(frozen=True)
class DelayObservation:
    window_center_seconds: float
    acoustic_array_lag_seconds: float
    lag_uncertainty_seconds: float
    absolute_correlation: float
    competitor_correlation: float
    prominence: float


@dataclass(frozen=True)
class DelayEstimate:
    coarse_lag_seconds: float | None
    acoustic_intercept_seconds: float | None
    drift_ppm: float | None
    quantization_bound_ppm: float | None
    observations: tuple[DelayObservation, ...]
    maximum_detrended_residual_seconds: float | None
    failure_category: str | None


@dataclass(frozen=True)
class AlignedSpan:
    render_samples: tuple[float, ...]
    capture_samples: tuple[float, ...]
    valid_support_fraction: float


def threshold_reasons(manifest: dict) -> list[str]:
    values = dict(DEFAULT_THRESHOLDS)
    supplied = manifest.get("thresholds", {})
    if not isinstance(supplied, dict):
        return ["invalidThresholds"]
    if any(key not in values for key in supplied):
        return ["invalidThresholds"]
    values.update(supplied)
    integer_names = {"minimumDelayObservationCount", "minimumTimingBlockCount", "maximumPCMSamples"}
    finite = lambda name: isinstance(values.get(name), (int, float)) and not isinstance(values.get(name), bool) and math.isfinite(float(values[name]))
    if not all(finite(name) for name in values if name != "requireDeliveryJitter") \
            or any(not isinstance(values[name], int) or isinstance(values[name], bool) for name in integer_names):
        return ["invalidThresholds"]
    if not (0 <= values["minimumValidCoverageFraction"] <= 1 and values["maximumDriftPPM"] >= 0
            and values["maximumUncorrectedOffsetSeconds"] >= 0 and values["maximumRenderLeadSeconds"] >= 0
            and values["maximumSearchDelaySeconds"] > 0 and 0 <= values["safetyMarginSeconds"] < values["maximumSearchDelaySeconds"]
            and 0 <= values["minimumBandCoherence"] <= 1 and values["minimumExcitationRMS"] >= 0
            and 0 <= values["maximumClippingFraction"] <= 1 and 0 <= values["maximumHeldOutLinearResidualFraction"] <= 1
            and 0 <= values["maximumIneligibleSessionFraction"] <= 1 and values["minimumExposureSeconds"] > 0
            and 0 <= values["minimumPathStabilityFraction"] <= 1
            and values["minimumDelayObservationCount"] >= 3 and values["minimumTimingBlockCount"] >= 2
            and 1_000 <= values["maximumPCMSamples"] <= MAX_PCM_SAMPLES
            and isinstance(values["requireDeliveryJitter"], bool)):
        return ["invalidThresholds"]
    return []


def safe_relative(value: object) -> bool:
    if not isinstance(value, str) or not value or value.startswith(("/", "~")) or "\\" in value:
        return False
    parts = value.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def has_symlink_component(path: Path) -> bool:
    current = Path(path.anchor or "/")
    for component in path.parts[1:] if path.is_absolute() else path.parts:
        current = current / component
        if current.is_symlink():
            return True
    return False


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = p * (len(ordered) - 1)
    low, high = math.floor(index), math.ceil(index)
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def anti_aliased_downsample(values: list[float], factor: int) -> list[float]:
    """Bound tracker work with a deterministic box low-pass before decimation."""
    if factor <= 1:
        return values
    return [statistics.fmean(values[start:start + factor])
            for start in range(0, len(values), factor)]


def finite_mean_centered(values: list[float]) -> list[float] | None:
    if not values or any(not math.isfinite(value) for value in values):
        return None
    mean = statistics.fmean(values)
    return [value - mean for value in values]


def energy_envelope(values: list[float], sample_rate: float, bin_seconds: float = 0.004) -> tuple[list[float], float] | None:
    if not values or any(not math.isfinite(value) for value in values):
        return None
    if not math.isfinite(sample_rate) or sample_rate <= 0 or not math.isfinite(bin_seconds) or bin_seconds <= 0:
        return None
    width = sample_rate * bin_seconds
    if not math.isfinite(width):
        return None
    bin_size = round(width)
    if bin_size <= 0:
        return None
    complete = len(values) // bin_size
    if complete < 3:
        return None
    envelope = [statistics.fmean(value * value for value in values[start:start + bin_size])
                for start in range(0, complete * bin_size, bin_size)]
    rate = sample_rate / bin_size
    if any(not math.isfinite(energy) for energy in envelope) or not math.isfinite(rate):
        return None
    return envelope, rate


def first_difference(values: list[float]) -> list[float]:
    if len(values) < 2:
        return []
    return [after - before for before, after in zip(values, values[1:])]


def safe_category(value: object, allowed: set[str]) -> str:
    """Keep arbitrary manifest strings out of the aggregate report."""
    return value if isinstance(value, str) and value in allowed else "unknown"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_path(root: Path, item: dict) -> tuple[Path | None, list[str]]:
    reasons: list[str] = []
    relative = item.get("path", item.get("relativePath"))
    if not safe_relative(relative):
        return None, ["invalidManifest"]
    root = root.resolve()
    candidate = root.joinpath(*str(relative).split("/"))
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except (FileNotFoundError, ValueError, OSError):
        return None, ["sourceHashMismatch"]
    if not resolved.is_file():
        return None, ["sourceHashMismatch"]
    cursor = root
    for component in str(relative).split("/"):
        cursor = cursor / component
        if cursor.is_symlink():
            return None, ["sourceHashMismatch"]
    expected = item.get("sha256")
    if not isinstance(expected, str) or len(expected) != 64 or expected != expected.lower() \
            or any(c not in "0123456789abcdef" for c in expected):
        return None, ["invalidManifest"]
    try:
        actual_hash = sha256(resolved)
    except (OSError, ValueError):
        return None, ["sourceHashMismatch"]
    if actual_hash != expected.lower():
        reasons.append("sourceHashMismatch")
    return resolved, reasons


def decode_wav(path: Path, expected_codec: str) -> tuple[list[float], int] | None:
    if expected_codec.lower() not in LOSSLESS_CODECS:
        return None
    if expected_codec.lower() == "pcm_f32le":
        return decode_float_wav(path)
    try:
        with wave.open(str(path), "rb") as stream:
            channels, width, rate, count = stream.getnchannels(), stream.getsampwidth(), stream.getframerate(), stream.getnframes()
            expected_width = {"pcm_s16le": 2, "pcm_s24le": 3, "pcm_s32le": 4}.get(expected_codec.lower())
            if channels != 1 or rate <= 0 or count <= 0 or count > MAX_PCM_SAMPLES \
                    or width not in (2, 3, 4) or expected_width != width:
                return None
            raw = stream.readframes(count)
    except (wave.Error, OSError):
        return None
    values: list[float] = []
    try:
        if width == 2:
            values = [sample / 32768.0 for sample in struct.unpack("<%dh" % (len(raw) // 2), raw)]
        elif width == 3:
            for i in range(0, len(raw), 3):
                value = int.from_bytes(raw[i:i + 3], "little", signed=True)
                values.append(value / 8388608.0)
        elif expected_codec.lower() == "pcm_s32le":
            values = [sample / 2147483648.0 for sample in struct.unpack("<%di" % (len(raw) // 4), raw)]
        else:
            values = [sample / 2147483648.0 for sample in struct.unpack("<%di" % (len(raw) // 4), raw)]
    except struct.error:
        return None
    return (values, rate) if values and all(math.isfinite(value) for value in values) else None


def decode_float_wav(path: Path) -> tuple[list[float], int] | None:
    """Decode only canonical mono IEEE-float WAV (format tag 3), without conversion on write."""
    try:
        raw_file = path.read_bytes()
    except OSError:
        return None
    if len(raw_file) > MAX_PCM_SAMPLES * 4 + 4096 or len(raw_file) < 44:
        return None
    if raw_file[:4] != b"RIFF" or raw_file[8:12] != b"WAVE":
        return None
    offset, fmt, payload = 12, None, None
    while offset + 8 <= len(raw_file):
        chunk_id, chunk_size = raw_file[offset:offset + 4], struct.unpack_from("<I", raw_file, offset + 4)[0]
        start, end = offset + 8, offset + 8 + chunk_size
        if end > len(raw_file):
            return None
        if chunk_id == b"fmt " and fmt is None:
            fmt = raw_file[start:end]
        elif chunk_id == b"data" and payload is None:
            payload = raw_file[start:end]
        offset = end + (chunk_size & 1)
    if fmt is None or payload is None or len(fmt) < 16:
        return None
    audio_format, channels, rate, _, block_align, bits = struct.unpack_from("<HHIIHH", fmt, 0)
    if audio_format != 3 or channels != 1 or rate <= 0 or block_align != 4 or bits != 32 \
            or len(payload) == 0 or len(payload) % 4 != 0 or len(payload) // 4 > MAX_PCM_SAMPLES:
        return None
    try:
        values = list(struct.unpack("<%df" % (len(payload) // 4), payload))
    except struct.error:
        return None
    return (values, rate) if values and all(math.isfinite(value) for value in values) else None


def correlation_at_lag(render: list[float], capture: list[float], lag: int) -> float:
    start_r, start_c = max(0, -lag), max(0, lag)
    n = min(len(render) - start_r, len(capture) - start_c)
    # Tiny overlaps can yield an artificially perfect normalized correlation at the
    # search boundary; require half a window of evidence for every lag candidate.
    if n < max(8, min(len(render), len(capture)) // 2):
        return -1.0
    rr = sum(x * x for x in render[start_r:start_r + n])
    cc = sum(x * x for x in capture[start_c:start_c + n])
    if rr <= 0 or cc <= 0:
        return -1.0
    return sum(render[start_r + i] * capture[start_c + i] for i in range(n)) / math.sqrt(rr * cc)


def normalized_correlation_at_lag(
    render: list[float], capture: list[float], lag: int, minimum_overlap_fraction: float = 0.5
) -> float | None:
    if not isinstance(lag, int) or isinstance(lag, bool):
        return None
    if (not isinstance(minimum_overlap_fraction, (int, float)) or isinstance(minimum_overlap_fraction, bool)
            or not math.isfinite(float(minimum_overlap_fraction))
            or not (0.0 < float(minimum_overlap_fraction) <= 1.0)):
        return None
    try:
        if not render or not capture:
            return None
        if any(not math.isfinite(value) for value in render) or any(not math.isfinite(value) for value in capture):
            return None
    except (TypeError, ValueError):
        return None
    return _normalized_correlation_finite(
        render, capture, lag, float(minimum_overlap_fraction)
    )


def _normalized_correlation_finite(
    render: list[float], capture: list[float], lag: int, minimum_overlap_fraction: float
) -> float | None:
    """Correlation inner loop for inputs validated once by the caller."""
    render_length, capture_length = len(render), len(capture)
    start_r, start_c = max(0, -lag), max(0, lag)
    n = min(render_length - start_r, capture_length - start_c)
    if n < max(8, math.ceil(min(render_length, capture_length) * minimum_overlap_fraction)):
        return None
    rr = cc = cross = 0.0
    for index in range(n):
        render_value = render[start_r + index]
        capture_value = capture[start_c + index]
        rr += render_value * render_value
        cc += capture_value * capture_value
        cross += render_value * capture_value
    if not math.isfinite(rr) or not math.isfinite(cc) or rr <= 0.0 or cc <= 0.0:
        return None
    denominator = math.sqrt(rr * cc)
    if not math.isfinite(denominator) or denominator <= 0.0:
        return None
    correlation = cross / denominator
    if not math.isfinite(correlation):
        return None
    return max(-1.0, min(1.0, correlation))


def prominent_peak(
    render: list[float], capture: list[float], minimum_lag: int, maximum_lag: int, exclusion_radius: int,
    minimum_score: float = 0.10, minimum_prominence: float = 0.05
) -> tuple[int, float, float, float] | None:
    integer = lambda value: isinstance(value, int) and not isinstance(value, bool)
    if not integer(minimum_lag) or not integer(maximum_lag) or not integer(exclusion_radius) or exclusion_radius < 0:
        return None
    if (not isinstance(minimum_score, (int, float)) or isinstance(minimum_score, bool)
            or not isinstance(minimum_prominence, (int, float)) or isinstance(minimum_prominence, bool)
            or not math.isfinite(float(minimum_score)) or not math.isfinite(float(minimum_prominence))
            or float(minimum_score) < 0.0 or float(minimum_prominence) < 0.0):
        return None
    if minimum_lag > maximum_lag:
        return None
    try:
        if not render or not capture \
                or any(not math.isfinite(value) for value in render) \
                or any(not math.isfinite(value) for value in capture):
            return None
    except (TypeError, ValueError):
        return None
    candidates: list[tuple[int, float]] = []
    for lag in range(minimum_lag, maximum_lag + 1):
        score = _normalized_correlation_finite(render, capture, lag, 0.5)
        if score is None:
            continue
        candidates.append((lag, abs(score)))
    if not candidates:
        return None
    best_lag, best_abs = max(candidates, key=lambda item: (item[1], -item[0]))
    if best_lag == minimum_lag or best_lag == maximum_lag:
        return None
    competitors = [score for lag, score in candidates if abs(lag - best_lag) > exclusion_radius]
    if not competitors:
        return None
    competitor_abs = max(competitors)
    prominence = best_abs - competitor_abs
    if (not math.isfinite(best_abs) or not math.isfinite(competitor_abs) or not math.isfinite(prominence)
            or best_abs < float(minimum_score) or prominence < float(minimum_prominence)):
        return None
    return (best_lag, best_abs, competitor_abs, prominence)


def refine_native_lag(
    render: list[float], capture: list[float], reduced_lag: int, reduced_rate: float, native_rate: float
) -> tuple[float, float] | None:
    integer = lambda value: isinstance(value, int) and not isinstance(value, bool)
    finite_positive = lambda value: (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and math.isfinite(float(value)) and float(value) > 0.0
    )
    if not integer(reduced_lag) or not finite_positive(reduced_rate) or not finite_positive(native_rate):
        return None
    reduced_rate, native_rate = float(reduced_rate), float(native_rate)
    if native_rate < reduced_rate:
        return None
    try:
        if not render or not capture:
            return None
        if any(not math.isfinite(value) for value in render) or any(not math.isfinite(value) for value in capture):
            return None
    except (TypeError, ValueError):
        return None
    scale = native_rate / reduced_rate
    center = reduced_lag * scale
    if not math.isfinite(scale) or not math.isfinite(center) or scale < 1.0:
        return None
    # A three-second window at the accepted drift ceiling can spread a box-decimated
    # peak across adjacent 4 kHz bins. Search three bins, then require an interior
    # native-rate maximum; periodic alternatives were already rejected above.
    radius = math.ceil(3.0 * scale)
    minimum_lag, maximum_lag = math.ceil(center - radius), math.floor(center + radius)
    if not integer(minimum_lag) or not integer(maximum_lag) or minimum_lag > maximum_lag:
        return None
    candidates: list[tuple[int, float]] = []
    for lag in range(minimum_lag, maximum_lag + 1):
        score = _normalized_correlation_finite(render, capture, lag, 0.5)
        if score is None or not math.isfinite(score):
            return None
        candidates.append((lag, abs(score)))
    best_lag, best_abs = max(candidates, key=lambda item: (item[1], -item[0]))
    if best_lag == minimum_lag or best_lag == maximum_lag:
        return None
    by_lag = {lag: score for lag, score in candidates}
    left, right = by_lag[best_lag - 1], by_lag[best_lag + 1]
    curvature = left - 2.0 * best_abs + right
    if (math.isfinite(left) and math.isfinite(right) and math.isfinite(best_abs)
            and math.isfinite(curvature) and curvature < 0.0):
        offset = (left - right) / (2.0 * curvature)
        refined = float(best_lag) if not math.isfinite(offset) else best_lag + max(-0.5, min(0.5, offset))
    else:
        refined = float(best_lag)
    lag_seconds = refined / native_rate
    uncertainty_seconds = 0.5 / native_rate
    if not math.isfinite(lag_seconds) or not math.isfinite(uncertainty_seconds):
        return None
    return (lag_seconds, max(uncertainty_seconds, 0.5 / native_rate))


def global_delay_anchor(
    render: list[float], capture: list[float], sample_rate: float, maximum_delay_seconds: float
) -> tuple[float, DelayObservation] | None:
    """Resolve one full-span coarse/fine/native acoustic-lag anchor."""
    numeric = lambda value: (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and math.isfinite(float(value))
    )
    if (not numeric(sample_rate) or float(sample_rate) <= 0.0
            or not numeric(maximum_delay_seconds) or float(maximum_delay_seconds) <= 0.0):
        return None
    common_count = min(len(render), len(capture))
    if common_count < 16 or common_count > MAX_PCM_SAMPLES:
        return None
    native_rate = float(sample_rate)
    maximum_delay_seconds = float(maximum_delay_seconds)
    centered_render = finite_mean_centered(render[:common_count])
    centered_capture = finite_mean_centered(capture[:common_count])
    if centered_render is None or centered_capture is None:
        return None

    render_envelope = energy_envelope(centered_render, native_rate)
    capture_envelope = energy_envelope(centered_capture, native_rate)
    if render_envelope is None or capture_envelope is None:
        return None
    envelope_render, envelope_rate = render_envelope
    envelope_capture, capture_envelope_rate = capture_envelope
    if abs(envelope_rate - capture_envelope_rate) > max(1e-9, envelope_rate * 1e-12):
        return None
    envelope_render = finite_mean_centered(envelope_render)
    envelope_capture = finite_mean_centered(envelope_capture)
    if envelope_render is None or envelope_capture is None:
        return None
    coarse_limit = math.ceil(maximum_delay_seconds * envelope_rate)
    if coarse_limit <= 1:
        return None
    coarse_peak = prominent_peak(
        envelope_render, envelope_capture, -coarse_limit, coarse_limit, 1
    )
    if coarse_peak is None:
        return None
    coarse_lag, coarse_score, coarse_competitor, coarse_prominence = coarse_peak
    coarse_lag_seconds = coarse_lag / envelope_rate

    factor = max(1, math.ceil(native_rate / 4_000.0))
    reduced_rate = native_rate / factor
    reduced_render = first_difference(anti_aliased_downsample(centered_render, factor))
    reduced_capture = first_difference(anti_aliased_downsample(centered_capture, factor))
    if len(reduced_render) < 16 or len(reduced_capture) < 16:
        return None
    reduced_limit = math.ceil(maximum_delay_seconds * reduced_rate)
    fine_radius = max(1, math.ceil(0.012 * reduced_rate))
    fine_center = round(coarse_lag_seconds * reduced_rate)
    fine_minimum = max(-reduced_limit, fine_center - fine_radius)
    fine_maximum = min(reduced_limit, fine_center + fine_radius)
    fine_exclusion = max(1, math.ceil(0.010 * reduced_rate))
    fine_peak = prominent_peak(
        reduced_render, reduced_capture, fine_minimum, fine_maximum, fine_exclusion
    )
    if fine_peak is None:
        return None
    fine_lag, fine_score, fine_competitor, fine_prominence = fine_peak
    fine_lag_seconds = fine_lag / reduced_rate
    envelope_bin_seconds = 1.0 / envelope_rate
    if abs(fine_lag_seconds - coarse_lag_seconds) > envelope_bin_seconds:
        return None

    common_seconds = common_count / native_rate
    native_window_count = round(min(3.0, common_seconds / 2.0) * native_rate)
    if native_window_count < 16:
        return None
    native_start = (common_count - native_window_count) // 2
    native_stop = native_start + native_window_count
    native_render = first_difference(centered_render[native_start:native_stop])
    native_capture = first_difference(centered_capture[native_start:native_stop])
    native_refinement = refine_native_lag(
        native_render, native_capture, fine_lag, reduced_rate, native_rate
    )
    if native_refinement is None:
        return None
    native_lag_seconds, native_uncertainty_seconds = native_refinement
    if (abs(native_lag_seconds) >= maximum_delay_seconds
            or abs(native_lag_seconds - coarse_lag_seconds) > envelope_bin_seconds):
        return None
    observation = DelayObservation(
        window_center_seconds=(native_start + native_window_count / 2.0) / native_rate,
        acoustic_array_lag_seconds=native_lag_seconds,
        lag_uncertainty_seconds=native_uncertainty_seconds,
        absolute_correlation=fine_score,
        competitor_correlation=fine_competitor,
        prominence=fine_prominence,
    )
    if not all(math.isfinite(value) for value in (
        coarse_lag_seconds,
        observation.window_center_seconds,
        observation.acoustic_array_lag_seconds,
        observation.lag_uncertainty_seconds,
        observation.absolute_correlation,
        observation.competitor_correlation,
        observation.prominence,
    )):
        return None
    return coarse_lag_seconds, observation


def failed_delay_estimate(
    category: str, coarse_lag_seconds: float | None = None
) -> DelayEstimate:
    """Build a fail-closed estimate with no usable downstream timing facts."""
    return DelayEstimate(
        coarse_lag_seconds=coarse_lag_seconds,
        acoustic_intercept_seconds=None,
        drift_ppm=None,
        quantization_bound_ppm=None,
        observations=(),
        maximum_detrended_residual_seconds=None,
        failure_category=category,
    )


def estimate_delay(
    render: list[float], capture: list[float], sample_rate: float, thresholds: dict
) -> DelayEstimate:
    """Estimate a full-support affine acoustic lag or return an unscored failure."""
    required = (
        "maximumSearchDelaySeconds",
        "maximumDriftPPM",
        "maximumUncorrectedOffsetSeconds",
        "minimumPathStabilityFraction",
    )
    if (not isinstance(thresholds, dict)
            or any(not isinstance(thresholds.get(key), (int, float))
                   or isinstance(thresholds.get(key), bool)
                   or not math.isfinite(float(thresholds[key])) for key in required)
            or not isinstance(sample_rate, (int, float)) or isinstance(sample_rate, bool)
            or not math.isfinite(float(sample_rate)) or float(sample_rate) <= 0.0):
        return failed_delay_estimate("delayUnresolved")
    native_rate = float(sample_rate)
    maximum_delay = float(thresholds["maximumSearchDelaySeconds"])
    maximum_drift = float(thresholds["maximumDriftPPM"])
    maximum_residual = float(thresholds["maximumUncorrectedOffsetSeconds"])
    minimum_stability = float(thresholds["minimumPathStabilityFraction"])
    if (maximum_delay <= 0.0 or maximum_drift < 0.0 or maximum_residual < 0.0
            or not 0.0 <= minimum_stability <= 1.0):
        return failed_delay_estimate("delayUnresolved")

    anchor = global_delay_anchor(render, capture, native_rate, maximum_delay)
    if anchor is None:
        return failed_delay_estimate("delayUnresolved")
    coarse_lag_seconds, anchor_observation = anchor
    common_count = min(len(render), len(capture))
    centered_render = finite_mean_centered(render[:common_count])
    centered_capture = finite_mean_centered(capture[:common_count])
    if centered_render is None or centered_capture is None:
        return failed_delay_estimate("delayUnresolved", coarse_lag_seconds)
    factor = max(1, math.ceil(native_rate / 4_000.0))
    reduced_rate = native_rate / factor
    reduced_render = first_difference(anti_aliased_downsample(centered_render, factor))
    reduced_capture = first_difference(anti_aliased_downsample(centered_capture, factor))
    native_render = first_difference(centered_render)
    native_capture = first_difference(centered_capture)
    reduced_count = min(len(reduced_render), len(reduced_capture))
    common_seconds = common_count / native_rate
    window_seconds = min(3.0, common_seconds / 2.0)
    window_count = round(window_seconds * reduced_rate)
    local_radius = max(1, math.ceil(0.024 * reduced_rate))
    local_exclusion = max(1, math.ceil(0.010 * reduced_rate))
    minimum_geometry = max(256, 2 * local_radius + 2 * local_exclusion + 3)
    if window_count < minimum_geometry or reduced_count < window_count:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)
    available = reduced_count - window_count
    scheduled_count = min(8, available + 1)
    if scheduled_count < 5:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)
    starts = sorted({
        round(index * available / (scheduled_count - 1))
        for index in range(scheduled_count)
    })
    if len(starts) != scheduled_count or starts[0] != 0 or starts[-1] != available:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)

    reduced_limit = math.ceil(maximum_delay * reduced_rate)
    expected_lag = round(anchor_observation.acoustic_array_lag_seconds * reduced_rate)
    observations: list[DelayObservation] = []
    for start in starts:
        window_render = reduced_render[start:start + window_count]
        window_capture = reduced_capture[start:start + window_count]
        minimum_lag = max(-reduced_limit, expected_lag - local_radius)
        maximum_lag = min(reduced_limit, expected_lag + local_radius)
        local_peak = prominent_peak(
            window_render,
            window_capture,
            minimum_lag,
            maximum_lag,
            local_exclusion,
        )
        if local_peak is None:
            return failed_delay_estimate("delayUnresolved", coarse_lag_seconds)
        reduced_lag, score, competitor, prominence = local_peak
        native_start = start * factor
        native_stop = min(len(native_render), (start + window_count + 1) * factor)
        local_native_render = native_render[native_start:native_stop]
        local_native_capture = native_capture[native_start:native_stop]
        refinement = refine_native_lag(
            local_native_render,
            local_native_capture,
            reduced_lag,
            reduced_rate,
            native_rate,
        )
        if refinement is None:
            return failed_delay_estimate("delayUnresolved", coarse_lag_seconds)
        lag_seconds, uncertainty_seconds = refinement
        if abs(lag_seconds) >= maximum_delay:
            return failed_delay_estimate("delayUnresolved", coarse_lag_seconds)
        observations.append(DelayObservation(
            window_center_seconds=(start + window_count / 2.0) / reduced_rate,
            acoustic_array_lag_seconds=lag_seconds,
            lag_uncertainty_seconds=uncertainty_seconds,
            absolute_correlation=score,
            competitor_correlation=competitor,
            prominence=prominence,
        ))

    observation_span = observations[-1].window_center_seconds - observations[0].window_center_seconds
    if observation_span <= 0.0:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)
    quantization_bound_ppm = (1.0 / native_rate) / observation_span * 1_000_000.0
    if not math.isfinite(quantization_bound_ppm) or quantization_bound_ppm > maximum_drift:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)

    minimum_pair_span = observation_span / 2.0
    slopes: list[float] = []
    for left_index, left in enumerate(observations):
        for right in observations[left_index + 1:]:
            delta_time = right.window_center_seconds - left.window_center_seconds
            if delta_time + 1e-12 < minimum_pair_span:
                continue
            slope_ppm = (
                (right.acoustic_array_lag_seconds - left.acoustic_array_lag_seconds)
                / delta_time * 1_000_000.0
            )
            uncertainty_ppm = (
                (left.lag_uncertainty_seconds + right.lag_uncertainty_seconds)
                / delta_time * 1_000_000.0
            )
            if (not math.isfinite(slope_ppm) or not math.isfinite(uncertainty_ppm)
                    or uncertainty_ppm < 0.0):
                return failed_delay_estimate("driftUnscored", coarse_lag_seconds)
            slopes.append(slope_ppm)
            if abs(slope_ppm) + uncertainty_ppm > maximum_drift:
                return failed_delay_estimate("excessiveDrift", coarse_lag_seconds)
    if len(slopes) < 3:
        return failed_delay_estimate("driftUnscored", coarse_lag_seconds)

    drift_ppm = statistics.median(slopes)
    drift_fraction = drift_ppm / 1_000_000.0
    intercepts = [
        observation.acoustic_array_lag_seconds
        - drift_fraction * observation.window_center_seconds
        for observation in observations
    ]
    acoustic_intercept_seconds = statistics.median(intercepts)
    residuals = [
        abs(observation.acoustic_array_lag_seconds
            - (acoustic_intercept_seconds
               + drift_fraction * observation.window_center_seconds))
        for observation in observations
    ]
    maximum_detrended_residual = max(residuals)
    if (not all(math.isfinite(value) for value in (
            drift_ppm,
            acoustic_intercept_seconds,
            maximum_detrended_residual,
    )) or maximum_detrended_residual > maximum_residual):
        return failed_delay_estimate("excessiveDrift", coarse_lag_seconds)
    stability_tolerance = max(
        1.0 / native_rate,
        abs(acoustic_intercept_seconds) * 0.10,
    )
    stability = sum(value <= stability_tolerance for value in residuals) / len(residuals)
    if stability < minimum_stability:
        return failed_delay_estimate("unstablePath", coarse_lag_seconds)
    return DelayEstimate(
        coarse_lag_seconds=coarse_lag_seconds,
        acoustic_intercept_seconds=acoustic_intercept_seconds,
        drift_ppm=drift_ppm,
        quantization_bound_ppm=quantization_bound_ppm,
        observations=tuple(observations),
        maximum_detrended_residual_seconds=maximum_detrended_residual,
        failure_category=None,
    )


def align_affine_support(
    render: list[float], capture: list[float], sample_rate: float, estimate: DelayEstimate
) -> AlignedSpan | None:
    """Align capture to an evidenced affine render lag without synthesizing edge support."""
    if (estimate.failure_category is not None
            or estimate.acoustic_intercept_seconds is None
            or estimate.drift_ppm is None
            or not isinstance(sample_rate, (int, float)) or isinstance(sample_rate, bool)
            or not math.isfinite(float(sample_rate)) or float(sample_rate) <= 0.0
            or not render or not capture
            or len(render) > MAX_PCM_SAMPLES or len(capture) > MAX_PCM_SAMPLES
            or any(not math.isfinite(value) for value in render)
            or any(not math.isfinite(value) for value in capture)):
        return None
    native_rate = float(sample_rate)
    intercept = float(estimate.acoustic_intercept_seconds)
    drift_fraction = float(estimate.drift_ppm) / 1_000_000.0
    if not math.isfinite(intercept) or not math.isfinite(drift_fraction):
        return None
    aligned_render: list[float] = []
    aligned_capture: list[float] = []
    previous_capture_index: int | None = None
    for capture_index, capture_sample in enumerate(capture):
        capture_seconds = capture_index / native_rate
        lag_samples = (intercept + drift_fraction * capture_seconds) * native_rate
        render_position = capture_index - lag_samples
        if not math.isfinite(render_position):
            return None
        lower = math.floor(render_position)
        fraction = render_position - lower
        if lower < 0 or lower >= len(render):
            continue
        if fraction > 1e-12:
            if lower + 1 >= len(render):
                continue
            render_sample = render[lower] * (1.0 - fraction) + render[lower + 1] * fraction
        else:
            render_sample = render[lower]
        if not math.isfinite(render_sample):
            return None
        if previous_capture_index is not None and capture_index != previous_capture_index + 1:
            # Affine support at the registered drift bound must be one contiguous interval.
            return None
        previous_capture_index = capture_index
        aligned_render.append(render_sample)
        aligned_capture.append(capture_sample)
    denominator = max(len(render), len(capture))
    if len(aligned_render) < 8 or denominator <= 0:
        return None
    support = len(aligned_render) / denominator
    if not math.isfinite(support) or not 0.0 <= support <= 1.0:
        return None
    return AlignedSpan(tuple(aligned_render), tuple(aligned_capture), support)


def signed_delay_contract(
    estimate: DelayEstimate, pts_offset_seconds: float, render_lead_seconds: float, thresholds: dict
) -> tuple[tuple[float, ...], str | None]:
    """Apply clock-domain offsets exactly once after acoustic evidence exists."""
    if estimate.failure_category is not None:
        return (), None
    numeric = lambda value: (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and math.isfinite(float(value))
    )
    if (not numeric(pts_offset_seconds) or not numeric(render_lead_seconds)
            or not isinstance(thresholds, dict)
            or not numeric(thresholds.get("maximumSearchDelaySeconds"))
            or not numeric(thresholds.get("safetyMarginSeconds"))):
        return (), "delayUnresolved"
    signed = tuple(
        observation.acoustic_array_lag_seconds
        + float(pts_offset_seconds)
        + float(render_lead_seconds)
        for observation in estimate.observations
    )
    if not signed or any(not math.isfinite(value) for value in signed):
        return (), "delayUnresolved"
    safety_margin = float(thresholds["safetyMarginSeconds"])
    maximum_delay = float(thresholds["maximumSearchDelaySeconds"])
    if min(signed) < -safety_margin:
        return (), "delayNonCausal"
    if max(signed) > maximum_delay - safety_margin:
        return (), "delayOutsideSearchRange"
    return signed, None


def band_measures(render: list[float], capture: list[float], rate: float) -> tuple[list[float], list[float]]:
    """Estimate magnitude-squared coherence over deterministic full-rate windows.

    For each band/frequency, complex cross-spectrum contributions are accumulated across
    windows before normalization. The caller aligns the two streams by the measured lag,
    so this quantity describes path coherence rather than a lag artifact.
    """
    n = min(len(render), len(capture))
    window = 4_096
    if n < 8:
        return [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]
    bands = ([250.0, 500.0], [750.0, 1_000.0, 1_500.0], [2_500.0, 4_000.0, 6_000.0])
    coherences, powers = [], []
    for frequencies in bands:
        frequency_coherences, frequency_powers = [], []
        for frequency in frequencies:
            if frequency >= rate / 2:
                continue
            cross_real = cross_imag = render_power = capture_power = 0.0
            power_normalization = 0.0
            for start in range(0, n - 7, window):
                stop = min(start + window, n)
                block_render, block_capture = render[start:stop], capture[start:stop]
                render_mean, capture_mean = statistics.fmean(block_render), statistics.fmean(block_capture)
                theta = 2 * math.pi * frequency / rate
                step_cos, step_sin = math.cos(theta), math.sin(theta)
                cos_value, sin_value = 1.0, 0.0
                xr = xi = yr = yi = 0.0
                for x0, y0 in zip(block_render, block_capture):
                    x, y = x0 - render_mean, y0 - capture_mean
                    xr += x * cos_value; xi -= x * sin_value
                    yr += y * cos_value; yi -= y * sin_value
                    cos_value, sin_value = (cos_value * step_cos - sin_value * step_sin,
                                            sin_value * step_cos + cos_value * step_sin)
                cross_real += xr * yr + xi * yi
                cross_imag += xi * yr - xr * yi
                render_power += xr * xr + xi * xi
                capture_power += yr * yr + yi * yi
                power_normalization += len(block_render) * len(block_render)
            denominator = render_power * capture_power
            if denominator > 0:
                frequency_coherences.append(max(0.0, min(1.0, (cross_real * cross_real + cross_imag * cross_imag) / denominator)))
                # For a real sinusoid, 2|X|^2/N^2 is its mean-square power.
                # Normalize each accumulated window by the corresponding N^2;
                # dividing by the complete recording length squared makes power
                # shrink merely because more windows were observed.
                frequency_powers.append(2 * render_power / max(1.0, power_normalization))
        coherences.append(statistics.fmean(frequency_coherences) if frequency_coherences else 0.0)
        powers.append(statistics.fmean(frequency_powers) if frequency_powers else 0.0)
    return coherences, powers


def timing_reasons(
    blocks: object, require_arrival: bool, minimum_block_count: int = 2
) -> tuple[list[str], float | None, float | None, int]:
    if not isinstance(blocks, list) or not blocks:
        return ["metadataOnly"], None, None, 0
    reasons: list[str] = []
    if require_arrival and len(blocks) < minimum_block_count:
        reasons.append("insufficientTimingObservations")
    exposure = 0.0
    rate: float | None = None
    frame_total = 0
    previous = None
    for block in blocks:
        if not isinstance(block, dict):
            reasons.append("invalidTiming")
            continue
        pts, duration, samples = block.get("presentationSeconds"), block.get("durationSeconds"), block.get("frameCount")
        if not all(isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)) for value in (pts, duration)) \
                or not isinstance(samples, int) or isinstance(samples, bool) or duration <= 0 or samples <= 0:
            reasons.append("invalidTiming")
            continue
        block_rate = float(samples) / float(duration)
        if rate is None: rate = block_rate
        elif abs(block_rate - rate) > max(1e-6, rate * 1e-6): reasons.append("inconsistentGeometry")
        exposure += float(duration)
        frame_total += int(samples)
        arrival = block.get("arrivalSeconds")
        if require_arrival and (not isinstance(arrival, (int, float)) or isinstance(arrival, bool)
                                or not math.isfinite(float(arrival))):
            reasons.append("missingArrivalMetadata")
        if previous is not None:
            delta = float(pts) - previous[0]
            tolerance = max(1e-9, 1.0 / max(rate or 1.0, 1.0))
            if delta - previous[1] > tolerance: reasons.append("gapDetected")
            if delta - previous[1] < -tolerance: reasons.append("overlappingBlocks")
            if isinstance(arrival, (int, float)) and not isinstance(arrival, bool) \
                    and isinstance(previous[2], (int, float)) and float(arrival) < float(previous[2]):
                reasons.append("invalidTiming")
        previous = (float(pts), float(duration), arrival)
    return list(dict.fromkeys(reasons)), exposure, rate, frame_total


def timing_metrics(blocks: object) -> tuple[float | None, list[float]]:
    if not isinstance(blocks, list) or not blocks:
        return None, []
    ordered = sorted((block for block in blocks if isinstance(block, dict)), key=lambda block: block.get("presentationSeconds", 0))
    if not ordered:
        return None, []
    first = float(ordered[0]["presentationSeconds"]); last = ordered[-1]
    span = float(last["presentationSeconds"]) + float(last["durationSeconds"]) - first
    duration = sum(float(block["durationSeconds"]) for block in ordered)
    coverage = duration / span if span > 0 else None
    jitter = []
    for previous, current in zip(ordered, ordered[1:]):
        if isinstance(previous.get("arrivalSeconds"), (int, float)) and isinstance(current.get("arrivalSeconds"), (int, float)):
            presentation_delta = float(current["presentationSeconds"]) - float(previous["presentationSeconds"])
            jitter.append(abs((float(current["arrivalSeconds"]) - float(previous["arrivalSeconds"])) - presentation_delta))
    return (min(1.0, max(0.0, coverage)) if coverage is not None else None), jitter


def held_out_linear_residual(render: list[float], capture: list[float], rate: int) -> float | None:
    """Fit a bounded linear path and score disjoint validation and held-out regions."""
    n = min(len(render), len(capture))
    if n < 512 or rate <= 0:
        return None
    if n > MAX_PCM_SAMPLES or any(not math.isfinite(value) for value in render[:n]) \
            or any(not math.isfinite(value) for value in capture[:n]):
        return None
    factor = max(1, math.ceil(rate / 4_000))
    x = anti_aliased_downsample(render[:n], factor)
    y = anti_aliased_downsample(capture[:n], factor)
    reduced_rate = rate / factor
    tap_count = min(256, max(16, int(math.ceil(0.064 * reduced_rate))))
    n = min(len(x), len(y))
    usable_start = tap_count - 1
    usable_count = n - usable_start
    train_count = usable_count // 2
    validation_count = usable_count // 4
    held_out_count = usable_count - train_count - validation_count
    if min(train_count, validation_count, held_out_count) <= 64:
        return None
    train_start = usable_start
    train_stop = train_start + train_count
    validation_start = train_stop
    validation_stop = validation_start + validation_count
    held_out_start = validation_stop

    render_mean = statistics.fmean(x[train_start:train_stop])
    capture_mean = statistics.fmean(y[train_start:train_stop])
    x = [value - render_mean for value in x]
    y = [value - capture_mean for value in y]
    if any(not math.isfinite(value) for value in x) or any(not math.isfinite(value) for value in y):
        return None
    coefficients = [0.0] * tap_count
    for step_size in (0.50, 0.25, 0.125):
        for index in range(train_start, train_stop):
            vector = x[index - tap_count + 1:index + 1]
            reversed_vector = list(reversed(vector))
            norm = 1e-8 + sum(value * value for value in reversed_vector)
            prediction = sum(weight * value for weight, value in zip(coefficients, reversed_vector))
            error = y[index] - prediction
            scale = step_size * error / norm
            for tap, value in enumerate(reversed_vector):
                coefficients[tap] += scale * value
        if any(not math.isfinite(value) for value in coefficients):
            return None

    def score(start: int, stop: int) -> float | None:
        error_energy = target_energy = 0.0
        observations = 0
        for index in range(start, stop):
            vector = reversed(x[index - tap_count + 1:index + 1])
            prediction = sum(weight * value for weight, value in zip(coefficients, vector))
            error = y[index] - prediction
            error_energy += error * error
            target_energy += y[index] * y[index]
            observations += 1
        if (observations <= 64 or target_energy <= 1e-12
                or not math.isfinite(error_energy) or not math.isfinite(target_energy)):
            return None
        return min(1.0, max(0.0, error_energy / target_energy))

    validation_residual = score(validation_start, validation_stop)
    held_out_residual = score(held_out_start, n)
    if validation_residual is None or held_out_residual is None:
        return None
    return max(validation_residual, held_out_residual)


def measure(render: list[float], capture: list[float], rate: int, thresholds: dict,
            ordinal: int, exposure: float | None, pts_offset: float = 0.0,
            render_lead: float = 0.0) -> dict:
    """Measure one session without allowing an unscored dependency to authorize it."""
    full_n = min(len(render), len(capture), MAX_PCM_SAMPLES)
    full_render, full_capture = render[:full_n], capture[:full_n]
    estimate = estimate_delay(full_render, full_capture, rate, thresholds)
    observations = list(estimate.observations)
    acoustic_delays = [item.acoustic_array_lag_seconds for item in observations]
    signed_values, signed_clock_failure = signed_delay_contract(
        estimate, pts_offset, render_lead, thresholds
    )
    signed_delays = list(signed_values)

    alignment = (
        align_affine_support(full_render, full_capture, rate, estimate)
        if estimate.failure_category is None and signed_clock_failure is None
        else None
    )
    aligned_render = list(alignment.render_samples) if alignment is not None else []
    aligned_capture = list(alignment.capture_samples) if alignment is not None else []
    coherence, power = (
        band_measures(aligned_render, aligned_capture, rate)
        if alignment is not None
        else (None, None)
    )
    rms = math.sqrt(sum(x * x for x in full_render) / len(full_render)) if full_render else 0.0
    clipping = sum(abs(x) >= 0.999 for x in full_render + full_capture) / max(1, len(full_render) + len(full_capture))
    residual = (
        held_out_linear_residual(aligned_render, aligned_capture, rate)
        if alignment is not None
        else None
    )

    long_slopes: list[float] = []
    path_stability: float | None = None
    delay_range: float | None = None
    if len(observations) >= 2 and estimate.acoustic_intercept_seconds is not None \
            and estimate.drift_ppm is not None:
        observation_span = observations[-1].window_center_seconds - observations[0].window_center_seconds
        minimum_pair_span = observation_span / 2.0
        for left_index, left in enumerate(observations):
            for right in observations[left_index + 1:]:
                delta_time = right.window_center_seconds - left.window_center_seconds
                if delta_time + 1e-12 >= minimum_pair_span:
                    long_slopes.append(
                        (right.acoustic_array_lag_seconds - left.acoustic_array_lag_seconds)
                        / delta_time * 1_000_000.0
                    )
        drift_fraction = estimate.drift_ppm / 1_000_000.0
        stability_tolerance = max(1.0 / rate, abs(estimate.acoustic_intercept_seconds) * 0.10)
        detrended = [
            abs(item.acoustic_array_lag_seconds
                - (estimate.acoustic_intercept_seconds
                   + drift_fraction * item.window_center_seconds))
            for item in observations
        ]
        path_stability = sum(value <= stability_tolerance for value in detrended) / len(detrended)
        delay_range = max(acoustic_delays) - min(acoustic_delays)
    return {
        "sessionOrdinal": ordinal,
        "exposureSeconds": exposure,
        "validCoverageFraction": None,
        "deliveryJitterP50Seconds": None,
        "deliveryJitterP95Seconds": None,
        "deliveryJitterP99Seconds": None,
        "driftPPM": percentile(long_slopes, 0.5),
        "driftP50PPM": percentile(long_slopes, 0.5),
        "driftP95PPM": percentile(long_slopes, 0.95),
        "driftP99PPM": percentile(long_slopes, 0.99),
        "signedDelayP50Seconds": percentile(signed_delays, 0.50),
        "signedDelayP95Seconds": percentile(signed_delays, 0.95),
        "signedDelayP99Seconds": percentile(signed_delays, 0.99),
        "_signedDelayP01Seconds": percentile(signed_delays, 0.01),
        "_signedDelayMinimumSeconds": min(signed_delays) if signed_delays else None,
        "_signedDelayMaximumSeconds": max(signed_delays) if signed_delays else None,
        "_delayRangeSeconds": delay_range,
        "bandCoherence": coherence,
        "bandPower": power,
        "pathStabilityFraction": path_stability,
        "clippingFraction": clipping,
        "heldOutLinearResidualFraction": residual,
        "delayObservationCount": len(observations),
        "_delayUnresolved": estimate.failure_category == "delayUnresolved",
        "_driftMaxAbsPPM": max((abs(value) for value in long_slopes), default=None),
        "_delayQuantizationBoundPPM": estimate.quantization_bound_ppm,
        "_estimatorFailureCategory": estimate.failure_category,
        "_signedClockFailureCategory": signed_clock_failure,
        "_acousticSupportFraction": alignment.valid_support_fraction if alignment is not None else None,
        "_rms": rms,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--sessions-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.sessions_root.is_symlink() or args.manifest.is_symlink():
        print("refusing symlink corpus roots or manifests", file=sys.stderr)
        return 2
    output_parent = args.output.parent
    output_parent_absolute = output_parent if output_parent.is_absolute() else Path.cwd() / output_parent
    if (not output_parent.exists() or not output_parent.is_dir() or output_parent.is_symlink()
            or has_symlink_component(output_parent_absolute)):
        print("invalid report destination", file=sys.stderr)
        return 2
    reasons_count: dict[str, int] = {}
    excluded: list[dict] = []
    metrics: list[dict] = []

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        manifest = {}
    if not isinstance(manifest, dict):
        manifest = {}
    gate_thresholds = dict(DEFAULT_THRESHOLDS)
    if isinstance(manifest.get("thresholds"), dict):
        gate_thresholds.update({key: value for key, value in manifest["thresholds"].items()
                                if key in DEFAULT_THRESHOLDS})
    manifest_reasons: list[str] = []
    manifest_reasons += threshold_reasons(manifest)
    if manifest.get("schemaVersion") != 1: manifest_reasons.append("invalidManifest")
    if manifest.get("topology") != "pairedScreenCaptureKit": manifest_reasons.append("unsupportedTopology")
    if manifest.get("route") != "builtInSpeakerMicrophone": manifest_reasons.append("unsupportedRoute")
    if manifest.get("consentConfirmed") is not True: manifest_reasons.append("missingConsent")
    if manifest.get("referenceCompletenessMeasured") is not True: manifest_reasons.append("referenceCompletenessUnobservable")
    if manifest.get("referenceScope") not in ("selectedApplication", "selectedWindow", "authorizedFullMix"):
        manifest_reasons.append("referenceScopeLimited")
    provenance_path_value, provenance_hash_value = manifest.get("provenanceRelativePath"), manifest.get("provenanceSha256")
    provenance_payload = None
    if (provenance_path_value is None) != (provenance_hash_value is None):
        manifest_reasons.append("invalidManifest")
    elif provenance_path_value is not None:
        if not isinstance(provenance_hash_value, str) or len(provenance_hash_value) != 64 \
                or provenance_hash_value != provenance_hash_value.lower() \
                or any(c not in "0123456789abcdef" for c in provenance_hash_value):
            manifest_reasons.append("invalidManifest")
        else:
            provenance_item = {"relativePath": provenance_path_value, "sha256": provenance_hash_value}
            provenance_path, provenance_errors = artifact_path(args.sessions_root, provenance_item)
            manifest_reasons += provenance_errors
            if provenance_path is not None:
                try:
                    provenance_payload = json.loads(provenance_path.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                    manifest_reasons.append("invalidManifest")
    render_lead = manifest.get("renderLeadSeconds", 0.0)
    if not isinstance(render_lead, (int, float)) or isinstance(render_lead, bool) or not math.isfinite(float(render_lead)) \
            or render_lead < 0 or render_lead > gate_thresholds["maximumRenderLeadSeconds"]:
        manifest_reasons.append("invalidTiming")
    if "sourceHashes" in manifest:
        manifest_reasons.append("invalidManifest")
    sessions = manifest.get("sessions") if isinstance(manifest.get("sessions"), list) else []
    if isinstance(manifest.get("artifacts"), list):
        artifacts = manifest["artifacts"]
        if sessions:
            # Codable manifests always contain this field; session-form manifests
            # require it to be empty so artifact identity has one authority.
            if artifacts:
                manifest_reasons.append("invalidManifest")
        elif len(artifacts) != 2 or {
                item.get("role") for item in artifacts if isinstance(item, dict)
        } != {"render", "capture"}:
            manifest_reasons.append("invalidManifest")
    for reason in set(manifest_reasons): reasons_count[reason] = reasons_count.get(reason, 0) + 1

    if not sessions and isinstance(manifest.get("artifacts"), list) and len(manifest["artifacts"]) == 2 \
            and all(isinstance(item, dict) for item in manifest["artifacts"]) \
            and {item.get("role") for item in manifest["artifacts"]} == {"render", "capture"}:
        artifacts = manifest["artifacts"]
        sessions = [{"ordinal": 0, "render": next(item for item in artifacts if item.get("role") == "render"),
                     "capture": next(item for item in artifacts if item.get("role") == "capture")}]
    seen_ordinals: set[object] = set()
    for index, session in enumerate(sessions):
        ordinal = session.get("ordinal", index) if isinstance(session, dict) else index
        session_reasons = list(manifest_reasons)
        if not isinstance(ordinal, int) or isinstance(ordinal, bool):
            session_reasons.append("invalidManifest")
            ordinal = index
        elif ordinal < 0:
            session_reasons.append("invalidManifest")
        if ordinal in seen_ordinals:
            session_reasons.append("duplicateOrdinal")
        seen_ordinals.add(ordinal)
        if not isinstance(session, dict):
            session_reasons.append("invalidManifest")
            render_item = capture_item = {}
        else:
            render_item, capture_item = session.get("render", {}), session.get("capture", {})
            if not isinstance(render_item, dict) or not isinstance(capture_item, dict): session_reasons.append("metadataOnly")
            timing_rates: list[float | None] = []
            timing_exposures: list[float] = []
            for timing_key in ("renderTiming", "captureTiming"):
                timing_errors, exposure, timing_rate, frame_total = timing_reasons(
                    session.get(timing_key), gate_thresholds["requireDeliveryJitter"],
                    gate_thresholds["minimumTimingBlockCount"]
                )
                session_reasons += timing_errors
                timing_rates.append(timing_rate)
                if exposure is not None and exposure < gate_thresholds["minimumExposureSeconds"]:
                    session_reasons.append("insufficientCoverage")
                if exposure is not None:
                    timing_exposures.append(exposure)
                session.setdefault("_timingFrameTotals", {})[timing_key] = frame_total
            if timing_rates[0] is not None and timing_rates[1] is not None and abs(timing_rates[0] - timing_rates[1]) > max(1e-6, timing_rates[0] * 1e-6):
                session_reasons.append("inconsistentGeometry")
        render_path, render_errors = artifact_path(args.sessions_root, render_item if isinstance(render_item, dict) else {})
        capture_path, capture_errors = artifact_path(args.sessions_root, capture_item if isinstance(capture_item, dict) else {})
        session_reasons += render_errors + capture_errors
        for item in (render_item, capture_item):
            if not isinstance(item, dict) or item.get("lossless") is not True: session_reasons.append("nonLossless")
            if not isinstance(item, dict) or item.get("developmentOnly") is not True: session_reasons.append("invalidManifest")
            if not isinstance(item, dict) or str(item.get("codec", "")).lower() not in LOSSLESS_CODECS: session_reasons.append("unsupportedCodec")
            if isinstance(item, dict):
                declared_rate = item.get("sampleRateHz")
                declared_duration = item.get("durationSeconds")
                if isinstance(declared_rate, (int, float)) and not isinstance(declared_rate, bool) \
                        and isinstance(declared_duration, (int, float)) and not isinstance(declared_duration, bool) \
                        and math.isfinite(float(declared_rate)) and math.isfinite(float(declared_duration)) \
                        and float(declared_rate) * float(declared_duration) > gate_thresholds["maximumPCMSamples"]:
                    session_reasons.append("analysisResourceLimitExceeded")
        if isinstance(render_item, dict) and render_item.get("role") != "render": session_reasons.append("invalidManifest")
        if isinstance(capture_item, dict) and capture_item.get("role") != "capture": session_reasons.append("invalidManifest")
        if isinstance(render_item, dict) and isinstance(capture_item, dict) \
                and render_item.get("path", render_item.get("relativePath")) == capture_item.get("path", capture_item.get("relativePath")):
            session_reasons.append("invalidManifest")
        if provenance_payload is not None:
            required = {"renderSHA256", "captureSHA256", "fixtureSHA256", "captureExecutableSHA256",
                        "inputUIDSHA256", "outputUIDSHA256", "runOrdinal", "targetProcessID",
                        "initialOutputVolume", "finalOutputVolume", "renderPeak", "capturePeak",
                        "renderBlockCount", "captureBlockCount", "renderFrameCount", "captureFrameCount",
                        "osBuildIdentity", "appBuildIdentity", "captureConfiguration", "route"}
            digest_keys = ("renderSHA256", "captureSHA256", "fixtureSHA256",
                           "captureExecutableSHA256", "inputUIDSHA256", "outputUIDSHA256")
            digests_valid = isinstance(provenance_payload, dict) and all(
                isinstance(provenance_payload.get(key), str)
                and len(provenance_payload[key]) == 64
                and provenance_payload[key] == provenance_payload[key].lower()
                and all(character in "0123456789abcdef" for character in provenance_payload[key])
                for key in digest_keys
            )
            numeric_keys = ("initialOutputVolume", "finalOutputVolume", "renderPeak", "capturePeak")
            numbers_valid = isinstance(provenance_payload, dict) and all(
                isinstance(provenance_payload.get(key), (int, float))
                and not isinstance(provenance_payload[key], bool)
                and math.isfinite(float(provenance_payload[key]))
                for key in numeric_keys
            )
            totals = session.get("_timingFrameTotals", {}) if isinstance(session, dict) else {}
            if not isinstance(provenance_payload, dict) or set(provenance_payload) != required \
                    or not digests_valid or not numbers_valid \
                    or provenance_payload.get("renderSHA256") != render_item.get("sha256") \
                    or provenance_payload.get("captureSHA256") != capture_item.get("sha256") \
                    or str(render_item.get("codec", "")).lower() != "pcm_f32le" \
                    or str(capture_item.get("codec", "")).lower() != "pcm_f32le" \
                    or provenance_payload.get("fixtureSHA256") not in ALLOWED_PRIVATE_PROVENANCE_FIXTURE_SHA256 \
                    or provenance_payload.get("runOrdinal") != ordinal \
                    or not isinstance(provenance_payload.get("targetProcessID"), int) \
                    or isinstance(provenance_payload.get("targetProcessID"), bool) \
                    or provenance_payload.get("targetProcessID", 0) <= 0 \
                    or not (0 < float(provenance_payload.get("initialOutputVolume", 0)) <= 0.25) \
                    or abs(float(provenance_payload.get("finalOutputVolume", 0))
                           - float(provenance_payload.get("initialOutputVolume", 0))) > 0.0001 \
                    or not (0 < float(provenance_payload.get("renderPeak", 0)) <= 0.15) \
                    or not (0 <= float(provenance_payload.get("capturePeak", -1)) <= 1) \
                    or provenance_payload.get("renderBlockCount") != len(session.get("renderTiming", [])) \
                    or provenance_payload.get("captureBlockCount") != len(session.get("captureTiming", [])) \
                    or provenance_payload.get("renderFrameCount") != totals.get("renderTiming") \
                    or provenance_payload.get("captureFrameCount") != totals.get("captureTiming") \
                    or provenance_payload.get("captureConfiguration") != "SCStream:48kHz:mono:native-f32le:audio+microphone" \
                    or provenance_payload.get("route") != "builtInSpeakerMicrophone" \
                    or not isinstance(provenance_payload.get("osBuildIdentity"), str) \
                    or not provenance_payload.get("osBuildIdentity") \
                    or not isinstance(provenance_payload.get("appBuildIdentity"), str) \
                    or not provenance_payload.get("appBuildIdentity"):
                session_reasons.append("invalidManifest")
        render_decoded = decode_wav(render_path, str(render_item.get("codec", ""))) if render_path else None
        capture_decoded = decode_wav(capture_path, str(capture_item.get("codec", ""))) if capture_path else None
        if render_decoded is None or capture_decoded is None: session_reasons.append("metadataOnly")
        if not session_reasons and render_decoded and capture_decoded:
            render, render_rate = render_decoded; capture, capture_rate = capture_decoded
            if len(render) > gate_thresholds["maximumPCMSamples"] or len(capture) > gate_thresholds["maximumPCMSamples"]:
                session_reasons.append("analysisResourceLimitExceeded")
            if render_rate != capture_rate: session_reasons.append("invalidTiming")
            if isinstance(render_item, dict) and isinstance(capture_item, dict) \
                    and (str(render_item.get("codec", "")).lower() != str(capture_item.get("codec", "")).lower()
                         or render_item.get("channelCount") != capture_item.get("channelCount")):
                session_reasons.append("inconsistentGeometry")
            elif not session_reasons:
                for item, values in ((render_item, render), (capture_item, capture)):
                    declared_rate, declared_channels, declared_duration = item.get("sampleRateHz"), item.get("channelCount"), item.get("durationSeconds")
                    declared_rate_valid = isinstance(declared_rate, (int, float)) and not isinstance(declared_rate, bool) \
                        and math.isfinite(float(declared_rate))
                    declared_duration_valid = isinstance(declared_duration, (int, float)) and not isinstance(declared_duration, bool) \
                        and math.isfinite(float(declared_duration)) and float(declared_duration) > 0
                    if declared_channels != 1 or not declared_rate_valid or abs(float(declared_rate) - render_rate) > 1e-6:
                        session_reasons.append("inconsistentGeometry")
                    if not declared_duration_valid or abs(float(declared_duration) - len(values) / render_rate) > max(1 / render_rate, 1e-6):
                        session_reasons.append("invalidTiming")
                totals = session.get("_timingFrameTotals", {})
                if totals.get("renderTiming") not in (None, len(render)) or totals.get("captureTiming") not in (None, len(capture)):
                    session_reasons.append("invalidTiming")
                render_timing = session.get("renderTiming", [])
                capture_timing = session.get("captureTiming", [])
                pts_offset = float(capture_timing[0]["presentationSeconds"]) - float(render_timing[0]["presentationSeconds"])
                value = measure(render, capture, render_rate, gate_thresholds, ordinal,
                                min(timing_exposures) if timing_exposures else None, pts_offset,
                                float(manifest.get("renderLeadSeconds", 0.0)))
                render_coverage, render_jitter = timing_metrics(session.get("renderTiming"))
                capture_coverage, capture_jitter = timing_metrics(session.get("captureTiming"))
                coverage_values = (
                    render_coverage,
                    capture_coverage,
                    value["_acousticSupportFraction"],
                )
                value["validCoverageFraction"] = (
                    min(coverage_values) if all(item is not None for item in coverage_values) else None
                )
                all_jitter = render_jitter + capture_jitter
                value["deliveryJitterP50Seconds"] = percentile(all_jitter, 0.50)
                value["deliveryJitterP95Seconds"] = percentile(all_jitter, 0.95)
                value["deliveryJitterP99Seconds"] = percentile(all_jitter, 0.99)
                estimator_failure = value["_estimatorFailureCategory"]
                signed_clock_failure = value["_signedClockFailureCategory"]
                if estimator_failure is not None:
                    session_reasons.append(estimator_failure)
                if signed_clock_failure is not None:
                    session_reasons.append(signed_clock_failure)
                if value["validCoverageFraction"] is None or value["validCoverageFraction"] < gate_thresholds["minimumValidCoverageFraction"]:
                    session_reasons.append("insufficientCoverage")
                if value["_rms"] < gate_thresholds["minimumExcitationRMS"]:
                    session_reasons.append("lowExcitation")
                if value["bandPower"] is not None and any(
                    power < gate_thresholds["minimumExcitationRMS"] ** 2
                    for power in value["bandPower"]
                ):
                    session_reasons.append("lowExcitation")
                if value["bandCoherence"] is not None and any(
                    coherence < gate_thresholds["minimumBandCoherence"]
                    for coherence in value["bandCoherence"]
                ):
                    session_reasons.append("lowExcitation")
                if value["clippingFraction"] > gate_thresholds["maximumClippingFraction"]: session_reasons.append("clipping")
                if (value["delayObservationCount"] < gate_thresholds["minimumDelayObservationCount"]
                        and estimator_failure in (None, "delayUnresolved")):
                    session_reasons.append("delayUnresolved")
                if value["driftP99PPM"] is None: session_reasons.append("driftUnscored")
                elif value["_driftMaxAbsPPM"] is not None and value["_driftMaxAbsPPM"] > gate_thresholds["maximumDriftPPM"]: session_reasons.append("excessiveDrift")
                if value["_delayRangeSeconds"] is not None and value["_delayRangeSeconds"] > gate_thresholds["maximumUncorrectedOffsetSeconds"]:
                    session_reasons.append("excessiveDrift")
                if value["_delayUnresolved"] or value["signedDelayP99Seconds"] is None: session_reasons.append("delayUnresolved")
                if value["signedDelayP99Seconds"] is not None and value["signedDelayP99Seconds"] > gate_thresholds["maximumSearchDelaySeconds"] - gate_thresholds["safetyMarginSeconds"]:
                    session_reasons.append("delayOutsideSearchRange")
                if value["_signedDelayP01Seconds"] is not None and value["_signedDelayP01Seconds"] < -gate_thresholds["safetyMarginSeconds"]:
                    session_reasons.append("delayNonCausal")
                if value["pathStabilityFraction"] is not None and value["pathStabilityFraction"] < gate_thresholds["minimumPathStabilityFraction"]: session_reasons.append("unstablePath")
                if value["pathStabilityFraction"] is None: session_reasons.append("unstablePath")
                if value["heldOutLinearResidualFraction"] is None: session_reasons.append("linearPathUnscored")
                elif value["heldOutLinearResidualFraction"] > gate_thresholds["maximumHeldOutLinearResidualFraction"]:
                    session_reasons.append("linearPathUnlearnable")
                for internal_key in (
                    "_signedDelayP01Seconds",
                    "_signedDelayMinimumSeconds",
                    "_signedDelayMaximumSeconds",
                    "_delayUnresolved",
                    "_driftMaxAbsPPM",
                    "_delayQuantizationBoundPPM",
                    "_estimatorFailureCategory",
                    "_signedClockFailureCategory",
                    "_acousticSupportFraction",
                    "_delayRangeSeconds",
                    "_rms",
                ):
                    value.pop(internal_key, None)
                if not session_reasons: metrics.append(value)
        session_reasons = list(dict.fromkeys(session_reasons))
        if session_reasons:
            excluded.append({"ordinal": ordinal, "reasons": session_reasons})
            for reason in set(session_reasons): reasons_count[reason] = reasons_count.get(reason, 0) + 1

    if not metrics: reasons_count["noEligibleSessions"] = reasons_count.get("noEligibleSessions", 0) + 1
    rejection_reasons = {"invalidManifest", "missingConsent", "sourceHashMismatch", "invalidTiming",
                         "duplicateOrdinal", "inconsistentGeometry", "gapDetected", "overlappingBlocks",
                         "excessiveDrift", "delayNonCausal", "delayOutsideSearchRange", "unstablePath",
                         "clipping", "linearPathUnlearnable"}
    has_rejection = any(any(reason in rejection_reasons for reason in item["reasons"]) for item in excluded)
    if manifest_reasons or has_rejection:
        outcome = "rejected"
    elif metrics and len(excluded) / len(sessions) <= gate_thresholds["maximumIneligibleSessionFraction"]:
        outcome = "proceedToCandidate"
    else:
        outcome = "unscored"
    report = {"schemaVersion": 1, "outcome": outcome,
              "topology": safe_category(manifest.get("topology"), {"pairedScreenCaptureKit", "vpio", "synthetic", "metadataOnly", "unknown"}),
              "route": safe_category(manifest.get("route"), {"builtInSpeakerMicrophone", "externalDevice", "unknown"}),
              "minimumExposureSeconds": gate_thresholds["minimumExposureSeconds"],
              "maximumIneligibleSessionFraction": gate_thresholds["maximumIneligibleSessionFraction"],
              "thresholdSnapshot": gate_thresholds,
              "sessionCount": len(sessions), "eligibleSessionCount": len(metrics),
              "excludedSessions": excluded, "metrics": metrics, "reasonCounts": reasons_count,
              "rawPCMRetained": False, "transcriptRetained": False, "pathsRetained": False}
    payload = (json.dumps(report, sort_keys=True, indent=2) + "\n").encode("utf-8")
    try:
        # O_EXCL makes the no-overwrite guarantee atomic; mode 0600 is applied at creation.
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
    except OSError:
        print("unable to create report", file=sys.stderr)
        return 2
    return 0 if outcome == "proceedToCandidate" else 2


if __name__ == "__main__":
    sys.exit(main())
