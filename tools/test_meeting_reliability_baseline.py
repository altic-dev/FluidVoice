import json
import tempfile
import unittest
from pathlib import Path

import meeting_reliability_baseline as baseline


class BaselineTests(unittest.TestCase):
    def test_flow_plateau_is_only_sampled_lower_bound(self):
        rows = [f"[07:18:{s:02d}.000] [INFO] [MeetingLive] [live/APP] flow chunks={c} audio={a}s openUtterance=0.0s partials={p} utterances=2 drops=0 SECRET_TRANSCRIPT"
                for s, c, a, p in [(7, 2255, 45.1, 123), (12, 2506, 50.1, 123), (37, 3758, 75.2, 123), (42, 4009, 80.2, 125)]]
        result = baseline.summarize_flows(rows)
        run = result["APP"]["longestSampledNoPartialRun"]
        self.assertEqual(run["observedNoPartialSpanSeconds"], 30)
        self.assertEqual(run["partialCount"], 123)
        self.assertNotIn("SECRET", json.dumps(result))

    def test_regressed_counter_rejects_multiple_sessions(self):
        line = "[07:18:07.000] [live/APP] flow chunks={} audio=1.0s openUtterance=0.0s partials=0 utterances=0 drops=0"
        with self.assertRaises(ValueError):
            baseline.summarize_flows([line.format(10), line.format(1)])

    def test_missing_flow_is_not_zero_drops_evidence(self):
        result = baseline.summarize_flows(["private unrelated log"])
        self.assertIsNone(result["APP"]["lastCounters"])
        self.assertIsNone(result["APP"]["longestSampledNoPartialRun"])

    def test_path_traversal_and_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            root.mkdir()
            (Path(directory) / "outside").write_text("private")
            (root / "escape").symlink_to(Path(directory) / "outside")
            for value in ("../outside", "/etc/passwd", "a//b", "./x", "a\\b", "escape"):
                with self.assertRaises(ValueError):
                    baseline.safe_child(root, value)

    def test_model_hash_mismatch_remains_false(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "example").mkdir()
            (root / "example/model.bin").write_bytes(b"model")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"modelRepository": "example", "artifacts": [
                {"path": "example/model.bin", "sha256": "0" * 64}]}))
            self.assertFalse(baseline.model_manifest_inventory(manifest)["allHashesMatch"])
            self.assertTrue(baseline.model_manifest_inventory(manifest)["exactTreeMatch"])
            (root / "example/extra.bin").write_bytes(b"extra")
            self.assertFalse(baseline.model_manifest_inventory(manifest)["exactTreeMatch"])

    def test_saved_source_track_id_counts_without_emitting_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.json"
            path.write_text(json.dumps({"audioTracks": [{"id": "mic", "kind": "microphone", "chunks": [], "health": {"droppedSampleCount": 0}}],
                                       "transcriptSegments": [
                                           {"sourceTrackID": "mic", "speakerID": "one", "text": "PRIVATE", "isLikelyEcho": False},
                                           {"sourceTrackID": "mic", "speakerID": "two", "text": "PRIVATE", "isLikelyEcho": True}]}))
            result = baseline.session_inventory(path)
            self.assertEqual(result["tracks"][0]["visibleSegmentCount"], 1)
            self.assertEqual(result["tracks"][0]["echoSegmentCount"], 1)
            self.assertNotIn("PRIVATE", json.dumps(result))

    def test_missing_health_fails_closed_and_missing_speaker_is_not_a_person(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.json"
            payload = {"audioTracks": [{"id": "mic", "kind": "microphone", "chunks": []}],
                       "transcriptSegments": [{"sourceTrackID": "mic"}]}
            path.write_text(json.dumps(payload))
            with self.assertRaises(ValueError):
                baseline.session_inventory(path)
            payload["audioTracks"][0]["health"] = {"droppedSampleCount": 0}
            path.write_text(json.dumps(payload))
            track = baseline.session_inventory(path)["tracks"][0]
            self.assertEqual(track["visibleSpeakerCount"], 0)
            self.assertEqual(track["missingVisibleSpeakerIDCount"], 1)

    def test_unknown_segment_schema_fails_instead_of_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.json"
            path.write_text(json.dumps({"audioTracks": [{"id": "mic", "kind": "microphone", "chunks": []}],
                                       "transcriptSegments": [{"trackID": "mic"}]}))
            with self.assertRaises(ValueError):
                baseline.session_inventory(path)


if __name__ == "__main__":
    unittest.main()
