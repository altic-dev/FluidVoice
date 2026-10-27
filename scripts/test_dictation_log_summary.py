"""Regression fixtures; no app, microphone, or real log access."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from dictation_log_summary import main, parse_logs, render, render_stages, render_terminal_stages, summarize, attach_field_receipts, add_latency_breakdown, render_terminal_latency, render_terminal_delivery, add_delivery_breakdown, add_pipeline_breakdown, render_terminal_pipeline, add_boundary_diagnostics


def row(family, t, event):
    return f"[12:00:00.000] [INFO] {family} t={t} {event}"


class DictationLogSummaryTests(unittest.TestCase):
    def parse(self, *lines):
        return [summarize(run) for run in parse_logs(lines)]

    def test_paste_and_main_callback_are_distinct(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("ASR_BENCH", 1.1, "session=1 first_audio"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("TYPING_BENCH", 2.2, "complete totalMs=16"),
            row("OVERLAY_BENCH", 2.18, "manager finish_hide_request"),
            row("OVERLAY_BENCH", 2.24, "manager finish_hide_complete"),
            row("TYPING_BENCH", 2.4, "delivery_main_begin"),
            row("PIPELINE_SUMMARY", 2.4, "id=A outcome=inserted"),
        )[0]
        self.assertEqual(result["from_stop_ms"]["paste_done"], 200)
        self.assertEqual(result["metrics"]["overlay_after_paste_ms"], 40)
        self.assertEqual(result["metrics"]["callback_queue_ms"], 200)
        self.assertEqual(result["metrics"]["hide_duration_ms"], 60)
        self.assertEqual(result["metrics"]["start_to_pcm_ms"], 100)

    def test_empty_run_never_inherits_paste(self):
        results = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("TYPING_BENCH", 2.1, "complete"),
            row("APP_BENCH", 3, "begin_recording"),
            row("APP_BENCH", 4, "pipeline_begin id=B"),
            row("ASR_BENCH", 4.1, "session=2 final_done textChars=0"),
            row("APP_BENCH", 4.2, "pipeline_handler_return id=B"),
        )
        self.assertEqual(results[1]["outcome"], "empty")
        self.assertIsNone(results[1]["from_stop_ms"]["paste_done"])

    def test_late_id_callback_routes_to_old_run(self):
        results = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 3, "begin_recording"),
            row("PIPELINE_SUMMARY", 3.1, "id=A outcome=inserted"),
            row("OVERLAY_BENCH", 3.2, "manager finish_hide_complete"),
            row("APP_BENCH", 4, "pipeline_begin id=B"),
        )
        self.assertEqual(results[0]["outcome"], "inserted")
        self.assertEqual(results[1]["outcome"], "incomplete")
        self.assertIsNone(results[1]["from_stop_ms"]["hidden"])

    def test_rotation_duplicates_and_restart_are_isolated(self):
        begin = row("APP_BENCH", 1, "begin_recording")
        results = self.parse(begin, begin, row("APP_BENCH", 2, "pipeline_begin id=A"),
                             "[RUN] PID=2", row("PIPELINE_SUMMARY", 3, "id=A outcome=inserted"),
                             row("APP_BENCH", 4, "pipeline_begin id=B"))
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0]["outcome"], "incomplete")
        self.assertTrue(results[1]["partial_start"])

    def test_incomplete_cancelled_and_untimed_markers(self):
        result = self.parse(row("APP_BENCH", 1, "begin_recording"),
                            "ASR_BENCH provider_streaming_done elapsedMs=4",
                            "Cancel shortcut pressed")[0]
        self.assertEqual(result["outcome"], "cancelled")
        self.assertIsNone(result["from_stop_ms"]["hidden"])
        self.assertIn("provider_streaming_done", render([result], details=True))

    def test_superseded_hide_is_not_reported_as_hidden(self):
        result = self.parse(row("APP_BENCH", 1, "begin_recording"),
                            row("APP_BENCH", 2, "pipeline_begin id=A"),
                            row("OVERLAY_BENCH", 2.1, "manager finish_hide_complete outcome=superseded"))[0]
        self.assertIsNone(result["from_stop_ms"]["hidden"])

    def test_internal_model_handoffs_and_context_are_separate(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("ASR_BENCH", 2.01, "session=4 capture_stop_await_begin"),
            row("ASR_BENCH", 2.05, "session=4 capture_stop_await_return"),
            row("ASR_BENCH", 2.06, "session=4 final_executor_request model=parakeet-v3 "
                "samples=80000 vocabEnabled=true vocabTerms=8"),
            row("ASR_BENCH", 2.061, "session=4 final_queue_previous_finished mainThread=false"),
            row("ASR_BENCH", 2.064, "final_executor_begin mainThread=true"),
            "ASR_BENCH provider_final_done samples=80000 audioMs=5000 elapsedMs=91 textChars=40",
            row("ASR_BENCH", 2.155, "final_executor_end"),
            row("ASR_BENCH", 2.16, "session=4 final_done samples=80000 audioMs=5000 textChars=40"),
            row("APP_BENCH", 2.162, "asr_stop_return elapsedMs=162"),
            row("APP_BENCH", 2.164, "processing_ui_requested status=Refining"),
            row("APP_BENCH", 2.165, "ai_process_call id=A provider=FluidIntelligence "
                "model=fluid-1 inputChars=40"),
            row("APP_BENCH", 2.365, "ai_process_return id=A"),
            row("APP_BENCH", 2.367, "text_ready chars=41"),
        )[0]

        self.assertEqual(result["metrics"]["capture_stop_ms"], 40)
        self.assertEqual(result["metrics"]["final_executor_hop_ms"], 3)
        self.assertEqual(result["metrics"]["asr_provider_ms"], 91)
        self.assertEqual(result["metrics"]["asr_to_ai_call_ms"], 3)
        self.assertEqual(result["metrics"]["refining_to_ai_call_ms"], 1)
        self.assertEqual(result["metrics"]["ai_processing_ms"], 200)
        self.assertEqual(result["metrics"]["ai_to_ready_ms"], 2)
        self.assertEqual(result["metrics"]["internal_stop_to_ready_ms"], 367)
        self.assertEqual(result["context"]["audio_ms"], 5000)
        self.assertEqual(result["context"]["samples"], 80000)
        self.assertEqual(result["context"]["asr_model"], "parakeet-v3")
        self.assertEqual(result["context"]["vocab_enabled"], "true")
        self.assertEqual(result["context"]["vocab_terms"], 8)
        self.assertEqual(result["context"]["ai_provider"], "FluidIntelligence")
        self.assertEqual(result["context"]["ai_model"], "fluid-1")

    def test_external_llm_handoff_breakdown(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 2.100, "ai_process_call id=A provider=OpenAI model=gpt-5 inputChars=40"),
            row("APP_BENCH", 2.102, "ai_route_resolved elapsedMs=2"),
            row("LLM_BENCH", 2.105, "id=A call_enter"),
            row("LLM_BENCH", 2.106, "id=A request_built bodyBytes=900"),
            row("LLM_BENCH", 2.107, "id=A attempt_start attempt=1"),
            row("LLM_BENCH", 2.120, "id=A response_headers"),
            row("LLM_BENCH", 2.150, "id=A first_content"),
            row("LLM_BENCH", 2.170, "id=A response_decoded"),
            row("LLM_BENCH", 2.171, "id=A call_return"),
            row("APP_BENCH", 2.172, "ai_process_return id=A"),
        )[0]

        self.assertEqual(result["metrics"]["llm_setup_ms"], 3)
        self.assertEqual(result["metrics"]["llm_request_build_ms"], 1)
        self.assertEqual(result["metrics"]["llm_transport_to_response_ms"], 13)
        self.assertEqual(result["metrics"]["llm_transport_to_first_content_ms"], 43)
        self.assertEqual(result["metrics"]["llm_decode_tail_ms"], 20)
        self.assertEqual(result["metrics"]["llm_return_hop_ms"], 1)
        self.assertIn("External AI handoff detail", render([result]))

    def test_private_fi_summary_uses_low_overhead_completion_log(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 2.100, "ai_process_call id=A provider=fluid-1 model=fluid-1 inputChars=40"),
            "[12:00:00.000] [INFO] [PrivateAIProvider] pipelineID=A Private provider post-processing complete "
            "backend=FluidDecode model=fluid-1 setupMs=1 requestMs=31 returnMs=0 totalMs=30 "
            "prefillMs=8 ttftMs=9 decodeMs=21",
            row("APP_BENCH", 2.140, "ai_process_return id=A"),
        )[0]

        self.assertEqual(result["metrics"]["fi_setup_ms"], 1)
        self.assertEqual(result["metrics"]["fi_request_ms"], 31)
        self.assertEqual(result["metrics"]["fi_model_ms"], 30)
        self.assertEqual(result["metrics"]["fi_prefill_ms"], 8)
        self.assertEqual(result["metrics"]["fi_ttft_ms"], 9)
        self.assertEqual(result["metrics"]["fi_decode_ms"], 21)
        self.assertEqual(result["metrics"]["fi_return_ms"], 0)
        self.assertEqual(result["metrics"]["fi_remaining_handoff_ms"], 8)
        rendered = render([result])
        self.assertIn("Private FI handoff", rendered)
        self.assertIn("| 1.0 | 31.0 | 30.0 | 8.0 | 9.0 | 21.0 |", rendered)

    def test_unrelated_private_api_result_does_not_attach_after_dictation_return(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 2.100, "ai_process_call id=A provider=fluid-1 model=fluid-1 inputChars=40"),
            row("APP_BENCH", 2.140, "ai_process_return id=A"),
            "[12:00:01.000] [INFO] [PrivateAIProvider] Private provider post-processing complete "
            "backend=FluidDecode model=fluid-1 setupMs=1 requestMs=31 returnMs=0 totalMs=30",
        )[0]

        self.assertIsNone(result["metrics"]["fi_request_ms"])

    def test_request_ids_route_every_family_and_reject_unknown_requests(self):
        results = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            row("APP_BENCH", 2, "pipeline_begin id=B pipelineID=B"),
            "pipelineID=A TYPING_BENCH t=2.1 complete",
            "pipelineID=unknown LLM_BENCH t=2.2 call_enter",
            "TYPING_BENCH t=2.3 complete",
            "pipelineID=A DICTATION_SUMMARY asrMs=30 aiMs=-1 readyMs=50 appOverheadMs=20 outcome=success",
        )
        self.assertEqual(results[0]["from_stop_ms"]["paste_done"], 1100)
        self.assertIsNone(results[1]["from_stop_ms"]["paste_done"])
        self.assertIsNone(results[1]["from_stop_ms"]["llm_call_enter"])
        self.assertEqual(results[0]["ready_outcome"], "success")
        self.assertEqual(results[0]["outcome"], "paste done; callback missing")
        self.assertEqual(results[0]["metrics"]["summary_asr_ms"], 30)
        self.assertIsNone(results[0]["metrics"]["summary_ai_ms"])

    def test_single_unlabelled_fi_result_is_not_authoritative(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A"),
            row("APP_BENCH", 1.1, "ai_process_call id=A"),
            "Private provider post-processing complete requestMs=30",
            row("APP_BENCH", 1.2, "ai_process_fail id=A"),
        )[0]
        self.assertIsNone(result["metrics"]["fi_request_ms"])
        self.assertEqual(result["metrics"]["ai_processing_ms"], 100)
        self.assertEqual(result["correlation"], "legacy_proximity_uncertain")

    def test_malformed_numbers_are_missing_not_zero_or_crashes(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A"),
            row("ASR_BENCH", 1.1, "final_done samples=no audioMs=nan textChars=inf"),
        )[0]
        self.assertIsNone(result["context"]["samples"])
        self.assertIsNone(result["context"]["audio_ms"])
        self.assertIsNone(result["context"]["text_chars"])

    def test_terminal_outcomes_are_not_relabelled_as_external_insertion(self):
        for outcome in ("sandbox", "internal_editor", "insertedAndActionDispatched",
                        "insertedActionSuppressed", "actionSuppressed", "rejected", "insertionFailed"):
            with self.subTest(outcome=outcome):
                result = self.parse(
                    row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
                    f"pipelineID=A PIPELINE_SUMMARY t=1.1 id=A outcome={outcome} totalMs=100",
                )[0]
                self.assertEqual(result["outcome"], outcome)
                self.assertEqual(result["metrics"]["stop_to_delivery_ms"], 100)

    def test_asr_timeout_failure_is_not_empty_or_success(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A DICTATION_SUMMARY asrMs=-1 aiMs=-1 readyMs=30000 outcome=asr_failed",
            "pipelineID=A APP_BENCH t=31 pipeline_handler_return id=A",
        )[0]
        self.assertEqual(result["outcome"], "asr_failed")
        self.assertIsNone(result["metrics"]["summary_asr_ms"])
        self.assertIsNone(result["metrics"]["stop_to_delivery_ms"])

    def test_restart_does_not_deduplicate_a_new_recording_with_reused_values(self):
        begin = row("APP_BENCH", 1, "begin_recording")
        results = self.parse(begin, "[RUN] new process", begin)
        self.assertEqual(len(results), 2)

    def test_concurrent_private_results_are_not_misattributed_to_dictation(self):
        result = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("APP_BENCH", 2, "pipeline_begin id=A"),
            row("APP_BENCH", 2.100, "ai_process_call id=A provider=fluid-1 model=fluid-1 inputChars=40"),
            "[12:00:00.000] [INFO] [PrivateAIProvider] Private provider post-processing complete "
            "backend=FluidDecode model=fluid-1 setupMs=1 requestMs=31 returnMs=0 totalMs=30",
            "[12:00:00.010] [INFO] [PrivateAIProvider] Private provider post-processing complete "
            "backend=FluidDecode model=fluid-1 setupMs=1 requestMs=41 returnMs=0 totalMs=40",
            row("APP_BENCH", 2.150, "ai_process_return id=A"),
        )[0]

        self.assertIsNone(result["metrics"]["fi_request_ms"])

    def test_clipboard_timing_separates_request_command_and_restoration(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A APP_BENCH t=1.1 text_ready",
            "pipelineID=A TYPING_BENCH t=1.167 request mode=reliablePaste",
            "pipelineID=A TYPING_BENCH t=1.180 clipboard_snapshot_complete elapsedMs=2",
            "pipelineID=A TYPING_BENCH t=1.181 clipboard_write generation=5 elapsedMs=1",
            "pipelineID=A TYPING_BENCH t=1.182 command_posted generation=5 totalMs=4",
            "pipelineID=A TYPING_BENCH t=1.882 restore_completed generation=5 success=true",
        )[0]
        self.assertEqual(result["context"]["insertion_mode"], "reliablePaste")
        self.assertEqual(result["metrics"]["ready_to_request_ms"], 67)
        self.assertEqual(result["metrics"]["request_to_command_ms"], 15)
        self.assertEqual(result["metrics"]["clipboard_snapshot_ms"], 2)
        self.assertEqual(result["metrics"]["clipboard_write_ms"], 1)
        self.assertEqual(result["metrics"]["clipboard_command_total_ms"], 4)
        self.assertEqual(result["metrics"]["command_to_restore_ms"], 700)
        self.assertIsNone(result["metrics"]["typing_queue_ms"])
        self.assertEqual(result["clipboard_uptime"]["command_posted"], 1.182)
        self.assertEqual(result["context"]["clipboard_command_status"], "command_posted")
        self.assertEqual(result["context"]["clipboard_settlement_status"], "restored")
        self.assertIn("| reliablePaste | 67.0 | 15.0 | 2.0 | 1.0 | 4.0 | 700.0 |", render([result]))

    def test_absent_mode_or_command_is_unknown_and_direct_mode_is_preserved(self):
        results = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A"),
            row("TYPING_BENCH", 1.1, "request"),
            row("APP_BENCH", 2, "pipeline_begin id=B"),
            row("TYPING_BENCH", 2.1, "request mode=standard"),
            row("TYPING_BENCH", 2.2, "complete totalMs=100"),
        )
        self.assertIsNone(results[0]["context"]["insertion_mode"])
        self.assertEqual(results[1]["context"]["insertion_mode"], "standard")
        for result in results:
            self.assertIsNone(result["metrics"]["request_to_command_ms"])
            self.assertIsNone(result["metrics"]["clipboard_command_total_ms"])
            self.assertIsNone(result["context"]["clipboard_settlement_status"])

    def test_late_clipboard_restore_uses_pipeline_and_command_generation(self):
        results = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A TYPING_BENCH t=1.1 request mode=reliablePaste",
            "pipelineID=A TYPING_BENCH t=1.2 command_posted generation=5 totalMs=1",
            row("APP_BENCH", 1.3, "begin_recording"),
            row("APP_BENCH", 1.4, "pipeline_begin id=B pipelineID=B"),
            "pipelineID=A TYPING_BENCH t=1.5 restore_completed generation=99 success=true",
            "pipelineID=A TYPING_BENCH t=1.9 restore_completed generation=5 success=false",
        )
        self.assertEqual(results[0]["metrics"]["command_to_restore_ms"], 700)
        self.assertEqual(results[0]["context"]["clipboard_settlement_status"], "restore_failed")
        self.assertEqual(results[0]["clipboard_uptime"]["clipboard_restore"], 1.9)
        self.assertIsNone(results[1]["metrics"]["command_to_restore_ms"])
        self.assertIsNone(results[1]["clipboard_uptime"]["clipboard_restore"])

    def test_clipboard_changed_skip_is_not_successful_restoration(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A TYPING_BENCH t=1.2 command_posted generation=3 totalMs=1",
            "pipelineID=A TYPING_BENCH t=1.9 settlement_skipped generation=3 reason=clipboard_changed",
        )[0]
        self.assertIsNone(result["metrics"]["command_to_restore_ms"])
        self.assertEqual(result["metrics"]["command_to_clipboard_change_skip_ms"], 700)
        self.assertEqual(result["context"]["clipboard_settlement_status"], "skipped_clipboard_changed")
        self.assertEqual(result["clipboard_uptime"]["clipboard_change_skipped"], 1.9)

    def test_untimed_clipboard_duration_does_not_invent_command_timestamp(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A TYPING_BENCH command_posted generation=3 totalMs=1",
            "pipelineID=A TYPING_BENCH t=1.9 restore_completed generation=3 success=true",
        )[0]
        self.assertEqual(result["metrics"]["clipboard_command_total_ms"], 1)
        self.assertIsNone(result["metrics"]["command_to_restore_ms"])
        self.assertIsNone(result["clipboard_uptime"]["command_posted"])

    def test_measured_focus_queue_and_timer_work_remain_separate(self):
        results = self.parse(
            row("APP_BENCH", 1.025, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=1.0"),
            "pipelineID=A APP_BENCH t=1.1 text_ready",
            "pipelineID=A APP_BENCH t=1.167 focus_target_check totalMs=67.0 pidMs=2.5 elementMs=64.0",
            "pipelineID=A TYPING_BENCH t=1.168 request mode=reliablePaste",
            "pipelineID=A TYPING_BENCH t=1.198 clipboard_slot_acquired generation=5 waitMs=30.0",
            "pipelineID=A TYPING_BENCH t=1.2 command_posted generation=5 totalMs=2",
            row("APP_BENCH", 1.3, "pipeline_begin id=B pipelineID=B toggleStopRequestedAt=nil"),
            "pipelineID=A TYPING_BENCH t=1.75 settlement_begin generation=99 elapsedMs=550 scheduledDelayMs=500",
            "pipelineID=A TYPING_BENCH t=1.8 settlement_begin generation=5 elapsedMs=599.5 scheduledDelayMs=500",
            "pipelineID=A TYPING_BENCH t=1.85 restore_completed generation=5 success=true elapsedMs=49.5",
        )
        metrics = results[0]["metrics"]
        self.assertEqual(metrics["toggle_callback_to_handler_ms"], 25)
        self.assertEqual(metrics["focus_check_ms"], 67)
        self.assertEqual(metrics["focus_pid_ms"], 2.5)
        self.assertEqual(metrics["focus_element_ms"], 64)
        self.assertEqual(metrics["clipboard_slot_wait_ms"], 30)
        self.assertEqual(metrics["request_to_command_ms"], 32)
        self.assertEqual(metrics["clipboard_command_total_ms"], 2)
        self.assertEqual(metrics["clipboard_settlement_scheduled_ms"], 500)
        self.assertEqual(metrics["clipboard_settlement_wait_ms"], 599.5)
        self.assertEqual(metrics["clipboard_restore_work_ms"], 49.5)
        self.assertEqual(metrics["command_to_restore_ms"], 650)
        self.assertIsNone(results[1]["metrics"]["clipboard_restore_work_ms"])
        self.assertIsNone(results[1]["metrics"]["toggle_callback_to_handler_ms"])
        self.assertIn("| 25.0 | 67.0 | 2.5 | 64.0 | 30.0 | 500.0 | 599.5 | 49.5 |", render(results))

    def test_missing_measured_subphases_are_not_inferred_from_totals(self):
        result = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A APP_BENCH t=1.1 focus_target_check totalMs=0.1 missingContext=true",
            "pipelineID=A TYPING_BENCH t=1.2 request mode=reliablePaste",
            "pipelineID=A TYPING_BENCH t=1.3 command_posted generation=5 totalMs=2",
            "pipelineID=A TYPING_BENCH t=1.9 restore_completed generation=5 success=true",
        )[0]
        self.assertEqual(result["metrics"]["focus_check_ms"], 0.1)
        self.assertEqual(result["context"]["focus_missing_context"], "true")
        for key in ("toggle_callback_to_handler_ms", "focus_pid_ms", "focus_element_ms",
                    "clipboard_slot_wait_ms", "clipboard_settlement_wait_ms",
                    "clipboard_settlement_scheduled_ms", "clipboard_restore_work_ms"):
            self.assertIsNone(result["metrics"][key], key)
        self.assertEqual(result["metrics"]["command_to_restore_ms"], 600)

    def test_intentional_copy_work_and_failed_delivery_queue_are_measured(self):
        results = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A TYPING_BENCH t=1.1 command_posted generation=5 totalMs=1",
            "pipelineID=A TYPING_BENCH t=1.7 settlement_begin generation=5 elapsedMs=600 scheduledDelayMs=500",
            "pipelineID=A TYPING_BENCH t=1.702 intentional_copy_settled generation=5 success=true elapsedMs=1.8",
            row("APP_BENCH", 2, "pipeline_begin id=B pipelineID=B"),
            "pipelineID=B TYPING_BENCH t=2.1 clipboard_slot_acquired generation=6 waitMs=9.5",
            "pipelineID=B TYPING_BENCH t=2.2 delivery_failed generation=6 reason=clipboard_snapshot_failed",
        )
        self.assertEqual(results[0]["metrics"]["clipboard_intentional_copy_work_ms"], 1.8)
        self.assertIsNone(results[0]["metrics"]["clipboard_restore_work_ms"])
        self.assertEqual(results[1]["metrics"]["clipboard_slot_wait_ms"], 9.5)
        self.assertIsNone(results[1]["metrics"]["clipboard_command_total_ms"])

    def test_stages_render_separates_recording_start_and_nested_stop_metrics(self):
        results = self.parse(
            row("APP_BENCH", 1, "begin_recording"),
            row("ASR_BENCH", 1.015, "first_audio"),
            row("APP_BENCH", 2, "pipeline_begin id=A pipelineID=A"),
            "pipelineID=A APP_BENCH t=2.01 asr_stop_call",
            "pipelineID=A APP_BENCH t=2.06 asr_stop_return",
            "pipelineID=A TYPING_BENCH t=2.2 command_posted generation=1 totalMs=1",
            row("APP_BENCH", 3, "pipeline_begin id=B pipelineID=B"),
        )
        text = render_stages(results)
        self.assertIn("| Recording start → first PCM (separate) | 15.0 | — |", text)
        self.assertIn("| Stop handler → command dispatch | 200.0 | — |", text)
        self.assertIn("| ASR stop call total | 50.0 | — |", text)
        self.assertIn("Nested stages overlap and are not additive", text)

    def test_stages_cli_uses_explicit_log_and_last(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.log"
            fixture.write_text("\n".join([
                row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
                row("APP_BENCH", 2, "pipeline_begin id=B pipelineID=B"),
                "pipelineID=B TYPING_BENCH t=2.1 request mode=reliablePaste",
            ]))
            output = io.StringIO()
            with patch("sys.argv", ["dictation_log_summary.py", "--log", str(fixture), "--last", "1", "--stages"]):
                with contextlib.redirect_stdout(output):
                    main()
            rendered = output.getvalue()
            self.assertIn("DICTATION TIMINGS", rendered)
            self.assertIn(" B  reliablePaste", rendered)
            self.assertNotIn(" A ", rendered)
            self.assertIn("┌", rendered)
            self.assertIn("Stage (ms)", rendered)
            with patch("sys.argv", ["dictation_log_summary.py", "--log", str(fixture), "--last", "1", "--stages", "--markdown"]):
                with contextlib.redirect_stdout(io.StringIO()) as markdown:
                    main()
            self.assertIn("# Dictation stages", markdown.getvalue())
            self.assertIn("| Insertion mode | reliablePaste |", markdown.getvalue())

    def test_terminal_tables_fit_width_and_preserve_every_recording(self):
        results = self.parse(*(row("APP_BENCH", i, f"pipeline_begin id=RUN{i} pipelineID=RUN{i}")
                               for i in range(1, 7)))
        for width in (40, 60, 80, 120, 200):
            with self.subTest(width=width):
                output = render_terminal_stages(results, width=width)
                self.assertTrue(all(len(line) <= width for line in output.splitlines()))
                for index in range(1, 7):
                    self.assertIn(f"#{index} ", output)
                    self.assertIn(f"RUN{index}", output)
                self.assertEqual(output.count("┌"), output.count("└"))
                # Every row inside each bordered table must stay aligned.
                for table in output.split("┌")[1:]:
                    body = table.split("└")[0].splitlines()
                    self.assertTrue(all(len(line) == len(body[0]) + 1 for line in body[1:]))

    def test_terminal_preserves_zero_unknown_and_large_values(self):
        results = self.parse(row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"))
        results[0]["metrics"]["clipboard_slot_wait_ms"] = 0
        results[0]["metrics"]["ai_processing_ms"] = 123456.7
        output = render_terminal_stages(results, width=80)
        self.assertRegex(output, r"Clipboard slot wait[^\n]+0\.0")
        self.assertRegex(output, r"AI processing[^\n]+123456\.7")
        self.assertRegex(output, r"Clipboard snapshot[^\n]+—")
        self.assertIn("Nested stages overlap", output)

    def latency_fixture(self, pipeline="A", pid=42):
        return self.parse(
            row("APP_BENCH", 1.02, f"pipeline_begin id={pipeline} pipelineID={pipeline} toggleStopRequestedAt=1.01"),
            f"pipelineID={pipeline} APP_BENCH t=1.03 asr_stop_call",
            f"pipelineID={pipeline} APP_BENCH t=1.13 asr_stop_return",
            f"pipelineID={pipeline} APP_BENCH t=1.14 ai_process_call",
            f"pipelineID={pipeline} APP_BENCH t=1.24 ai_process_return",
            f"pipelineID={pipeline} APP_BENCH t=1.25 text_ready",
            f"pipelineID={pipeline} TYPING_BENCH t=1.27 request chars=5 mode=reliablePaste preferredPID={pid}",
            f"pipelineID={pipeline} TYPING_BENCH t=1.28 command_posted generation=1 totalMs=10",
        )

    def receipt_fixture(self, **changes):
        events = [dict(event="stop_pressed", t=1.0, run_id="test", target_pid=42),
                  dict(event="field_received", t=1.3, run_id="test", target_pid=42, chars=5)]
        events[1].update(changes)
        return [json.dumps(e) for e in events]

    def test_stop_to_field_partitions_all_time_and_excludes_background(self):
        rows = self.latency_fixture()
        attach_field_receipts(rows, self.receipt_fixture())
        add_latency_breakdown(rows)
        m = rows[0]["latency"]
        self.assertEqual(m["total_ms"], 300)
        self.assertEqual(m["sent_ms"], 270)
        self.assertEqual(m["input_ms"], 10)
        self.assertEqual(m["receiver_ms"], 20)
        self.assertEqual(m["unattributed_ms"], 0)
        self.assertEqual(sum(v for k, v in m.items() if k not in ("total_ms", "sent_ms") and v is not None), 300)
        output = render_terminal_latency(rows, width=80)
        table = output.split("┌", 1)[1].split("└", 1)[0]
        self.assertNotIn("PCM", table)
        self.assertNotIn("Restore", table)
        self.assertNotIn("Overlay", table)
        self.assertIn("300.0", table)

    def test_missing_receipt_never_claims_end_to_end(self):
        rows = self.latency_fixture()
        add_latency_breakdown(rows)
        self.assertIsNone(rows[0]["latency"]["total_ms"])
        self.assertIsNone(rows[0]["latency"]["receiver_ms"])
        self.assertEqual(rows[0]["latency"]["sent_ms"], 270)

    def test_reject_wrong_target_partial_text_and_stale_receipts(self):
        for changes in ({"target_pid": 9}, {"chars": 4}, {"t": 0.5}, {"t": 40},
                        {"event": "field_mismatch"}, {"t": float("nan")}):
            with self.subTest(changes=changes):
                rows = self.latency_fixture()
                attach_field_receipts(rows, self.receipt_fixture(**changes))
                self.assertNotIn("field_receipt", rows[0])
        rows = self.latency_fixture()
        logs = self.receipt_fixture() + [json.dumps(dict(event="timeout", t=1.4, run_id="test", target_pid=42))]
        attach_field_receipts(rows, logs)
        self.assertNotIn("field_receipt", rows[0])

    def test_ambiguous_pipeline_or_duplicate_test_is_not_a_measurement(self):
        rows = self.latency_fixture() + self.latency_fixture(pipeline="B")
        attach_field_receipts(rows, self.receipt_fixture())
        self.assertTrue(all("field_receipt" not in r for r in rows))
        rows = self.latency_fixture()
        logs = self.receipt_fixture()
        attach_field_receipts(rows, logs + [line.replace('"test"', '"second"') for line in logs])
        self.assertNotIn("field_receipt", rows[0])

    def test_missing_ai_markers_count_as_unattributed_not_zero(self):
        rows = self.latency_fixture()
        rows[0]["phase_uptime"]["ai_call"] = None
        rows[0]["phase_uptime"]["ai_return"] = None
        attach_field_receipts(rows, self.receipt_fixture())
        add_latency_breakdown(rows)
        m = rows[0]["latency"]
        self.assertEqual(m["total_ms"], 300)
        self.assertEqual(m["unattributed_ms"], 120)
        self.assertIsNone(m["ai_ms"])

    def test_receipt_before_dispatch_log_does_not_make_negative_latency(self):
        rows = self.latency_fixture()
        attach_field_receipts(rows, self.receipt_fixture(t=1.275))
        add_latency_breakdown(rows)
        m = rows[0]["latency"]
        self.assertEqual(m["total_ms"], 275)
        self.assertIsNone(m["receiver_ms"])
        self.assertIsNone(m["insertion_ms"])
        self.assertEqual(m["unattributed_ms"], 5)


    def test_delivery_only_partitions_ready_to_dispatch(self):
        rows = self.latency_fixture()
        p = rows[0]["phase_uptime"]
        p.update(clipboard_slot_acquired=1.271, clipboard_snapshot_complete=1.274, clipboard_write=1.278)
        add_delivery_breakdown(rows)
        m = rows[0]["delivery"]
        self.assertEqual(m, dict(prepare_ms=20, queue_ms=1, snapshot_ms=3, write_ms=4,
                                dispatch_ms=2, unattributed_ms=0, total_ms=30))
        self.assertEqual(sum(v for k,v in m.items() if k != "total_ms"), m["total_ms"])
        output = render_terminal_delivery(rows, width=80)
        table = output.split("┌",1)[1].split("└",1)[0]
        self.assertIn("30.00", table)
        self.assertNotIn("AI", table)
        self.assertNotIn("PCM", table)
        self.assertNotIn("field confirmed", table)
        self.assertNotIn("Restore timer", table)

    def test_delivery_missing_markers_and_failed_dispatch_stay_honest(self):
        rows = self.latency_fixture()
        add_delivery_breakdown(rows)
        m = rows[0]["delivery"]
        self.assertEqual(m["total_ms"], 30)
        self.assertEqual(m["unattributed_ms"], 10)
        self.assertIsNone(m["snapshot_ms"])
        rows[0]["phase_uptime"]["command_posted"] = None
        add_delivery_breakdown(rows)
        self.assertIsNone(rows[0]["delivery"]["total_ms"])

    def test_full_timeline_counts_every_stage_once(self):
        rows = self.latency_fixture()
        p = rows[0]["phase_uptime"]
        p.update(clipboard_slot_acquired=1.271, clipboard_snapshot_complete=1.274, clipboard_write=1.278)
        # Neither a receiving-field timestamp nor later clipboard restoration changes this endpoint.
        rows[0]["field_receipt"] = dict(stop=1.0, received=1.9)
        p["clipboard_restore"] = 2.5
        add_pipeline_breakdown(rows)
        m = rows[0]["pipeline"]
        self.assertEqual(m["total_ms"], 270)
        self.assertEqual(m["stop_queue_ms"], 10)
        self.assertEqual(m["asr_ms"], 100)
        self.assertEqual(m["ai_ms"], 100)
        self.assertEqual(m["unattributed_ms"], 0)
        self.assertEqual(sum(v for k,v in m.items() if k != "total_ms" and v is not None), 270)

    def test_full_timeline_exposes_active_chunk_wait_without_double_counting_asr(self):
        rows = self.latency_fixture()
        rows[0]["phase_uptime"].update(capture_stop_begin=1.031, capture_stop_return=1.041,
            streaming_drain_end=1.09, final_executor_begin=1.10, final_executor_end=1.12)
        add_pipeline_breakdown(rows)
        m = rows[0]["pipeline"]
        self.assertIsNone(m["asr_ms"])
        self.assertEqual(m["capture_stop_ms"], 10)
        self.assertEqual(m["streaming_drain_ms"], 49)
        self.assertEqual(m["final_asr_ms"], 20)
        self.assertEqual(sum(v for k,v in m.items() if k != "total_ms" and v is not None), 270)
        self.assertIn("Wait for active transcription chunk", render_terminal_pipeline(rows, width=80))

    def test_full_timeline_multiple_output_steps_and_failure(self):
        rows = self.latency_fixture()
        rows[0]["events"].append(dict(family="TYPING_BENCH", name="command_posted", t=1.9, fields={}))
        add_pipeline_breakdown(rows)
        self.assertEqual(rows[0]["pipeline"]["total_ms"], 890)
        self.assertEqual(rows[0]["pipeline"]["remaining_output_ms"], 620)
        rows[0]["events"].append(dict(family="TYPING_BENCH", name="delivery_failed", t=1.91, fields={}))
        add_pipeline_breakdown(rows)
        self.assertIsNone(rows[0]["pipeline"]["total_ms"])
        self.assertEqual(rows[0]["pipeline"]["ai_ms"], 100)

    def test_default_cli_is_full_timeline_and_all_includes_each_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "fixture.log"
            log.write_text("\n".join([row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A"),
                                      row("APP_BENCH", 2, "pipeline_begin id=B pipelineID=B")]))
            with patch("sys.argv", ["dictation_log_summary.py", "--log", str(log), "--last", "1", "--all"]):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    main()
            text = output.getvalue()
            self.assertIn("FULL TIMELINE: STOP", text)
            self.assertIn(" A ", text)
            self.assertIn(" B ", text)
            self.assertNotIn("TOTAL: Text ready", text)

    def boundary_fixture(self, *extra):
        return self.parse(
            row("HOTKEY_BENCH", 1.01, "stop_request stopRequestedAt=1.01 inputReceivedAt=1.0 inputAgeMs=5 pressReceivedAt=0.9 route=toggle eventType=flagsChanged"),
            row("APP_BENCH", 1.02, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=1.01"),
            row("TYPING_BENCH", 1.28, "command_posted pipelineID=A"),
            row("OVERLAY_BENCH", 1.36, "manager finish_hide_complete pipelineID=A"),
            row("APP_BENCH", 1.37, "pipeline_handler_return pipelineID=A"),
            row("APP_BENCH", 1.38, "dispatch_main_queue_probe scheduledAt=1.281 pipelineID=A"),
            row("OVERLAY_BENCH", 1.47, "bottom_hide_immediate_cleanup_complete pipelineID=A"),
            *extra,
        )

    def test_input_and_post_dispatch_boundaries_do_not_inflate_pipeline_total(self):
        rows = self.boundary_fixture()
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertEqual(rows[0]["pipeline"]["total_ms"], 270)
        self.assertEqual(rows[0]["boundaries"], dict(
            os_event_to_dispatch_ms=285, input_delivery_ms=5, input_to_request_ms=10,
            held_key_ms=100, stop_to_hidden_ms=350, stop_to_handler_return_ms=360,
            stop_to_cleanup_ms=460, dispatch_to_hidden_ms=80,
            dispatch_main_queue_wait_ms=99, dispatch_to_visible_ms=None))

    def test_hotkey_matching_is_exact_unique_and_reset_at_process_restart(self):
        prefix = row("HOTKEY_BENCH", 1.01, "stop_request stopRequestedAt=1.01 inputReceivedAt=1.0 inputAgeMs=5")
        pipeline = row("APP_BENCH", 1.02, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=1.01")
        for lines in ((prefix, pipeline.replace("At=1.01", "At=1.0101")),
                      (prefix, "[RUN] new process", pipeline),
                      (prefix, prefix.replace("inputAgeMs=5", "inputAgeMs=6"), pipeline),
                      (prefix, pipeline, pipeline.replace("id=A", "id=B").replace("pipelineID=A", "pipelineID=B"))):
            with self.subTest(lines=lines):
                rows = self.parse(*lines)
                add_pipeline_breakdown(rows)
                add_boundary_diagnostics(rows)
                self.assertTrue(all(r["boundaries"]["input_to_request_ms"] is None for r in rows))
        # A delayed log line routes to A even after a newer B recording began.
        rows = self.parse(pipeline,
                          pipeline.replace("id=A", "id=B").replace("pipelineID=A", "pipelineID=B").replace("At=1.01", "At=2.01"),
                          prefix)
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertEqual(rows[0]["boundaries"]["input_to_request_ms"], 10)
        self.assertIsNone(rows[1]["boundaries"]["input_to_request_ms"])

    def test_missing_invalid_or_future_input_does_not_create_total(self):
        for changes in ({"inputAgeMs": None}, {"inputAgeMs": "nan"},
                        {"inputAgeMs": "-1"}, {"inputReceivedAt": "1.1"},
                        {"inputReceivedAt": "inf"}, {"stopRequestedAt": "1.011"}):
            with self.subTest(changes=changes):
                rows = self.boundary_fixture()
                event = next(e for e in rows[0]["events"] if e["family"] == "HOTKEY_BENCH")
                event["fields"].update(changes)
                add_pipeline_breakdown(rows)
                add_boundary_diagnostics(rows)
                self.assertIsNone(rows[0]["boundaries"]["os_event_to_dispatch_ms"])
        rows = self.boundary_fixture()
        event = next(e for e in rows[0]["events"] if e["family"] == "HOTKEY_BENCH")
        event["fields"]["pressReceivedAt"] = "1.1"
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertIsNone(rows[0]["boundaries"]["held_key_ms"])
        self.assertEqual(rows[0]["boundaries"]["os_event_to_dispatch_ms"], 285)

    def test_cancelled_and_failed_delivery_have_no_boundary_success_endpoint(self):
        for cancelled in (False, True):
            rows = self.boundary_fixture()
            if cancelled:
                rows[0]["outcome"] = "cancelled"
            else:
                rows[0]["events"].append(dict(family="TYPING_BENCH", name="delivery_failed", t=1.29, fields={}))
            add_pipeline_breakdown(rows)
            add_boundary_diagnostics(rows)
            self.assertIsNone(rows[0]["boundaries"]["os_event_to_dispatch_ms"])
            self.assertIsNone(rows[0]["boundaries"]["stop_to_cleanup_ms"])
            self.assertIsNone(rows[0]["boundaries"]["dispatch_main_queue_wait_ms"])
            self.assertEqual(rows[0]["boundaries"]["input_to_request_ms"], 10)

    def test_pre_dispatch_stale_and_ambiguous_probe_markers_stay_unknown(self):
        rows = self.boundary_fixture()
        rows[0]["phase_uptime"]["hidden"] = 1.1
        probe = next(e for e in rows[0]["events"] if e["name"] == "dispatch_main_queue_probe")
        probe["fields"]["scheduledAt"] = "1.27"
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertIsNone(rows[0]["boundaries"]["dispatch_to_hidden_ms"])
        self.assertIsNone(rows[0]["boundaries"]["stop_to_hidden_ms"])
        self.assertIsNone(rows[0]["boundaries"]["dispatch_main_queue_wait_ms"])
        rows = self.boundary_fixture(row("APP_BENCH", 1.39, "dispatch_main_queue_probe scheduledAt=1.281 pipelineID=A"))
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertIsNone(rows[0]["boundaries"]["dispatch_main_queue_wait_ms"])
        # Unlabelled or foreign IDs cannot contaminate a correlated run.
        rows = self.parse(row("APP_BENCH", 1.02, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=1.01"),
                          row("TYPING_BENCH", 1.28, "command_posted pipelineID=A"),
                          row("APP_BENCH", 1.38, "dispatch_main_queue_probe scheduledAt=1.281 pipelineID=OLD"),
                          row("APP_BENCH", 1.39, "dispatch_main_queue_probe scheduledAt=1.281"))
        add_pipeline_breakdown(rows)
        add_boundary_diagnostics(rows)
        self.assertIsNone(rows[0]["boundaries"]["dispatch_main_queue_wait_ms"])

    def test_boundary_tables_fit_terminal_and_markdown_export_includes_notes(self):
        for width in (40, 60, 80, 120, 200):
            output = render_terminal_pipeline(self.boundary_fixture(), width=width)
            self.assertTrue(all(len(line) <= width for line in output.splitlines()))
            self.assertIn("BOUNDARY DIAGNOSTICS", output)
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "fixture.log"
            log.write_text(row("APP_BENCH", 1.02, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=1.01"))
            with patch("sys.argv", ["dictation_log_summary.py", "--log", str(log), "--markdown"]):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    main()
            self.assertIn("## Boundary diagnostics (overlapping)", output.getvalue())
            self.assertIn("do not add these rows", output.getvalue())
            self.assertIn("| Dispatch → text visibly entered | — |", output.getvalue())

    def direct_completion_fixture(self, completion=1.3, callback_result="", *extra):
        return self.parse(
            row("APP_BENCH", 1.0, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=0.9"),
            row("APP_BENCH", 1.1, "text_ready pipelineID=A"),
            row("TYPING_BENCH", 1.2, "request mode=direct pipelineID=A"),
            row("TYPING_BENCH", completion, "complete result=commandPosted pipelineID=A"),
            row("TYPING_BENCH", 1.8, "asr_type_dispatched pipelineID=A " + callback_result),
            *extra,
        )

    def test_direct_normal_and_spoken_send_end_before_later_callback(self):
        for callback_result in ("result=commandPosted", ""):
            with self.subTest(callback_result=callback_result):
                rows = self.direct_completion_fixture(callback_result=callback_result)
                add_pipeline_breakdown(rows)
                self.assertEqual(rows[0]["pipeline"]["total_ms"], 400)
                self.assertEqual(rows[0]["dispatch_uptime"], 1.3)
                self.assertNotEqual(rows[0]["pipeline"]["total_ms"], 900)

    def test_direct_invalid_missing_or_future_completion_is_not_an_endpoint(self):
        for timestamp in (None, float("nan"), float("inf"), -1, 1.15, 2.0):
            with self.subTest(timestamp=timestamp):
                rows = self.direct_completion_fixture(completion=timestamp)
                add_pipeline_breakdown(rows)
                self.assertIsNone(rows[0]["pipeline"]["total_ms"])
        rows = self.direct_completion_fixture()
        rows[0]["events"] = [e for e in rows[0]["events"] if e["name"] != "complete"]
        add_pipeline_breakdown(rows)
        self.assertIsNone(rows[0]["pipeline"]["total_ms"])

    def test_direct_failed_completion_and_cancellation_suppress_success(self):
        for failure in ("cancel", "delivery_failed", "recoverableFailure(pasteCommandFailed)"):
            rows = self.direct_completion_fixture()
            if failure == "cancel":
                rows[0]["outcome"] = "cancelled"
            else:
                rows[0]["events"].append(dict(family="TYPING_BENCH", t=1.4,
                    name="delivery_failed" if failure == "delivery_failed" else "complete",
                    fields={} if failure == "delivery_failed" else {"result": failure}))
            add_pipeline_breakdown(rows)
            self.assertIsNone(rows[0]["pipeline"]["total_ms"])

    def test_direct_completion_requires_correlation_and_late_id_returns_to_original_run(self):
        for scope in ("", "pipelineID=UNKNOWN"):
            rows = self.parse(
                row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=0.9"),
                row("TYPING_BENCH", 1.3, "complete result=commandPosted " + scope))
            add_pipeline_breakdown(rows)
            self.assertIsNone(rows[0]["pipeline"]["total_ms"])
        rows = self.parse(
            row("APP_BENCH", 1, "pipeline_begin id=A pipelineID=A toggleStopRequestedAt=0.9"),
            row("APP_BENCH", 2, "pipeline_begin id=B pipelineID=B toggleStopRequestedAt=1.9"),
            row("TYPING_BENCH", 1.3, "complete result=commandPosted pipelineID=A"))
        add_pipeline_breakdown(rows)
        self.assertEqual(rows[0]["pipeline"]["total_ms"], 400)
        self.assertIsNone(rows[1]["pipeline"]["total_ms"])

    def test_clipboard_and_injection_return_keep_precedence_over_completion(self):
        rows = self.direct_completion_fixture()
        rows[0]["events"].append(dict(family="TYPING_BENCH", name="command_posted", t=1.25, fields={}))
        add_pipeline_breakdown(rows)
        self.assertEqual(rows[0]["dispatch_uptime"], 1.25)
        rows = self.direct_completion_fixture()
        rows[0]["phase_uptime"]["injection_return"] = 1.26
        add_pipeline_breakdown(rows)
        self.assertEqual(rows[0]["dispatch_uptime"], 1.26)

    def test_delivery_and_pipeline_suppress_same_failed_or_cancelled_run(self):
        for failure in ("cancel", "delivery_failed", "recoverableFailure(pasteCommandFailed)"):
            rows = self.latency_fixture()
            if failure == "cancel":
                rows[0]["outcome"] = "cancelled"
            else:
                rows[0]["events"].append(dict(family="TYPING_BENCH", t=1.4,
                    name="delivery_failed" if failure == "delivery_failed" else "complete",
                    fields={} if failure == "delivery_failed" else {"result": failure}))
            add_pipeline_breakdown(rows)
            add_delivery_breakdown(rows)
            self.assertIsNone(rows[0]["pipeline"]["total_ms"])
            self.assertIsNone(rows[0]["delivery"]["total_ms"])


if __name__ == "__main__":
    unittest.main()
