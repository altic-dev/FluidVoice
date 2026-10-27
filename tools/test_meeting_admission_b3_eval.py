import json
import tempfile
import unittest
from pathlib import Path

import meeting_admission_b3_eval as subject


class B3EvalTests(unittest.TestCase):
    def test_label_requires_full_containment(self):
        labels = [{"start": 0, "end": 2, "label": "noNearEndSpeech"}]
        self.assertEqual(subject.label_for(0, 2, labels), "noNearEndSpeech")
        self.assertIsNone(subject.label_for(1.9, 2.1, labels))

    def test_confusion_keeps_positive_and_negative_separate(self):
        rows = [{"label": "noNearEndSpeech", "x": True},
                {"label": "noNearEndSpeech", "x": False},
                {"label": "coarseNearEndSpeechRegion", "x": True}]
        result = subject.confusion(rows, lambda row: row["x"])
        self.assertEqual(result["falseAcceptedNegativeFrames"], 1)
        self.assertEqual(result["acceptedCoarseScriptRegionFrames"], 1)

    def test_annotation_rejects_overlap(self):
        payload = {"schemaVersion": 1, "sessions": [{"sessionID": "00000000-0000-0000-0000-000000000001", "sidecar": "a.json", "intervals": [
            {"start": 0, "end": 2, "label": "noNearEndSpeech", "provenance": "a"},
            {"start": 1, "end": 3, "label": "coarseNearEndSpeechRegion", "provenance": "b"}]}]}
        with self.assertRaises(ValueError):
            subject.validate_annotations(payload)

    def test_annotation_rejects_sidecar_traversal(self):
        payload = {"schemaVersion": 1, "sessions": [{"sessionID": "00000000-0000-0000-0000-000000000001",
            "sidecar": "../outside.json", "intervals": []}]}
        with self.assertRaises(ValueError):
            subject.validate_annotations(payload)

    def test_annotation_rejects_empty_intervals(self):
        payload = {"schemaVersion": 1, "sessions": [{"sessionID": "00000000-0000-0000-0000-000000000001",
            "sidecar": "a.json", "intervals": []}]}
        with self.assertRaises(ValueError):
            subject.validate_annotations(payload)

    def test_output_never_contains_transcript_text_or_identifiers(self):
        # Exercise the counter directly: values are aggregates and sets are collapsed.
        session = {"audioTracks": [{"id": "mic-secret", "kind": "microphone"}],
                   "transcriptSegments": [{"sourceTrackID": "mic-secret", "start": {"value": 0, "timescale": 1},
                       "end": {"value": 1, "timescale": 1}, "text": "private words", "speakerID": "private-speaker"}]}
        result = subject.transcript_counts(session, [{"start": 0, "end": 2, "label": "noNearEndSpeech"}])
        serialized = json.dumps(result)
        self.assertNotIn("private words", serialized)
        self.assertNotIn("private-speaker", serialized)
        self.assertEqual(result["byLabel"]["noNearEndSpeech"]["visibleWords"], 2)

    def test_sweep_includes_accept_all_control_and_unique_thresholds(self):
        self.assertEqual(subject.THRESHOLDS[0], 0.0)
        self.assertEqual(len(subject.THRESHOLDS), len(set(subject.THRESHOLDS)))
        self.assertIn(0.85, subject.THRESHOLDS)
        self.assertTrue(set(subject.REPORT_THRESHOLDS).issubset(subject.THRESHOLDS))

    def test_unknown_frame_is_counted_not_silently_dropped(self):
        sidecar = {"speechFrameSamples": 4096, "speechFrameSampleRate": 16000,
                   "speechFrames": [{"frame": {"start": 0, "probability": None, "unknown": "contextWarmup"},
                                     "temporalState": "unavailable"}]}
        rows, coverage = subject.session_rows(sidecar, [{"start": 0, "end": 1, "label": "noNearEndSpeech"}])
        self.assertEqual(rows, [])
        self.assertEqual(coverage["byLabel"]["noNearEndSpeech"]["unknownFrames"], 1)

    def test_invalid_missing_probability_is_rejected(self):
        sidecar = {"speechFrameSamples": 4096, "speechFrameSampleRate": 16000,
                   "speechFrames": [{"frame": {"start": 0, "probability": None, "unknown": None},
                                     "temporalState": "unavailable"}]}
        with self.assertRaises(ValueError):
            subject.session_rows(sidecar, [{"start": 0, "end": 1, "label": "noNearEndSpeech"}])

    def test_straddling_transcript_is_reported(self):
        session = {"audioTracks": [{"id": "mic", "kind": "microphone"}], "transcriptSegments": [
            {"sourceTrackID": "mic", "start": {"value": 15, "timescale": 10},
             "end": {"value": 25, "timescale": 10}, "text": "two words"}]}
        result = subject.transcript_counts(session, [
            {"start": 0, "end": 2, "label": "noNearEndSpeech"},
            {"start": 2, "end": 3, "label": "coarseNearEndSpeechRegion"}])
        self.assertEqual(result["excluded"]["boundaryStraddlingSegments"], 1)
        self.assertEqual(result["excluded"]["boundaryStraddlingWords"], 2)

    def test_session_duration_uses_either_track_origin_and_latest_end(self):
        session = {"audioTracks": [{"chunks": [
            {"presentationStart": {"value": 100, "timescale": 10},
             "presentationEnd": {"value": 200, "timescale": 10}}]}, {"chunks": [
            {"presentationStart": {"value": 90, "timescale": 10},
             "presentationEnd": {"value": 210, "timescale": 10}}]}]}
        self.assertEqual(subject.session_duration(session), 12)


if __name__ == "__main__":
    unittest.main()
