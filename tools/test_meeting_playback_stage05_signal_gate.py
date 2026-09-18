#!/usr/bin/env python3
import sys
import unittest
import copy
import hashlib
import json
import math
import os
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import meeting_playback_stage05_signal_gate as gate


class Stage05SignalGateTests(unittest.TestCase):
    @staticmethod
    def _write_float_wav(path: Path, samples: list[float], rate: int = 16_000) -> None:
        payload = struct.pack("<%df" % len(samples), *samples)
        fmt = struct.pack("<HHIIHH", 3, 1, rate, rate * 4, 4, 32)
        body = b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(payload)) + payload
        path.write_bytes(b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body)

    @staticmethod
    def _write_wav(path: Path, samples: list[float], rate: int = 16_000) -> None:
        encoded = [max(-32768, min(32767, int(round(value * 32767)))) for value in samples]
        with wave.open(str(path), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(rate)
            stream.writeframes(struct.pack("<%dh" % len(encoded), *encoded))

    @staticmethod
    def _seeded_signal(rate: int, seconds: float, tones: bool = False) -> list[float]:
        values, state = [], 0x1234_5678
        for index in range(round(rate * seconds)):
            state = (state * 1_664_525 + 1_013_904_223) & 0xFFFF_FFFF
            value = ((state / 0xFFFF_FFFF) - 0.5) * 0.30
            if tones:
                time = index / rate
                value += 0.04 * (
                    math.sin(2 * math.pi * 250 * time)
                    + math.sin(2 * math.pi * 1_000 * time)
                    + math.sin(2 * math.pi * 4_000 * time)
                ) / 3
            values.append(value)
        return values

    @staticmethod
    def _affine_capture(
        render: list[float], rate: int, delay_seconds: float, drift_ppm: float
    ) -> list[float]:
        capture = []
        for index in range(len(render)):
            source = index - (delay_seconds + drift_ppm / 1_000_000 * index / rate) * rate
            lower = math.floor(source)
            fraction = source - lower
            if lower < 0 or lower + 1 >= len(render):
                capture.append(0.0)
            else:
                capture.append(render[lower] * (1.0 - fraction) + render[lower + 1] * fraction)
        return capture

    def _cli_fixture(self):
        temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        root = Path(temporary.name)
        rate, count, delay = 16_000, 20_000, 96
        render, state = [], 0x1234_5678
        for index in range(count):
            state = (state * 1_664_525 + 1_013_904_223) & 0xFFFF_FFFF
            # Broadband component disambiguates the deliberately simultaneous multiband tones
            # from one-period aliases while remaining an ordinary lossless excitation fixture.
            noise = ((state / 0xFFFF_FFFF) - 0.5) * 0.24
            t = index / rate
            render.append(0.18 * (math.sin(2 * math.pi * 250 * t) + math.sin(2 * math.pi * 1_000 * t) + math.sin(2 * math.pi * 4_000 * t)) / 3 + noise)
        capture = [0.0] * delay + render[:-delay]
        self._write_wav(root / "render.wav", render, rate); self._write_wav(root / "capture.wav", capture, rate)

        def artifact(role: str, name: str) -> dict:
            payload = (root / name).read_bytes()
            return {"role": role, "relativePath": name, "sha256": hashlib.sha256(payload).hexdigest(),
                    "codec": "pcm_s16le", "lossless": True, "sampleRateHz": rate,
                    "channelCount": 1, "durationSeconds": count / rate, "developmentOnly": True}

        duration = count / rate
        timing = [
            {"presentationSeconds": start / rate, "durationSeconds": 4_000 / rate,
             "frameCount": 4_000, "arrivalSeconds": start / rate}
            for start in range(0, count, 4_000)
        ]
        manifest = {"schemaVersion": 1, "topology": "pairedScreenCaptureKit", "route": "builtInSpeakerMicrophone",
                    "referenceScope": "selectedApplication", "referenceCompletenessMeasured": True, "consentConfirmed": True,
                    "artifacts": [],
                    "thresholds": {"maximumSearchDelaySeconds": 0.05, "safetyMarginSeconds": 0.01,
                                   "maximumDriftPPM": 2_000},
                    "sessions": [{"ordinal": 0, "render": artifact("render", "render.wav"), "capture": artifact("capture", "capture.wav"),
                                  "renderTiming": timing, "captureTiming": copy.deepcopy(timing)}]}
        manifest_path = root / "manifest.json"; manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return temporary, root, manifest, manifest_path

    @staticmethod
    def _run_cli(root: Path, manifest_path: Path, output_name: str):
        return subprocess.run([sys.executable, str(Path(__file__).with_name("meeting_playback_stage05_signal_gate.py")),
                               "--manifest", str(manifest_path), "--sessions-root", str(root), "--output", str(root / output_name)],
                              capture_output=True, text=True)

    def test_cli_stable_delayed_linear_fixture_passes_and_report_is_private(self):
        temporary, root, _, manifest_path = self._cli_fixture()
        try:
            result = self._run_cli(root, manifest_path, "report.json")
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / "report.json").read_text(encoding="utf-8")); metric = report["metrics"][0]
            self.assertEqual(report["outcome"], "proceedToCandidate"); self.assertEqual(report["eligibleSessionCount"], 1)
            self.assertIsNotNone(metric["signedDelayP50Seconds"]); self.assertIsNotNone(metric["driftP99PPM"])
            self.assertTrue(all(value is not None for value in metric["bandCoherence"]))
            self.assertGreaterEqual(metric["delayObservationCount"], 3)
            self.assertAlmostEqual(metric["signedDelayP50Seconds"], 96 / 16_000, delta=0.002)
            self.assertLessEqual(abs(metric["driftP99PPM"]), 0.1)
            self.assertGreater(min(metric["bandCoherence"]), 0.1)
            self.assertIsNotNone(metric["heldOutLinearResidualFraction"]); self.assertIsNotNone(metric["clippingFraction"])
            serialized = json.dumps(report); self.assertNotIn(str(root), serialized); self.assertNotIn("render.wav", serialized)
            self.assertFalse(report["rawPCMRetained"] or report["transcriptRetained"] or report["pathsRetained"])
        finally:
            temporary.cleanup()

    def test_cli_rejects_time_varying_fixture_and_geometry_hash_gap(self):
        temporary, root, manifest, manifest_path = self._cli_fixture()
        try:
            varying = copy.deepcopy(manifest); rate, count = 16_000, 20_000
            with wave.open(str(root / "capture.wav"), "rb") as stream: raw = stream.readframes(stream.getnframes())
            source = list(struct.unpack("<%dh" % (len(raw) // 2), raw)); source = [value if index < 15_500 else int(value * 0.05) for index, value in enumerate(source)]
            with wave.open(str(root / "capture.wav"), "wb") as stream:
                stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(rate); stream.writeframes(struct.pack("<%dh" % len(source), *source))
            varying["sessions"][0]["capture"]["sha256"] = hashlib.sha256((root / "capture.wav").read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(varying), encoding="utf-8")
            result = self._run_cli(root, manifest_path, "varying.json"); self.assertEqual(result.returncode, 2)
            varying_report = json.loads((root / "varying.json").read_text()); self.assertEqual(varying_report["outcome"], "rejected")
            self.assertTrue(
                {"linearPathUnlearnable", "delayUnresolved"}
                & set(varying_report["reasonCounts"])
            )

            broken = copy.deepcopy(varying); broken["sessions"][0]["render"]["sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(broken), encoding="utf-8"); result = self._run_cli(root, manifest_path, "hash.json"); self.assertEqual(result.returncode, 2)
            self.assertIn("sourceHashMismatch", json.loads((root / "hash.json").read_text())["reasonCounts"])

            gap = copy.deepcopy(manifest)
            for key in ("renderTiming", "captureTiming"):
                gap["sessions"][0][key] = [{"presentationSeconds": 0, "durationSeconds": 0.625, "frameCount": 10_000, "arrivalSeconds": 0},
                                             {"presentationSeconds": 1.5, "durationSeconds": 0.625, "frameCount": 10_000, "arrivalSeconds": 1.5}]
            manifest_path.write_text(json.dumps(gap), encoding="utf-8"); result = self._run_cli(root, manifest_path, "gap.json"); self.assertEqual(result.returncode, 2)
            self.assertIn("gapDetected", json.loads((root / "gap.json").read_text())["reasonCounts"])
        finally:
            temporary.cleanup()

    def test_cli_rejects_geometry_and_never_overwrites_report(self):
        temporary, root, manifest, manifest_path = self._cli_fixture()
        try:
            geometry = copy.deepcopy(manifest); geometry["sessions"][0]["renderTiming"][0]["frameCount"] -= 1
            manifest_path.write_text(json.dumps(geometry), encoding="utf-8"); result = self._run_cli(root, manifest_path, "geometry.json"); self.assertEqual(result.returncode, 2)
            self.assertTrue({"invalidTiming", "inconsistentGeometry"} & set(json.loads((root / "geometry.json").read_text())["reasonCounts"]))
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8"); first = self._run_cli(root, manifest_path, "once.json"); self.assertEqual(first.returncode, 0, first.stderr)
            second = self._run_cli(root, manifest_path, "once.json"); self.assertEqual(second.returncode, 2); self.assertIn("unable to create report", second.stderr)
            self.assertEqual(os.stat(root / "once.json").st_mode & 0o777, 0o600)
        finally:
            temporary.cleanup()

    def test_unknown_and_nonfinite_thresholds_fail_closed(self):
        self.assertIn("invalidThresholds", gate.threshold_reasons({"thresholds": {"future": 1}}))
        self.assertIn("invalidThresholds", gate.threshold_reasons({"thresholds": {"maximumDriftPPM": float("nan")}}))
        self.assertEqual(gate.safe_category("private-window-title", {"unknown"}), "unknown")

    def test_native_float32_wav_is_decoded_and_nonfinite_is_rejected(self):
        temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        try:
            path = Path(temporary.name) / "float.wav"
            self._write_float_wav(path, [0.25, -0.5, 0.0])
            decoded = gate.decode_wav(path, "pcm_f32le")
            self.assertIsNotNone(decoded)
            self.assertEqual(decoded[1], 16_000)
            self.assertEqual(decoded[0], [0.25, -0.5, 0.0])
            self.assertIsNone(gate.decode_wav(path, "pcm_s16le"))
            self._write_float_wav(path, [float("nan")])
            self.assertIsNone(gate.decode_wav(path, "pcm_f32le"))
        finally:
            temporary.cleanup()

    def test_private_provenance_is_hash_bound_and_rejects_extra_fields(self):
        temporary, root, manifest, manifest_path = self._cli_fixture()
        try:
            session = manifest["sessions"][0]
            for role in ("render", "capture"):
                artifact = session[role]
                path = root / artifact["relativePath"]
                with wave.open(str(path), "rb") as stream:
                    raw = stream.readframes(stream.getnframes())
                samples = [value / 32768.0 for value in struct.unpack("<%dh" % (len(raw) // 2), raw)]
                self._write_float_wav(path, samples, int(artifact["sampleRateHz"]))
                artifact["codec"] = "pcm_f32le"
                artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            provenance = {
                "renderSHA256": session["render"]["sha256"],
                "captureSHA256": session["capture"]["sha256"],
                "fixtureSHA256": gate.EXPECTED_FIXTURE_SHA256,
                "captureExecutableSHA256": "a" * 64,
                "inputUIDSHA256": "b" * 64,
                "outputUIDSHA256": "c" * 64,
                "runOrdinal": 0,
                "targetProcessID": 123,
                "initialOutputVolume": 0.25,
                "finalOutputVolume": 0.25,
                "renderPeak": 0.10,
                "capturePeak": 0.20,
                "renderBlockCount": len(session["renderTiming"]),
                "captureBlockCount": len(session["captureTiming"]),
                "renderFrameCount": sum(block["frameCount"] for block in session["renderTiming"]),
                "captureFrameCount": sum(block["frameCount"] for block in session["captureTiming"]),
                "osBuildIdentity": "test-os",
                "appBuildIdentity": "test-build",
                "captureConfiguration": "SCStream:48kHz:mono:native-f32le:audio+microphone",
                "route": "builtInSpeakerMicrophone",
            }
            provenance_path = root / "provenance.json"
            provenance_path.write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
            manifest["provenanceRelativePath"] = "provenance.json"
            manifest["provenanceSha256"] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            accepted = self._run_cli(root, manifest_path, "provenance-pass.json")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            provenance["fixtureSHA256"] = gate.EXPECTED_OPERATOR_MEDIA_FIXTURE_SHA256
            provenance_path.write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
            manifest["provenanceSha256"] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            operator_media = self._run_cli(root, manifest_path, "provenance-operator-media-pass.json")
            self.assertEqual(operator_media.returncode, 0, operator_media.stderr)

            provenance["fixtureSHA256"] = "d" * 64
            provenance_path.write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
            manifest["provenanceSha256"] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            unknown = self._run_cli(root, manifest_path, "provenance-unknown-fixture.json")
            self.assertEqual(unknown.returncode, 2)
            unknown_report = json.loads((root / "provenance-unknown-fixture.json").read_text(encoding="utf-8"))
            self.assertEqual(unknown_report["outcome"], "rejected")
            self.assertIn("invalidManifest", unknown_report["reasonCounts"])

            provenance["fixtureSHA256"] = gate.EXPECTED_FIXTURE_SHA256
            provenance["absolutePath"] = "/private/leak"
            provenance_path.write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
            manifest["provenanceSha256"] = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            rejected = self._run_cli(root, manifest_path, "provenance-reject.json")
            self.assertEqual(rejected.returncode, 2)
            report = json.loads((root / "provenance-reject.json").read_text(encoding="utf-8"))
            self.assertEqual(report["outcome"], "rejected")
            self.assertIn("invalidManifest", report["reasonCounts"])
            self.assertNotIn("absolutePath", json.dumps(report))
        finally:
            temporary.cleanup()

    def test_fir_fixture_is_low_residual_and_time_varying_fixture_is_not(self):
        render = [0.1 if i % 8 == 0 else 0.0 for i in range(2_000)]
        stable = list(render)
        varying = [value if i < 1_500 else value * 0.05 for i, value in enumerate(render)]
        self.assertLess(gate.held_out_linear_residual(render, stable, 2_000), 0.01)
        self.assertGreater(gate.held_out_linear_residual(render, varying, 2_000), 0.5)

    def test_timing_rejects_gap_overlap_and_missing_arrival(self):
        blocks = [
            {"presentationSeconds": 0, "durationSeconds": 1, "frameCount": 16_000, "arrivalSeconds": 0},
            {"presentationSeconds": 2, "durationSeconds": 1, "frameCount": 16_000, "arrivalSeconds": 2},
        ]
        reasons, _, _, _ = gate.timing_reasons(blocks, True)
        self.assertIn("gapDetected", reasons)
        overlap = [dict(blocks[0]), dict(blocks[1], presentationSeconds=0.5, arrivalSeconds=0.5)]
        reasons, _, _, _ = gate.timing_reasons(overlap, True)
        self.assertIn("overlappingBlocks", reasons)
        reasons, _, _, _ = gate.timing_reasons([dict(blocks[0], arrivalSeconds=None)], True)
        self.assertIn("missingArrivalMetadata", reasons)
        self.assertIn("insufficientTimingObservations", reasons)
        reversed_arrival = [dict(blocks[0]), dict(blocks[1], arrivalSeconds=-1)]
        reasons, _, _, _ = gate.timing_reasons(reversed_arrival, True)
        self.assertIn("invalidTiming", reasons)

    def test_band_measures_are_not_cloned(self):
        samples = [0.1 if i % 16 == 0 else 0.0 for i in range(4_096)]
        coherence, power = gate.band_measures(samples, samples, 16_000)
        self.assertEqual(len(coherence), 3)
        self.assertEqual(len(power), 3)
        self.assertTrue(any(abs(value - power[0]) > 1e-12 for value in power[1:]))

    def test_correlation_rejects_tiny_boundary_overlap(self):
        signal = [0.1 if i % 8 == 0 else 0.0 for i in range(2_000)]
        self.assertLess(gate.correlation_at_lag(signal, signal, 1_999), 0.0)
        self.assertGreater(gate.correlation_at_lag(signal, signal, 0), 0.99)

    def test_periodic_delay_without_a_prominent_peak_is_unresolved(self):
        rate = 16_000
        periodic = [0.1 * math.sin(2 * math.pi * 1_000 * index / rate)
                    for index in range(rate * 2)]
        self.assertIsNone(gate.global_delay_anchor(periodic, periodic, rate, 0.05))

    def test_preprocessing_and_peak_selection_fail_closed(self):
        self.assertIsNone(gate.finite_mean_centered([]))
        self.assertIsNone(gate.finite_mean_centered([0.0, float("nan")]))
        envelope = gate.energy_envelope([1.0, -1.0] * 8, 1_000, 0.004)
        self.assertEqual(envelope, ([1.0, 1.0, 1.0, 1.0], 250.0))
        self.assertEqual(gate.first_difference([1.0, 4.0, 2.0]), [3.0, -2.0])

        source = self._seeded_signal(4_000, 1.5)
        inverted = [-value for value in source]
        self.assertLess(gate.normalized_correlation_at_lag(source, inverted, 0), -0.99)
        self.assertIsNone(gate.prominent_peak(source, source, -1, 1, 10))

        first, second = 40, 120
        double = [
            (source[index - first] if index >= first else 0.0)
            + (source[index - second] if index >= second else 0.0)
            for index in range(len(source))
        ]
        self.assertIsNone(gate.prominent_peak(source, double, -200, 200, 40))
        boundary = [0.0] * 200 + source[:-200]
        self.assertIsNone(gate.prominent_peak(source, boundary, -200, 200, 40))

    def test_full_span_estimator_and_measured_support(self):
        rate = 16_000
        render = self._seeded_signal(rate, 14.0, tones=True)
        capture = self._affine_capture(render, rate, 0.006, 0.0)
        estimate = gate.estimate_delay(render, capture, rate, gate.DEFAULT_THRESHOLDS)
        self.assertIsNone(estimate.failure_category)
        self.assertGreaterEqual(len(estimate.observations), 5)
        self.assertAlmostEqual(estimate.acoustic_intercept_seconds, 0.006, delta=2 / rate)
        self.assertLess(abs(estimate.drift_ppm), 1.0)
        aligned = gate.align_affine_support(render, capture, rate, estimate)
        self.assertIsNotNone(aligned)
        self.assertGreaterEqual(aligned.valid_support_fraction, 0.99)
        self.assertEqual(len(aligned.render_samples), len(aligned.capture_samples))
        self.assertLess(gate.held_out_linear_residual(
            list(aligned.render_samples), list(aligned.capture_samples), rate
        ), 0.01)

    def test_drift_is_uncertainty_bounded_and_outside_limit_never_passes(self):
        rate = 16_000
        render = self._seeded_signal(rate, 14.0)
        for expected in (50.0, -50.0):
            estimate = gate.estimate_delay(
                render,
                self._affine_capture(render, rate, 0.010, expected),
                rate,
                gate.DEFAULT_THRESHOLDS,
            )
            self.assertIsNone(estimate.failure_category)
            self.assertAlmostEqual(estimate.drift_ppm, expected, delta=5.0)
            self.assertLessEqual(
                abs(estimate.drift_ppm) + estimate.quantization_bound_ppm,
                gate.DEFAULT_THRESHOLDS["maximumDriftPPM"],
            )

        outside = gate.estimate_delay(
            render,
            self._affine_capture(render, rate, 0.010, 101.0),
            rate,
            gate.DEFAULT_THRESHOLDS,
        )
        self.assertIsNotNone(outside.failure_category)
        self.assertIsNone(outside.drift_ppm)
        self.assertEqual(outside.observations, ())

    def test_every_scheduled_window_is_required(self):
        rate = 16_000
        render = self._seeded_signal(rate, 14.0)
        capture = self._affine_capture(render, rate, 0.010, 0.0)
        unrelated = self._seeded_signal(rate, 3.0)
        capture[-len(unrelated):] = unrelated
        estimate = gate.estimate_delay(render, capture, rate, gate.DEFAULT_THRESHOLDS)
        self.assertEqual(estimate.failure_category, "delayUnresolved")
        self.assertEqual(estimate.observations, ())
        self.assertIsNone(estimate.drift_ppm)

    def test_resolved_delay_outlier_rejects_the_whole_track(self):
        rate = 16_000
        render = self._seeded_signal(rate, 14.0)
        capture = []
        for index in range(len(render)):
            delay = 0.010 if index < rate * 11 else 0.015
            source = index - delay * rate
            lower = math.floor(source)
            fraction = source - lower
            capture.append(
                0.0 if lower < 0 or lower + 1 >= len(render)
                else render[lower] * (1.0 - fraction) + render[lower + 1] * fraction
            )
        estimate = gate.estimate_delay(render, capture, rate, gate.DEFAULT_THRESHOLDS)
        self.assertEqual(estimate.failure_category, "excessiveDrift")
        self.assertEqual(estimate.observations, ())
        self.assertIsNone(estimate.drift_ppm)

    def test_signed_clock_contract_applies_each_term_once_and_nulls_failure(self):
        def estimate(lag: float) -> gate.DelayEstimate:
            observations = tuple(
                gate.DelayObservation(index, lag, 0.00001, 0.8, 0.2, 0.6)
                for index in range(5)
            )
            return gate.DelayEstimate(0.0, lag, 0.0, 1.0, observations, 0.0, None)

        signed, failure = gate.signed_delay_contract(
            estimate(0.010), 0.020, 0.030, gate.DEFAULT_THRESHOLDS
        )
        self.assertIsNone(failure)
        self.assertTrue(all(abs(value - 0.060) < 1e-12 for value in signed))

        signed, failure = gate.signed_delay_contract(
            estimate(0.0), -0.021, 0.0, gate.DEFAULT_THRESHOLDS
        )
        self.assertEqual((signed, failure), ((), "delayNonCausal"))
        signed, failure = gate.signed_delay_contract(
            estimate(0.450), 0.0, 0.031, gate.DEFAULT_THRESHOLDS
        )
        self.assertEqual((signed, failure), ((), "delayOutsideSearchRange"))
        unresolved = gate.failed_delay_estimate("delayUnresolved")
        self.assertEqual(
            gate.signed_delay_contract(unresolved, 0.100, 0.050, gate.DEFAULT_THRESHOLDS),
            ((), None),
        )

    def test_unresolved_measure_has_no_dependent_metrics(self):
        rate = 16_000
        periodic = [0.1 * math.sin(2 * math.pi * 1_000 * index / rate)
                    for index in range(rate * 2)]
        metric = gate.measure(periodic, periodic, rate, gate.DEFAULT_THRESHOLDS, 0, 2.0)
        self.assertTrue(metric["_delayUnresolved"])
        self.assertIsNone(metric["driftP99PPM"])
        self.assertIsNone(metric["signedDelayP50Seconds"])
        self.assertIsNone(metric["bandCoherence"])
        self.assertIsNone(metric["heldOutLinearResidualFraction"])
        self.assertIsNone(metric["_acousticSupportFraction"])

    def test_affine_alignment_never_pads_or_bridges_support(self):
        render = [float(index) for index in range(1_000)]
        capture = [float(index) for index in range(1_000)]
        observations = tuple(
            gate.DelayObservation(index, 0.010, 0.0005, 1.0, 0.0, 1.0)
            for index in range(5)
        )
        estimate = gate.DelayEstimate(0.010, 0.010, 0.0, 1.0, observations, 0.0, None)
        aligned = gate.align_affine_support(render, capture, 1_000, estimate)
        self.assertIsNotNone(aligned)
        self.assertEqual(len(aligned.render_samples), 990)
        self.assertEqual(aligned.valid_support_fraction, 0.99)
        self.assertEqual(aligned.render_samples[0], render[0])
        self.assertEqual(aligned.capture_samples[0], capture[10])

        unequal = gate.align_affine_support(render, capture + [0.0] * 100, 1_000, estimate)
        self.assertIsNotNone(unequal)
        self.assertLess(unequal.valid_support_fraction, 0.91)

    def test_short_default_drift_resolution_is_unscored(self):
        rate = 16_000
        render = self._seeded_signal(rate, 1.25, tones=True)
        capture = self._affine_capture(render, rate, 0.006, 0.0)
        estimate = gate.estimate_delay(render, capture, rate, gate.DEFAULT_THRESHOLDS)
        self.assertEqual(estimate.failure_category, "driftUnscored")
        self.assertIsNone(estimate.drift_ppm)

    def test_fixed_64ms_fir_passes_both_path_regions(self):
        rate = 4_000
        render = self._seeded_signal(rate, 3.0)
        taps = {0: 0.8, 40: 0.3, 255: 0.2}
        capture = [
            sum(weight * render[index - offset]
                for offset, weight in taps.items() if index >= offset)
            for index in range(len(render))
        ]
        self.assertLess(gate.held_out_linear_residual(render, capture, rate), 0.01)


if __name__ == "__main__":
    unittest.main()
