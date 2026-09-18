import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import meeting_playback_stage0_baseline as baseline


def media_time(seconds: int):
    return {"value": seconds * 1000, "timescale": 1000}


def make_track(root: Path, kind: str, method: str, codec: str = "lpcm"):
    relative = f"tracks/{kind}/000000.bin"
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((kind + method).encode())
    digest = baseline.sha256_file(path)
    return {
        "id": f"{kind}-id",
        "kind": kind,
        "captureMethod": method,
        "format": {"codec": codec, "sampleRate": 48000, "channelCount": 1},
        "health": {"droppedSampleCount": 0},
        "captureEras": [],
        "chunks": [
            {
                "sequence": 0,
                "relativeFilePath": relative,
                "presentationStart": media_time(1),
                "presentationEnd": media_time(2),
                "sha256": digest,
                "byteCount": path.stat().st_size,
                "finalizationState": "finalized",
                "discontinuities": [],
            }
        ],
    }


class Stage0BaselineTests(unittest.TestCase):
    def test_raw_lossless_paired_topology_still_requires_route_and_evidence(self):
        recording = {
            "topology": "pairedSCKSingleStream",
            "route": "builtInSpeakersPersisted",
            "tracks": [
                {"format": {"codec": "lpcm"}},
                {"format": {"codec": "lpcm"}},
            ],
        }
        reasons = baseline.stage05_reasons(recording)
        self.assertNotIn("notRawPairedSCKTopology", reasons)
        self.assertNotIn("lossySourceCodec", reasons)
        self.assertIn("excitationNotIndependentlyAnnotated", reasons)
        self.assertIn("consentProvenanceNotRecordedForSignalDomainCorpus", reasons)

    def test_vpio_aac_is_never_promoted_to_paired_signal_evidence(self):
        recording = {
            "topology": "selectedApplicationSCKPlusVPIOMicrophone",
            "route": "speakersUserReported",
            "tracks": [
                {"format": {"codec": "aac-lc"}},
                {"format": {"codec": "aac-lc"}},
            ],
        }
        reasons = baseline.stage05_reasons(recording)
        self.assertIn("notRawPairedSCKTopology", reasons)
        self.assertIn("lossySourceCodec", reasons)
        self.assertIn("exactBuiltInRouteNotPersisted", reasons)

    def test_inventory_hashes_chunks_without_emitting_private_session_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session_id = "720AB8CD-842E-4D25-97A1-9CAAFBC28E74"
            session_root = root / session_id
            session_root.mkdir()
            session = {
                "id": session_id,
                "mode": "onlineCall",
                "title": "PRIVATE TITLE",
                "transcriptSegments": [{"text": "PRIVATE TRANSCRIPT"}],
                "speakers": [{"displayName": "PRIVATE NAME", "diarizationEmbedding": [0.1]}],
                "audioTracks": [
                    make_track(session_root, "applicationAudio", "screenCaptureKit", "aac-lc"),
                    make_track(session_root, "microphone", "voiceProcessing", "aac-lc"),
                ],
            }
            (session_root / "session.json").write_text(json.dumps(session))
            annotation = {
                "sessionID": session_id,
                "intervals": [{"start": 0, "end": 1, "label": "noNearEndSpeech"}],
            }
            result = baseline.recording_inventory(root, annotation, "development-only-v1")
            encoded = json.dumps(result)
            self.assertNotIn("PRIVATE", encoded)
            self.assertNotIn("transcript", encoded)
            self.assertNotIn("diarizationEmbedding", encoded)
            self.assertEqual(result["topology"], "selectedApplicationSCKPlusVPIOMicrophone")
            self.assertFalse(result["stage05Eligible"])
            self.assertTrue(all(
                chunk["storedSHA256Matches"]
                for track in result["tracks"]
                for chunk in track["chunks"]
            ))

    def test_profile_digest_changes_but_never_returns_private_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session_root = root / "720AB8CD-842E-4D25-97A1-9CAAFBC28E74"
            session_root.mkdir()
            path = session_root / "session.json"
            payload = {
                "id": session_root.name,
                "speakers": [{"id": "PRIVATE", "displayName": "PRIVATE", "diarizationEmbedding": [0.1, 0.2]}],
            }
            path.write_text(json.dumps(payload))
            first = baseline.profile_state_inventory(root)
            payload["speakers"][0]["diarizationEmbedding"][0] = 0.3
            path.write_text(json.dumps(payload))
            second = baseline.profile_state_inventory(root)
            self.assertNotEqual(first["canonicalProfileStateSHA256"], second["canonicalProfileStateSHA256"])
            self.assertNotIn("PRIVATE", json.dumps(first))
            self.assertEqual(first["speakerRecordsWithEmbedding"], 1)
            self.assertEqual(first["sourceSessionIDs"], [session_root.name])

    def test_profile_digest_can_recheck_frozen_sessions_without_absorbing_new_ones(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_id = "720AB8CD-842E-4D25-97A1-9CAAFBC28E74"
            first_root = root / first_id
            first_root.mkdir()
            (first_root / "session.json").write_text(json.dumps({"id": first_id, "speakers": []}))
            frozen = baseline.profile_state_inventory(root)
            second_id = "C102F9B6-C61F-48EB-8F8B-A36451C712B8"
            second_root = root / second_id
            second_root.mkdir()
            (second_root / "session.json").write_text(json.dumps({"id": second_id, "speakers": [{"id": "new"}]}))
            rechecked = baseline.profile_state_inventory(root, frozen["sourceSessionIDs"])
            self.assertEqual(
                frozen["canonicalProfileStateSHA256"],
                rechecked["canonicalProfileStateSHA256"],
            )
            self.assertEqual(rechecked["sourceSessionCount"], 1)

    def test_chunk_escape_and_hash_mismatch_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = root / "session"
            session.mkdir()
            (root / "outside").write_bytes(b"private")
            track = make_track(session, "microphone", "screenCaptureKit")
            track["chunks"][0]["relativeFilePath"] = "../outside"
            with self.assertRaises(ValueError):
                baseline.track_inventory(session, track)
            track = make_track(session, "microphone", "screenCaptureKit")
            track["chunks"][0]["byteCount"] += 1
            with self.assertRaises(ValueError):
                baseline.track_inventory(session, track)
            track = make_track(session, "microphone", "screenCaptureKit")
            track["chunks"][0]["sha256"] = "0" * 64
            with self.assertRaises(ValueError):
                baseline.track_inventory(session, track)

    def test_manifest_validation_forbids_private_or_aec_authorization(self):
        base = {
            "schemaVersion": 1,
            "recordings": [{"developmentOnly": True}],
            "stage05": {"aec3DependencyAuthorized": False},
        }
        baseline.validate_manifest_shape(base)
        private = dict(base, leaked="/Users/example/private")
        with self.assertRaises(ValueError):
            baseline.validate_manifest_shape(private)
        other_absolute = dict(base, leaked="/private/example")
        with self.assertRaises(ValueError):
            baseline.validate_manifest_shape(other_absolute)
        url = dict(base, leaked="https://example.invalid/private")
        with self.assertRaises(ValueError):
            baseline.validate_manifest_shape(url)
        authorized = dict(base, stage05={"aec3DependencyAuthorized": True})
        with self.assertRaises(ValueError):
            baseline.validate_manifest_shape(authorized)

    def test_frozen_legacy_hashes_can_be_verified_after_temporary_outputs_expire(self):
        annotations = [{"sidecar": "one.json"}]
        frozen = [
            {"basename": "one.json", "availabilityAtFreeze": "present", "sha256": "1" * 64, "bytes": 3},
            {
                "basename": baseline.LEGACY_AGGREGATE,
                "availabilityAtFreeze": "present",
                "sha256": "2" * 64,
                "bytes": 4,
            },
        ]
        self.assertEqual(baseline.legacy_output_inventory(annotations, None, frozen), frozen)
        broken = [dict(frozen[0], sha256="bad"), frozen[1]]
        with self.assertRaises(ValueError):
            baseline.legacy_output_inventory(annotations, None, broken)


if __name__ == "__main__":
    unittest.main()
