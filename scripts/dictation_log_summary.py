#!/usr/bin/env python3
"""Read-only, standard-library summary of recent FluidVoice dictation timings.

Usage: python3 scripts/dictation_log_summary.py --last 5 [--stages]
Use --markdown for Markdown export, --details for marker details, --json for data.
Reads Fluid.log.1 then Fluid.log. Explicit paths are accepted with --log PATH.
No recording, playback, app activation, or file writes are performed.
"""

import argparse
import json
import math
import re
import statistics
import shutil
import textwrap
from pathlib import Path


MARKER = re.compile(
    r"\b(HOTKEY_BENCH|APP_BENCH|ASR_BENCH|FI_SERVICE_BENCH|FI_BRIDGE_BENCH|LLM_BENCH|OVERLAY_BENCH|TYPING_BENCH|HISTORY_BENCH|PIPELINE_SUMMARY|DICTATION_SUMMARY)\b(.*)"
)
FIELD = re.compile(r"(?:^|\s)(\w+)=([^\s]+)")
WALL = re.compile(r"^\[([\d:.]+)\]")


def parse_logs(lines):
    """Group at recording boundaries; never reuse a previous run's timings.

    Late ID-bearing callbacks are routed back to their original pipeline.
    Unlabelled tail events after a rapid restart cannot be safely attributed;
    keep them in the timeline but exclude pre-stop events from stop metrics.
    App restarts reset correlation even when IDs/session numbers are reused.
    """
    runs, by_id, current, seen = [], {}, None, set()
    session_runs, stop_requests = [], []

    def stop_key(value):
        try:
            value = float(value)
            return value if math.isfinite(value) and value >= 0 else None
        except (TypeError, ValueError):
            return None

    def attach_stop_requests():
        # Hotkey events precede pipeline IDs. Only exact, unique stop-request
        # timestamps within this process session establish identity.
        targets, requests = {}, {}
        for run in session_runs:
            for event in run["events"]:
                if event["family"] == "APP_BENCH" and event["name"] == "pipeline_begin":
                    key = stop_key(event["fields"].get("toggleStopRequestedAt"))
                    if key is not None:
                        targets.setdefault(key, []).append(run)
        for event in stop_requests:
            key = stop_key(event["fields"].get("stopRequestedAt"))
            if key is not None:
                requests.setdefault(key, []).append(event)
        for key, candidates in requests.items():
            matches = targets.get(key, [])
            if len(candidates) == 1 and len(matches) == 1:
                matches[0]["events"].append(candidates[0])

    for line in lines:
        if line.startswith("[RUN]"):
            attach_stop_requests()
            session_runs, stop_requests = [], []
            current, by_id = None, {}
            seen.clear()
            continue
        if line in seen:
            continue  # overlapping rotated snapshots
        seen.add(line)
        match = MARKER.search(line)
        private_result = "Private provider post-processing complete" in line
        if not match and not private_result:
            if current and ("Cancel shortcut pressed" in line or "stopWithoutTranscription" in line):
                current["cancelled"] = True
            continue
        if private_result:
            family, body = "FI_RESULT", line.split("Private provider post-processing complete", 1)[1]
        else:
            family, body = match.groups()
        fields = dict(FIELD.findall(body))
        correlation = dict(FIELD.findall(line)).get("pipelineID")
        words = [part for part in body.split() if "=" not in part]
        name = "complete" if family == "FI_RESULT" else (
            " ".join(words) if family not in ("PIPELINE_SUMMARY", "DICTATION_SUMMARY") else "summary"
        )
        try:
            timestamp = float(fields["t"])
        except (KeyError, ValueError):
            timestamp = None
        event = {"family": family, "name": name, "t": timestamp,
                 "pipeline_id": correlation,
                 "fields": {k: v for k, v in fields.items() if k != "t"}}
        if family == "HOTKEY_BENCH":
            if name == "stop_request":
                stop_requests.append(event)
            continue
        if family == "APP_BENCH" and name == "begin_recording":
            wall = WALL.match(line)
            current = {"id": None, "time": wall.group(1) if wall else "?",
                       "events": [], "cancelled": False, "partial_start": False}
            runs.append(current)
            session_runs.append(current)
        if family == "APP_BENCH" and name == "pipeline_begin":
            if current is None or current["id"] is not None:
                current = {"id": None, "time": WALL.match(line).group(1) if WALL.match(line) else "?",
                           "events": [], "cancelled": False, "partial_start": True}
                runs.append(current)
                session_runs.append(current)
            current["id"] = fields.get("id")
            current["correlated"] = correlation is not None
            if current["id"]:
                by_id[current["id"]] = current
        explicit_id = correlation or (fields.get("id") if family in (
            "APP_BENCH", "PIPELINE_SUMMARY", "LLM_BENCH") else None)
        if correlation and family in ("APP_BENCH", "PIPELINE_SUMMARY", "LLM_BENCH") and fields.get("id", correlation) != correlation:
            continue
        target = by_id.get(explicit_id) if explicit_id else current
        if target and target.get("correlated") and not explicit_id:
            # Unscoped work may belong to Local API or a previous recording.
            # Never use proximity as identity for modern stop-pipeline logs.
            continue
        if family == "FI_RESULT":
            # This provider log has no pipeline ID. Attach it only while the
            # current recording has an AI call that has not returned, so an
            # unrelated Local API request cannot contaminate a dictation.
            ai_names = [event["name"] for event in target["events"]] if target else []
            last_call = max((index for index, name in enumerate(ai_names) if name == "ai_process_call"), default=-1)
            last_return = max((index for index, name in enumerate(ai_names) if name == "ai_process_return"), default=-1)
            if not explicit_id and last_call <= last_return:
                continue
        # An unknown callback ID must not contaminate a newer recording.
        if fields.get("id") and family in ("APP_BENCH", "PIPELINE_SUMMARY") and name != "pipeline_begin":
            target = by_id.get(fields["id"])
        if target is not None:
            target["events"].append(event)
    attach_stop_requests()
    return runs


def summarize(run):
    events = run["events"]

    def find(family, names, after=None, last=False):
        matches = [e for e in events if e["family"] == family and e["name"] in names
                   and not (e["name"] == "manager finish_hide_complete"
                            and e["fields"].get("outcome") == "superseded")
                   and e["t"] is not None and (after is None or e["t"] >= after)]
        return (matches[-1] if last else matches[0]) if matches else None

    def find_with_field(family, names, key, value, after=None):
        return next((e for e in events if e["family"] == family and e["name"] in names
                     and e["fields"].get(key) == value and e["t"] is not None
                     and (after is None or e["t"] >= after)), None)

    def find_untimed(family, names, after_index=0):
        return next((e for e in events[after_index:]
                     if e["family"] == family and e["name"] in names), None)

    def time(event):
        return event["t"] if event else None

    def numeric_field(event, key):
        try:
            value = float(event["fields"][key]) if event else None
            return value if value is not None and math.isfinite(value) and value >= 0 else None
        except (KeyError, ValueError, TypeError):
            return None

    def delta(end, start):
        return round((end - start) * 1000, 1) if end is not None and start is not None else None

    start = time(find("APP_BENCH", {"begin_recording"}))
    stop = time(find("APP_BENCH", {"stop_path_enter"}))
    if stop is None:
        stop = time(find("APP_BENCH", {"pipeline_begin"}))
    # Do not accidentally match recording-stage events as completion events.
    after = stop if stop is not None else float("inf")
    phases = {
        "asr_stop_call": time(find("APP_BENCH", {"asr_stop_call"}, after)),
        "capture_stop_begin": time(find("ASR_BENCH", {"capture_stop_await_begin"}, after)),
        "capture_stop_return": time(find("ASR_BENCH", {"capture_stop_await_return"}, after)),
        "streaming_drain_end": time(find("ASR_BENCH", {"streaming_timer_stop end", "stop_streaming_wait"}, after)),
        "final_queue_ready": time(find("ASR_BENCH", {"final_queue_previous_finished"}, after)),
        "final_executor_begin": time(find("ASR_BENCH", {"final_executor_begin"}, after)),
        "final_executor_end": time(find("ASR_BENCH", {"final_executor_end"}, after)),
        "final_asr": time(find("ASR_BENCH", {"final_done"}, after)),
        "asr_return": time(find("APP_BENCH", {"asr_stop_return"}, after)),
        "refining_requested": time(find_with_field(
            "APP_BENCH", {"processing_ui_requested"}, "status", "Refining", after
        )),
        "ai_call": time(find("APP_BENCH", {"ai_process_call"}, after)),
        "ai_route_resolved": time(find("APP_BENCH", {"ai_route_resolved"}, after)),
        "ai_private_call": time(find("APP_BENCH", {"ai_private_call"}, after)),
        "ai_service_enter": time(find("FI_SERVICE_BENCH", {"enhance_enter"}, after)),
        "ai_service_call": time(find("FI_SERVICE_BENCH", {"provider_call"}, after)),
        "ai_adapter_call": time(find("FI_BRIDGE_BENCH", {"adapter_call"}, after)),
        "ai_bridge_enter": time(find("FI_BRIDGE_BENCH", {"enhance_enter"}, after)),
        "ai_bridge_validated": time(find("FI_BRIDGE_BENCH", {"validated"}, after)),
        "ai_bridge_client_ready": time(find("FI_BRIDGE_BENCH", {"client_ready"}, after)),
        "ai_model_call": time(find("FI_BRIDGE_BENCH", {"run_call"}, after)),
        "ai_model_return": time(find("FI_BRIDGE_BENCH", {"run_return"}, after)),
        "ai_bridge_return": time(find("FI_BRIDGE_BENCH", {"enhance_return"}, after)),
        "ai_adapter_return": time(find("FI_BRIDGE_BENCH", {"adapter_return"}, after)),
        "ai_service_return": time(find("FI_SERVICE_BENCH", {"provider_return"}, after)),
        "ai_private_return": time(find("APP_BENCH", {"ai_private_return"}, after)),
        "llm_call_enter": time(find("LLM_BENCH", {"call_enter"}, after)),
        "llm_request_built": time(find("LLM_BENCH", {"request_built"}, after)),
        "llm_attempt_start": time(find("LLM_BENCH", {"attempt_start"}, after)),
        "llm_response": time(find("LLM_BENCH", {"response_headers", "response_data"}, after)),
        "llm_first_content": time(find("LLM_BENCH", {"first_content"}, after)),
        "llm_response_decoded": time(find("LLM_BENCH", {"response_decoded"}, after)),
        "llm_call_return": time(find("LLM_BENCH", {"call_return"}, after)),
        "ai_return": time(find("APP_BENCH", {"ai_process_return"}, after)),
        "ai_failure": time(find("APP_BENCH", {"ai_process_fail"}, after)),
        "text_ready": time(find("APP_BENCH", {"text_ready"}, after)),
        "paste_dispatch": time(find("TYPING_BENCH", {"asr_type_dispatched"}, after)),
        "paste_done": time(find("TYPING_BENCH", {"complete"}, after)),
        "injection_return": time(find("TYPING_BENCH", {"insert_return"}, after)),
        "typing_request": time(find("TYPING_BENCH", {"request"}, after)),
        "typing_worker": time(find("TYPING_BENCH", {"worker_start"}, after)),
        "hide_request": time(find("OVERLAY_BENCH", {"manager finish_hide_request"}, after)),
        "alpha_return": time(find("OVERLAY_BENCH", {"bottom_hide_alpha_return"}, after)),
        "order_out_return": time(find("OVERLAY_BENCH", {"bottom_hide_order_out_return"}, after)),
        "hidden": time(find("OVERLAY_BENCH", {"manager finish_hide_complete"}, after)),
        "delivery_callback": time(find("TYPING_BENCH", {"delivery_main_begin"}, after)),
        "handler_return": time(find("APP_BENCH", {"pipeline_handler_return"}, after)),
        "cleanup": time(find("OVERLAY_BENCH", {"bottom_hide_immediate_cleanup_complete",
                                               "notch hide_immediate_cleanup_complete"}, after, last=True)),
    }
    final = find("ASR_BENCH", {"final_done"}, after)
    stop_event_index = next((index for index, event in enumerate(events)
                             if event["t"] == stop and event["family"] == "APP_BENCH"), 0)
    provider_final = find_untimed("ASR_BENCH", {"provider_final_done"}, stop_event_index)
    private_results = [
        event for event in events[stop_event_index:]
        if event["family"] == "FI_RESULT" and event["name"] == "complete"
    ]
    # FI completion logs do not carry a pipeline ID. If another local request
    # finishes during this dictation, suppress the breakdown instead of
    # guessing which result belongs to the hotkey pipeline.
    private_result = private_results[0] if len(private_results) == 1 and private_results[0]["pipeline_id"] else None
    final_request = find("ASR_BENCH", {"final_executor_request"}, after)
    ai_call = find("APP_BENCH", {"ai_process_call"}, after)
    summary = find("PIPELINE_SUMMARY", {"summary"}, after)
    ready_summary = find_untimed("DICTATION_SUMMARY", {"summary"}, stop_event_index)
    typing_request = find_untimed("TYPING_BENCH", {"request"}, stop_event_index)
    clipboard_snapshot = find_untimed("TYPING_BENCH", {"clipboard_snapshot_complete"}, stop_event_index)
    clipboard_write = find_untimed("TYPING_BENCH", {"clipboard_write"}, stop_event_index)
    command_posted = find_untimed("TYPING_BENCH", {"command_posted"}, stop_event_index)
    delivery_failed = find_untimed("TYPING_BENCH", {"delivery_failed"}, stop_event_index)
    first_slot = find_untimed("TYPING_BENCH", {"clipboard_slot_acquired"}, stop_event_index)
    generation_source = command_posted or delivery_failed or first_slot
    command_generation = generation_source["fields"].get("generation") if generation_source else None
    focus_check = find_untimed("APP_BENCH", {"focus_target_check"}, stop_event_index)
    pipeline_begin = find("APP_BENCH", {"pipeline_begin"})
    toggle_requested_at = numeric_field(pipeline_begin, "toggleStopRequestedAt")

    def settlement_event(name, reason=None):
        # Multiple insertions can share a pipeline. Only pair the selected command
        # with its own generation, including callbacks after another recording starts.
        if command_generation is None:
            return None
        return next((event for event in events[stop_event_index:]
                     if event["family"] == "TYPING_BENCH" and event["name"] == name
                     and event["fields"].get("generation") == command_generation
                     and (reason is None or event["fields"].get("reason") == reason)), None)

    clipboard_restore = settlement_event("restore_completed")
    clipboard_changed = settlement_event("settlement_skipped", "clipboard_changed")
    intentional_copy = settlement_event("intentional_copy_settled")
    clipboard_slot = settlement_event("clipboard_slot_acquired")
    settlement_begin = settlement_event("settlement_begin")
    phases.update({
        "clipboard_snapshot_complete": time(clipboard_snapshot),
        "clipboard_write": time(clipboard_write),
        "command_posted": time(command_posted),
        "clipboard_restore": time(clipboard_restore),
        "clipboard_change_skipped": time(clipboard_changed),
        "clipboard_slot_acquired": time(clipboard_slot),
        "clipboard_settlement_begin": time(settlement_begin),
    })
    clipboard_status = None
    if clipboard_restore:
        clipboard_status = {"true": "restored", "false": "restore_failed"}.get(
            clipboard_restore["fields"].get("success"))
    elif clipboard_changed:
        clipboard_status = "skipped_clipboard_changed"
    elif intentional_copy:
        clipboard_status = {"true": "transcript_kept", "false": "intentional_copy_failed"}.get(
            intentional_copy["fields"].get("success"))
    if run["cancelled"]:
        outcome = "cancelled"
    elif summary:
        outcome = summary["fields"].get("outcome", "finished")
    elif ready_summary and ready_summary["fields"].get("outcome") == "asr_failed":
        outcome = "asr_failed"
    elif final and final["fields"].get("textChars") == "0" and phases["handler_return"] is not None:
        outcome = "empty"
    elif phases["paste_done"] is not None:
        outcome = "paste done; callback missing"
    else:
        outcome = "incomplete"
    tail = delta(phases["hidden"], phases["paste_done"])
    try:
        provider_final_ms = float(provider_final["fields"]["elapsedMs"]) if provider_final else None
    except (KeyError, ValueError):
        provider_final_ms = None
    fi_setup_ms = numeric_field(private_result, "setupMs")
    fi_request_ms = numeric_field(private_result, "requestMs")
    fi_model_ms = numeric_field(private_result, "totalMs")
    fi_prefill_ms = numeric_field(private_result, "prefillMs")
    fi_ttft_ms = numeric_field(private_result, "ttftMs")
    fi_decode_ms = numeric_field(private_result, "decodeMs")
    fi_return_ms = numeric_field(private_result, "returnMs")
    ai_processing_ms = delta(phases["ai_return"] if phases["ai_return"] is not None
                             else phases["ai_failure"], phases["ai_call"])
    ai_route_ms = delta(phases["ai_route_resolved"], phases["ai_call"])
    fi_known_ms = [value for value in (fi_setup_ms, fi_request_ms, fi_return_ms) if value is not None]
    fi_remaining_handoff_ms = (
        round(ai_processing_ms - (ai_route_ms or 0) - sum(fi_known_ms), 1)
        if ai_processing_ms is not None and len(fi_known_ms) == 3
        else None
    )
    metrics = {
        "start_to_pcm_ms": delta(time(find("ASR_BENCH", {"first_audio"})), start),
        "start_to_overlay_ms": delta(time(find("OVERLAY_BENCH", {"bottom_visible", "bottom_order_front"})), start),
        "recording_ms": delta(stop, start),
        "hide_duration_ms": delta(phases["hidden"], phases["hide_request"]),
        "overlay_after_paste_ms": tail,
        "callback_queue_ms": delta(phases["delivery_callback"], phases["paste_done"]),
        "capture_stop_ms": delta(phases["capture_stop_return"], phases["capture_stop_begin"]),
        "asr_stop_total_ms": delta(phases["asr_return"], phases["asr_stop_call"]),
        "final_executor_hop_ms": delta(phases["final_executor_begin"], phases["final_queue_ready"]),
        "final_executor_ms": delta(phases["final_executor_end"], phases["final_executor_begin"]),
        "asr_provider_ms": provider_final_ms,
        "asr_to_ai_call_ms": delta(phases["ai_call"], phases["asr_return"]),
        "refining_to_ai_call_ms": delta(phases["ai_call"], phases["refining_requested"]),
        "ai_route_ms": ai_route_ms,
        "ai_app_to_service_ms": delta(phases["ai_service_enter"], phases["ai_private_call"]),
        "ai_service_setup_ms": delta(phases["ai_service_call"], phases["ai_service_enter"]),
        "ai_service_to_adapter_ms": delta(phases["ai_adapter_call"], phases["ai_service_call"]),
        "ai_adapter_to_runtime_ms": delta(phases["ai_bridge_enter"], phases["ai_adapter_call"]),
        "ai_call_to_bridge_ms": delta(phases["ai_bridge_enter"], phases["ai_private_call"]),
        "ai_bridge_validate_ms": delta(phases["ai_bridge_validated"], phases["ai_bridge_enter"]),
        "ai_bridge_client_ms": delta(phases["ai_bridge_client_ready"], phases["ai_bridge_validated"]),
        "ai_bridge_request_ms": delta(phases["ai_model_call"], phases["ai_bridge_client_ready"]),
        "ai_bridge_setup_ms": delta(phases["ai_model_call"], phases["ai_bridge_enter"]),
        "ai_model_envelope_ms": delta(phases["ai_model_return"], phases["ai_model_call"]),
        "ai_bridge_tail_ms": delta(phases["ai_bridge_return"], phases["ai_model_return"]),
        "ai_runtime_to_adapter_ms": delta(phases["ai_adapter_return"], phases["ai_bridge_return"]),
        "ai_adapter_to_service_ms": delta(phases["ai_service_return"], phases["ai_adapter_return"]),
        "ai_service_to_app_ms": delta(phases["ai_private_return"], phases["ai_service_return"]),
        "ai_return_hop_ms": delta(phases["ai_private_return"], phases["ai_bridge_return"]),
        "fi_setup_ms": fi_setup_ms,
        "fi_request_ms": fi_request_ms,
        "fi_model_ms": fi_model_ms,
        "fi_prefill_ms": fi_prefill_ms,
        "fi_ttft_ms": fi_ttft_ms,
        "fi_decode_ms": fi_decode_ms,
        "fi_prompt_tokens": numeric_field(private_result, "promptTokens"),
        "fi_output_tokens": numeric_field(private_result, "outputTokens"),
        "fi_tokens_per_second": numeric_field(private_result, "tps"),
        "fi_return_ms": fi_return_ms,
        "fi_remaining_handoff_ms": fi_remaining_handoff_ms,
        "llm_setup_ms": delta(phases["llm_call_enter"], phases["ai_route_resolved"]),
        "llm_request_build_ms": delta(phases["llm_request_built"], phases["llm_call_enter"]),
        "llm_transport_to_response_ms": delta(phases["llm_response"], phases["llm_attempt_start"]),
        "llm_transport_to_first_content_ms": delta(
            phases["llm_first_content"]
            if phases["llm_first_content"] is not None
            else phases["llm_response"],
            phases["llm_attempt_start"],
        ),
        "llm_decode_tail_ms": delta(
            phases["llm_response_decoded"],
            phases["llm_first_content"]
            if phases["llm_first_content"] is not None
            else phases["llm_response"],
        ),
        "llm_return_hop_ms": delta(phases["ai_return"], phases["llm_call_return"]),
        "ai_processing_ms": ai_processing_ms,
        "ai_to_ready_ms": delta(phases["text_ready"], phases["ai_return"]),
        "internal_stop_to_ready_ms": delta(phases["text_ready"], stop),
        "typing_queue_ms": delta(phases["typing_worker"], phases["typing_request"]),
        "ready_to_request_ms": delta(phases["typing_request"], phases["text_ready"]),
        "request_to_command_ms": delta(phases["command_posted"], phases["typing_request"]),
        "clipboard_snapshot_ms": numeric_field(clipboard_snapshot, "elapsedMs"),
        "clipboard_write_ms": numeric_field(clipboard_write, "elapsedMs"),
        "clipboard_command_total_ms": numeric_field(command_posted, "totalMs"),
        "command_to_restore_ms": delta(phases["clipboard_restore"], phases["command_posted"]),
        "command_to_clipboard_change_skip_ms": delta(phases["clipboard_change_skipped"], phases["command_posted"]),
        "toggle_callback_to_handler_ms": delta(time(pipeline_begin), toggle_requested_at),
        "focus_check_ms": numeric_field(focus_check, "totalMs"),
        "focus_pid_ms": numeric_field(focus_check, "pidMs"),
        "focus_element_ms": numeric_field(focus_check, "elementMs"),
        "clipboard_slot_wait_ms": numeric_field(clipboard_slot, "waitMs"),
        "clipboard_settlement_wait_ms": numeric_field(settlement_begin, "elapsedMs"),
        "clipboard_settlement_scheduled_ms": numeric_field(settlement_begin, "scheduledDelayMs"),
        "clipboard_restore_work_ms": numeric_field(clipboard_restore, "elapsedMs"),
        "clipboard_intentional_copy_work_ms": numeric_field(intentional_copy, "elapsedMs"),
        "ready_to_injection_ms": delta(phases["injection_return"], phases["text_ready"]),
        "ready_to_delivery_ms": delta(phases["delivery_callback"], phases["text_ready"]),
        "stop_to_delivery_ms": numeric_field(summary, "totalMs"),
        "summary_asr_ms": numeric_field(ready_summary, "asrMs"),
        "summary_ai_ms": numeric_field(ready_summary, "aiMs"),
        "summary_app_overhead_ms": numeric_field(ready_summary, "appOverheadMs"),
        "summary_ready_ms": numeric_field(ready_summary, "readyMs"),
    }
    context = {
        "insertion_mode": typing_request["fields"].get("mode") if typing_request else None,
        "load_average_1m": numeric_field(pipeline_begin, "loadAvg1m"),
        "clipboard_command_status": "command_posted" if command_posted else (
            delivery_failed["fields"].get("reason") if delivery_failed else None),
        "clipboard_settlement_status": clipboard_status,
        "clipboard_generation": command_generation,
        "focus_missing_context": focus_check["fields"].get("missingContext") if focus_check else None,
        "route": next((e["fields"].get("route") for e in events
                       if e["family"] == "APP_BENCH" and e["name"] == "pipeline_begin"), None),
        "llm_attempt_count": sum(e["family"] == "LLM_BENCH" and e["name"] == "attempt_start" for e in events),
        "audio_ms": numeric_field(final, "audioMs"),
        "samples": numeric_field(final, "samples"),
        "text_chars": numeric_field(final, "textChars"),
        "asr_model": final_request["fields"].get("model") if final_request else None,
        "vocab_enabled": final_request["fields"].get("vocabEnabled") if final_request else None,
        "vocab_terms": numeric_field(final_request, "vocabTerms"),
        "ai_provider": ai_call["fields"].get("provider") if ai_call else None,
        "ai_model": ai_call["fields"].get("model") if ai_call else None,
    }
    return {"id": run["id"], "time": run["time"], "outcome": outcome,
            "ready_outcome": ready_summary["fields"].get("outcome") if ready_summary else None,
            "correlation": "request_id" if run.get("correlated") else "legacy_proximity_uncertain",
            "correctness": "not_checked_requires_expected_and_delivered_text",
            "partial_start": run["partial_start"], "stop_uptime": stop,
            "stop_callback_uptime": toggle_requested_at,
            "phase_uptime": phases,
            "clipboard_uptime": {key: phases[key] for key in (
                "clipboard_snapshot_complete", "clipboard_write", "command_posted",
                "clipboard_restore", "clipboard_change_skipped", "clipboard_slot_acquired",
                "clipboard_settlement_begin")},
            "from_stop_ms": {key: delta(value, stop) for key, value in phases.items()},
            "metrics": metrics, "context": context, "events": events}


def render(rows, details=False):
    def fmt(value):
        return "—" if value is None else f"{value:.1f}"

    lines = ["# Dictation evaluation", "",
             "Readiness is not delivery. Timing is not text-correctness proof.", "",
             "| Time / ID | Correlation | Ready result | Delivery result | ASR | AI | App overhead | Ready | Delivery |",
             "|---|---|---|---|---:|---:|---:|---:|---:|"]
    for row in rows:
        m = row["metrics"]
        values = [m["summary_asr_ms"], m["summary_ai_ms"], m["summary_app_overhead_ms"],
                  m["summary_ready_ms"], m["stop_to_delivery_ms"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | {row['correlation']} | "
                     f"{row['ready_outcome'] or 'unknown'} | {row['outcome']} | "
                     + " | ".join(map(fmt, values)) + " |")
    lines += ["", "Legacy proximity metrics are exploratory, not authoritative overlap comparisons. "
              "FI breakdown requires a matching request ID. Correctness requires checking the actual delivered text.",
              "", "## Delivery and overlay", "",
             "Times in ms from stop-handler entry (not physical key-down). — = not logged / not applicable.",
             "Hidden = window API returned, not measured pixels. Paste = worker completed (including optional send-key wait), not target-app rendering.", "",
             "| Time / ID | Outcome | ASR | Ready | Paste | Hidden | Hide cost | Hidden − paste | Callback queue | Cleanup |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        p, m = row["from_stop_ms"], row["metrics"]
        values = [p["asr_return"], p["text_ready"], p["paste_done"], p["hidden"],
                  m["hide_duration_ms"], m["overlay_after_paste_ms"], m["callback_queue_ms"], p["cleanup"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | {row['outcome']} | " + " | ".join(map(fmt, values)) + " |")
    tails = [r["metrics"]["overlay_after_paste_ms"] for r in rows if r["metrics"]["overlay_after_paste_ms"] is not None]
    if tails:
        lines += ["", f"Overlay API returned after paste in {sum(t > 0 for t in tails)}/{len(tails)} measured runs. "
                  f"Hidden − paste: median {statistics.median(tails):.1f} ms, worst {max(tails):.1f} ms "
                  "(negative = hidden first)."]
    lines += ["", "Cleanup is the last logged overlay-cleanup marker, not proof all background work has finished.",
              "Unlabelled events are bounded by recording starts; rapid-overlap tails cannot be reliably attributed."]
    lines += ["", "## Clipboard delivery", "",
              "Durations in ms. Mode is the logged setting; command posted is dispatch, not visible insertion. "
              "Coordinator total starts after acquiring its slot; no queue time is inferred. "
              "For multiple clipboard commands, this table describes the first command and its matching settlement. "
              "— = unknown / not logged.", "",
              "| Time / ID | Mode | Ready→request | Request→command | Snapshot | Write | Coordinator total | Command→restore | Command→changed skip | Command status | Clipboard status |",
              "|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|"]
    for row in rows:
        m, context = row["metrics"], row["context"]
        values = [m["ready_to_request_ms"], m["request_to_command_ms"],
                  m["clipboard_snapshot_ms"], m["clipboard_write_ms"], m["clipboard_command_total_ms"],
                  m["command_to_restore_ms"], m["command_to_clipboard_change_skip_ms"]]
        mode = (context["insertion_mode"] or "unknown").replace("|", "\\|")
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | {mode} | "
                     + " | ".join(map(fmt, values))
                     + f" | {context['clipboard_command_status'] or 'unknown'} | "
                     + f"{context['clipboard_settlement_status'] or 'unknown'} |")
    lines += ["", "## Measured focus and clipboard waits", "",
              "Times in ms. Toggle callback→handler starts at the app callback, not physical key-down. "
              "PID and element checks are parts of focus total; scheduled delay is part of actual timer wait. "
              "Timer wait and restoration work are separate from dispatch. Do not add nested columns or "
              "infer an unlogged wait from the remaining elapsed time.", "",
              "| Time / ID | Toggle callback→handler | Focus total | PID check | Element check | Clipboard queue | Timer scheduled | Timer actual | Restore work | Keep-transcript work |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        m = row["metrics"]
        values = [m["toggle_callback_to_handler_ms"], m["focus_check_ms"], m["focus_pid_ms"],
                  m["focus_element_ms"], m["clipboard_slot_wait_ms"],
                  m["clipboard_settlement_scheduled_ms"], m["clipboard_settlement_wait_ms"],
                  m["clipboard_restore_work_ms"], m["clipboard_intentional_copy_work_ms"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    lines += ["", "## Internal model handoffs", "",
              "These exclude focus restoration, paste injection, and overlay dismissal.", "",
              "| Time / ID | Capture stop | ASR hop | ASR provider | ASR→AI | Refining→AI | AI process | AI→ready | Stop→ready |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        m = row["metrics"]
        values = [m["capture_stop_ms"], m["final_executor_hop_ms"], m["asr_provider_ms"],
                  m["asr_to_ai_call_ms"], m["refining_to_ai_call_ms"], m["ai_processing_ms"],
                  m["ai_to_ready_ms"], m["internal_stop_to_ready_ms"]]
        lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    lines += ["", "ASR provider and AI process are measured model-call envelopes; all other columns are glue/handoff time."]
    if any(row["metrics"]["ai_model_envelope_ms"] is not None for row in rows):
        lines += ["", "## AI handoff detail", "",
                  "| Time / ID | Route | Call→bridge | Bridge setup | FI run | Bridge tail | Return hop | AI total |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|"]
        for row in rows:
            m = row["metrics"]
            values = [m["ai_route_ms"], m["ai_call_to_bridge_ms"], m["ai_bridge_setup_ms"],
                      m["ai_model_envelope_ms"], m["ai_bridge_tail_ms"], m["ai_return_hop_ms"],
                      m["ai_processing_ms"]]
            lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    if any(row["metrics"]["ai_app_to_service_ms"] is not None for row in rows):
        lines += ["", "## FI actor and setup detail", "",
                  "| Time / ID | App→service | Service setup | Service→adapter | Adapter→runtime | Validate | Cached client | Request | Runtime→adapter | Adapter→service | Service→app |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for row in rows:
            m = row["metrics"]
            values = [m["ai_app_to_service_ms"], m["ai_service_setup_ms"],
                      m["ai_service_to_adapter_ms"], m["ai_adapter_to_runtime_ms"],
                      m["ai_bridge_validate_ms"], m["ai_bridge_client_ms"],
                      m["ai_bridge_request_ms"], m["ai_runtime_to_adapter_ms"],
                      m["ai_adapter_to_service_ms"], m["ai_service_to_app_ms"]]
            lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    if any(row["metrics"]["fi_model_ms"] is not None for row in rows):
        lines += ["", "## Private FI handoff", "",
                  "| Time / ID | Setup | Request | Model | Prefill | TTFT | Decode | Inside return | Remaining handoff | AI total |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for row in rows:
            m = row["metrics"]
            values = [m["fi_setup_ms"], m["fi_request_ms"], m["fi_model_ms"],
                      m["fi_prefill_ms"], m["fi_ttft_ms"], m["fi_decode_ms"],
                      m["fi_return_ms"], m["fi_remaining_handoff_ms"], m["ai_processing_ms"]]
            lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    if any(row["metrics"]["llm_request_build_ms"] is not None for row in rows):
        lines += ["", "## External AI handoff detail", "",
                  "| Time / ID | Route→client | Request build | Transport→headers | Transport→first text | Decode tail | Return hop | AI total |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|"]
        for row in rows:
            m = row["metrics"]
            values = [m["llm_setup_ms"], m["llm_request_build_ms"],
                      m["llm_transport_to_response_ms"], m["llm_transport_to_first_content_ms"],
                      m["llm_decode_tail_ms"], m["llm_return_hop_ms"], m["ai_processing_ms"]]
            lines.append(f"| {row['time']} / {(row['id'] or '?')[:8]} | " + " | ".join(map(fmt, values)) + " |")
    if details:
        for row in rows:
            context = row["context"]
            lines += ["", f"## {row['time']} / {row['id'] or 'no pipeline ID'}", "",
                      f"Start → first PCM: {fmt(row['metrics']['start_to_pcm_ms'])} ms; "
                      f"start → overlay: {fmt(row['metrics']['start_to_overlay_ms'])} ms; "
                      f"start → stop: {fmt(row['metrics']['recording_ms'])} ms.",
                      f"Audio: {fmt(context['audio_ms'])} ms / {context['samples'] or '—'} samples; "
                      f"ASR: {context['asr_model'] or '—'}; vocab: {context['vocab_enabled'] or '—'} "
                      f"({context['vocab_terms'] if context['vocab_terms'] is not None else '—'} terms); "
                      f"AI: {context['ai_provider'] or '—'} / {context['ai_model'] or '—'}; "
                      f"text: {context['text_chars'] or '—'} chars.", "",
                      "| From stop (ms) | Event | Fields |", "|---:|---|---|"]
            for e in row["events"]:
                relative = (e["t"] - row["stop_uptime"]) * 1000 if e["t"] is not None and row["stop_uptime"] is not None else None
                fields = " ".join(f"{k}={v}" for k, v in e["fields"].items()).replace("|", "\\|")
                lines.append(f"| {fmt(relative)} | {e['family']} {e['name']} | {fields} |")
    return "\n".join(lines)


STAGES = [
    ("Recording start → first PCM (separate)", "metrics", "start_to_pcm_ms"),
    ("Toggle callback → stop handler", "metrics", "toggle_callback_to_handler_ms"),
    ("Stop handler → command dispatch", "from_stop_ms", "command_posted"),
    ("ASR stop call total", "metrics", "asr_stop_total_ms"),
    ("ASR provider (within ASR)", "metrics", "asr_provider_ms"),
    ("AI processing", "metrics", "ai_processing_ms"),
    ("Ready → insertion request", "metrics", "ready_to_request_ms"),
    ("Focus check total", "metrics", "focus_check_ms"),
    ("PID check (within focus)", "metrics", "focus_pid_ms"),
    ("Element check (within focus)", "metrics", "focus_element_ms"),
    ("Request → command dispatch", "metrics", "request_to_command_ms"),
    ("Clipboard slot wait", "metrics", "clipboard_slot_wait_ms"),
    ("Clipboard snapshot", "metrics", "clipboard_snapshot_ms"),
    ("Clipboard write", "metrics", "clipboard_write_ms"),
    ("Coordinator after slot acquired", "metrics", "clipboard_command_total_ms"),
    ("Overlay hide API duration", "metrics", "hide_duration_ms"),
    ("Restore timer scheduled (within actual wait)", "metrics", "clipboard_settlement_scheduled_ms"),
    ("Restore timer actual wait", "metrics", "clipboard_settlement_wait_ms"),
    ("Restore work", "metrics", "clipboard_restore_work_ms"),
    ("Keep-transcript work", "metrics", "clipboard_intentional_copy_work_ms"),
]


def render_stages(rows):
    """One measured-stage overview; nested intervals are never added together."""
    def fmt(value):
        return "—" if value is None else f"{value:.1f}"

    lines = ["# Dictation stages", "",
             "Times in ms; — = not logged / unknown. Nested stages overlap and are not additive. "
             "Recording-start timing is separate from stop latency. Dispatch and overlay API completion "
             "do not prove visible insertion or rendered pixels.", "",
             "| Stage | " + " | ".join(f"{r['time']} / {(r['id'] or '?')[:8]}" for r in rows) + " |",
             "|---|" + "---:|" * len(rows)]
    lines.append("| Insertion mode | " + " | ".join(
        (r["context"]["insertion_mode"] or "—").replace("|", "\\|") for r in rows) + " |")
    for label, source, key in STAGES:
        lines.append(f"| {label} | " + " | ".join(fmt(r[source][key]) for r in rows) + " |")
    return "\n".join(lines)


def render_terminal_stages(rows, width=None, stages=None, title="DICTATION TIMINGS", notes=None, precision=1):
    """Bounded-width tables for plain terminals, with no external packages."""
    width = max(40, width or shutil.get_terminal_size(fallback=(100, 24)).columns)
    label_width = min(40, width - 19)
    value_width = 12
    per_table = max(1, (width - label_width - 4) // (value_width + 3))
    lines = textwrap.wrap(title, width) + textwrap.wrap(
        "All durations in milliseconds (ms). — = not measured.", width) + [""]
    for index, row in enumerate(rows, 1):
        mode = row["context"]["insertion_mode"] or "unknown mode"
        load = row["context"].get("load_average_1m")
        load_label = f"  load {load:.1f}" if load is not None else ""
        lines.extend(textwrap.wrap(
            f"#{index}  {row['time']}  {(row['id'] or '?')[:8]}  {mode}{load_label}", width))
    for offset in range(0, len(rows), per_table):
        batch = rows[offset:offset + per_table]
        widths = [label_width] + [value_width] * len(batch)

        def border(left, middle, right):
            return left + middle.join("─" * (w + 2) for w in widths) + right

        def cells(values):
            wrapped = [textwrap.wrap(str(value), w) or [""]
                       for value, w in zip(values, widths)]
            result = []
            for n in range(max(map(len, wrapped))):
                parts = []
                for col, (segments, w) in enumerate(zip(wrapped, widths)):
                    value = segments[n] if n < len(segments) else ""
                    parts.append(" " + (value.ljust(w) if col == 0 else value.rjust(w)) + " ")
                result.append("│" + "│".join(parts) + "│")
            return result

        lines += ["", border("┌", "┬", "┐")]
        lines += cells(["Stage (ms)"] + [f"#{offset + i + 1}" for i in range(len(batch))])
        lines.append(border("├", "┼", "┤"))
        for label, source, key in (STAGES if stages is None else stages):
            values = ["—" if r[source][key] is None else f"{r[source][key]:.{precision}f}" for r in batch]
            lines += cells([label] + values)
        lines.append(border("└", "┴", "┘"))
    for note in (notes if notes is not None else (
        "Nested stages overlap and are not additive. Recording-start timing is separate from stop latency.",
        "Dispatch measures sending the paste command, not when text becomes visible. Overlay timing measures the API call.",
    )):
        lines += [""] + textwrap.wrap(note, width)
    return "\n".join(lines)


def attach_field_receipts(rows, lines):
    """Join a local test by target PID, stop window and full pasted character count.

    Ambiguous, timed-out, mismatched or incomplete tests never become successes.
    Receipt times use the same macOS systemUptime clock as the app, not log write time.
    """
    tests = {}
    for line in lines:
        try:
            event = json.loads(line)
            if not isinstance(event, dict):
                continue
            t = event.get("t")
            if isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) or t < 0:
                continue
            tests.setdefault(event["run_id"], []).append(event)
        except (ValueError, KeyError, TypeError):
            continue  # includes an incomplete final line during an active capture
    candidates = {}
    for run_id, events in tests.items():
        stops = [e for e in events if e.get("event") == "stop_pressed"]
        received = [e for e in events if e.get("event") == "field_received"]
        if len(stops) != 1 or len(received) != 1:
            continue
        if any(e.get("event") in ("timeout", "field_mismatch") for e in events):
            continue
        stop, receipt = stops[0], received[0]
        if not 0 <= receipt["t"] - stop["t"] <= 30:
            continue
        target_pid = stop.get("target_pid")
        if not isinstance(target_pid, int) or receipt.get("target_pid") != target_pid:
            continue
        matches = []
        for row in rows:
            callback = row["stop_callback_uptime"]
            request = next((e for e in row["events"] if e["family"] == "TYPING_BENCH"
                            and e["name"] == "request"), None)
            if callback is None or not stop["t"] <= callback <= receipt["t"] or request is None:
                continue
            fields = request["fields"]
            if (row["correlation"] != "request_id" or row["outcome"] == "cancelled"
                    or row["context"]["clipboard_command_status"] != "command_posted"
                    or fields.get("preferredPID") != str(target_pid)
                    or fields.get("chars") != str(receipt.get("chars"))):
                continue
            if request["t"] is None or not callback <= request["t"] <= receipt["t"]:
                continue
            matches.append(row)
        if len(matches) != 1:
            continue
        drawn = [e for e in events if e.get("event") == "field_drawn"
                 and e.get("target_pid") == target_pid and e["t"] >= receipt["t"]]
        candidates.setdefault(matches[0]["id"], []).append({
            "run_id": run_id, "stop": stop["t"], "received": receipt["t"],
            "drawn": min((e["t"] for e in drawn), default=None),
        })
    for row in rows:
        matches = candidates.get(row["id"], [])
        if len(matches) == 1:
            row["field_receipt"] = matches[0]


LATENCY_STAGES = [
    ("TOTAL: Stop → text in field", "latency", "total_ms"),
    ("Stop button → app receives stop", "latency", "input_ms"),
    ("App receives stop → ASR starts", "latency", "before_asr_ms"),
    ("Finish transcription", "latency", "asr_ms"),
    ("Transcription → AI starts", "latency", "before_ai_ms"),
    ("AI processing", "latency", "ai_ms"),
    ("AI ends → final text ready", "latency", "after_ai_ms"),
    ("Prepare target / request insertion", "latency", "prepare_ms"),
    ("Insertion request → paste sent", "latency", "insertion_ms"),
    ("Paste sent → text in field", "latency", "receiver_ms"),
    ("Other / unlogged stage time", "latency", "unattributed_ms"),
    ("SUBTOTAL: App stop → paste sent", "latency", "sent_ms"),
]


def add_latency_breakdown(rows):
    def duration(start, end):
        if start is None or end is None or not all(math.isfinite(t) for t in (start, end)) or end < start:
            return None
        return (end - start) * 1000

    for row in rows:
        p = row["phase_uptime"]
        receipt = row.get("field_receipt", {})
        # Older logs have only a stop handler marker. Do not call that a button press.
        app_stop = row["stop_callback_uptime"]
        if app_stop is None:
            app_stop = row["stop_uptime"]
        origin = receipt.get("stop", app_stop)
        ai_end = p["ai_return"] if p["ai_return"] is not None else p["ai_failure"]
        intervals = [
            ("input_ms", receipt.get("stop"), app_stop),
            ("before_asr_ms", app_stop, p["asr_stop_call"]),
            ("asr_ms", p["asr_stop_call"], p["asr_return"]),
            ("before_ai_ms", p["asr_return"], p["ai_call"]),
            ("ai_ms", p["ai_call"], ai_end),
            ("after_ai_ms", ai_end, p["text_ready"]),
            ("prepare_ms", p["text_ready"], p["typing_request"]),
            ("insertion_ms", p["typing_request"], p["command_posted"]),
            ("receiver_ms", p["command_posted"], receipt.get("received")),
        ]
        end = receipt.get("received", p["command_posted"])
        m = {}
        previous_end = origin
        for key, start, finish in intervals:
            value = duration(start, finish)
            # Do not add overlapping or out-of-envelope markers into the critical path.
            if (value is not None and origin is not None and end is not None
                    and origin <= start <= finish <= end
                    and (previous_end is None or start >= previous_end)):
                m[key] = value
                previous_end = finish
            else:
                m[key] = None
        envelope = duration(origin, end)
        m["unattributed_ms"] = max(0, envelope - sum(v for v in m.values() if v is not None)) if envelope is not None else None
        m["total_ms"] = duration(receipt.get("stop"), receipt.get("received"))
        m["sent_ms"] = duration(app_stop, p["command_posted"])
        row["latency"] = {key: round(value, 1) if value is not None else None for key, value in m.items()}


def render_terminal_latency(rows, width=None):
    add_latency_breakdown(rows)
    measured = sum(row["latency"]["total_ms"] is not None for row in rows)
    notes = [
        f"Verified local test-field receipts: {measured}/{len(rows)}. TOTAL is unknown without a receiving-field measurement.",
        "The individual stages partition the stop-to-field interval. Do not add TOTAL or SUBTOTAL again. "
        "Other/unlogged time includes gaps where stage markers are missing.",
        "The test verifies the full text is in the field. This is target-app receipt, not a physical display/pixel timestamp. "
        "The test button also includes the synthetic shortcut handoff to FluidVoice.",
        "Microphone startup, overlay cleanup and clipboard restoration are in --stages. "
        "They are not added to the stop-to-field total.",
    ]
    return render_terminal_stages(rows, width, LATENCY_STAGES, "STOP → TEXT IN FIELD", notes)


DELIVERY_STAGES = [
    ("TOTAL: Text ready → paste sent", "delivery", "total_ms"),
    ("Prepare / restore target focus", "delivery", "prepare_ms"),
    ("Wait / enter clipboard slot", "delivery", "queue_ms"),
    ("Save previous clipboard", "delivery", "snapshot_ms"),
    ("Write dictated text to clipboard", "delivery", "write_ms"),
    ("Resolve paste key / send command", "delivery", "dispatch_ms"),
    ("Other / missing stage markers", "delivery", "unattributed_ms"),
]


def delivery_was_unsuccessful(row):
    """Keep every dispatch report consistent for failed or cancelled output."""
    return row["outcome"] == "cancelled" or any(
        e["family"] == "TYPING_BENCH" and (
            e["name"] == "delivery_failed" or
            e["fields"].get("result", "").startswith("recoverableFailure"))
        for e in row["events"]
    )


def add_delivery_breakdown(rows):
    for row in rows:
        p = row["phase_uptime"]
        start, end = p["text_ready"], p["command_posted"]
        if delivery_was_unsuccessful(row):
            end = None
        intervals = [
            ("prepare_ms", start, p["typing_request"]),
            ("queue_ms", p["typing_request"], p["clipboard_slot_acquired"]),
            ("snapshot_ms", p["clipboard_slot_acquired"], p["clipboard_snapshot_complete"]),
            ("write_ms", p["clipboard_snapshot_complete"], p["clipboard_write"]),
            ("dispatch_ms", p["clipboard_write"], end),
        ]
        complete = (start is not None and end is not None and
                    math.isfinite(start) and math.isfinite(end) and end >= start)
        total = (end - start) * 1000 if complete else None
        m, previous = {}, start
        for key, begin, finish in intervals:
            if (complete and begin is not None and finish is not None
                    and start <= begin <= finish <= end and begin >= previous):
                m[key] = (finish - begin) * 1000
                previous = finish
            else:
                m[key] = None
        m["unattributed_ms"] = max(0, total - sum(v for v in m.values() if v is not None)) if complete else None
        m["total_ms"] = total
        row["delivery"] = {key: round(value, 2) if value is not None else None for key, value in m.items()}


def render_terminal_delivery(rows, width=None):
    add_delivery_breakdown(rows)
    return render_terminal_stages(rows, width, DELIVERY_STAGES, "TEXT READY → PASTE COMMAND SENT", [
        "Starts after ASR/AI finish. Ends when FluidVoice sends the paste command.",
        "The stages partition that interval, including their handoffs. TOTAL is their summary, not another stage.",
        "Receiving-app rendering and later clipboard restoration are excluded. — = missing measurement.",
    ], precision=2)


PIPELINE_STAGES = [
    ("TOTAL: Stop → text dispatch", "pipeline", "total_ms"),
    ("Stop request → handler begins", "pipeline", "stop_queue_ms"),
    ("Stop preparation / UI → ASR call", "pipeline", "stop_preparation_ms"),
    ("ASR work (unsplit older logs)", "pipeline", "asr_ms"),
    ("Enter ASR / begin stopping audio", "pipeline", "asr_setup_ms"),
    ("Stop audio capture", "pipeline", "capture_stop_ms"),
    ("Wait for active transcription chunk", "pipeline", "streaming_drain_ms"),
    ("Prepare final audio / ASR queue", "pipeline", "final_queue_ms"),
    ("Final transcription", "pipeline", "final_asr_ms"),
    ("Finalize ASR result / return", "pipeline", "asr_return_ms"),
    ("Transcription → AI handoff", "pipeline", "before_ai_ms"),
    ("AI processing (full call)", "pipeline", "ai_ms"),
    ("Finalize text after AI", "pipeline", "after_ai_ms"),
    ("Prepare / restore target focus", "pipeline", "prepare_ms"),
    ("Wait / enter clipboard slot", "pipeline", "queue_ms"),
    ("Save previous clipboard", "pipeline", "snapshot_ms"),
    ("Write dictated text to clipboard", "pipeline", "write_ms"),
    ("Resolve paste key / send command", "pipeline", "dispatch_ms"),
    ("Remaining output steps / waits", "pipeline", "remaining_output_ms"),
    ("Other / missing stage markers", "pipeline", "unattributed_ms"),
]


def add_pipeline_breakdown(rows):
    """Partition the entire recorded stop-request to final dispatch interval."""
    for row in rows:
        p = row["phase_uptime"]
        start = row["stop_callback_uptime"]
        row["pipeline_start_basis"] = "stop_request"
        if start is None:
            start = row["stop_uptime"]
            row["pipeline_start_basis"] = "handler_only"
        def valid_time(value):
            return (start is not None and math.isfinite(start) and value is not None
                    and math.isfinite(value) and value >= start)

        commands = [e["t"] for e in row["events"] if e["family"] == "TYPING_BENCH"
                    and e["name"] == "command_posted" and valid_time(e["t"])]
        end = max(commands) if commands else (p["injection_return"] if valid_time(p["injection_return"]) else None)
        # Current direct insertion logs completion before optional Spoken Send
        # waits. Its later ASR callback lacks result= and is not the text endpoint.
        if end is None:
            callback_times = [e["t"] for e in row["events"] if e["family"] == "TYPING_BENCH"
                              and e["name"] == "asr_type_dispatched" and valid_time(e["t"])]
            request = p["typing_request"]
            completions = [e["t"] for e in row["events"] if e["family"] == "TYPING_BENCH"
                           and e["name"] == "complete" and e["fields"].get("result") == "commandPosted"
                           and valid_time(e["t"])
                           and (request is None or (valid_time(request) and e["t"] >= request))
                           and (not callback_times or e["t"] <= min(callback_times))]
            end = max(completions) if completions else None
        # Older direct typing may only expose its final dispatch callback.
        if end is None:
            callback = next((e for e in row["events"] if e["family"] == "TYPING_BENCH"
                             and e["name"] == "asr_type_dispatched"
                             and e["fields"].get("result") == "commandPosted"
                             and valid_time(e["t"])), None)
            end = callback["t"] if callback else None
        if delivery_was_unsuccessful(row):
            end = None
        ai_end = p["ai_return"] if p["ai_return"] is not None else p["ai_failure"]
        intervals = [
            ("stop_queue_ms", row["stop_callback_uptime"], row["stop_uptime"]),
            ("stop_preparation_ms", row["stop_uptime"], p["asr_stop_call"]),
            ("asr_ms", p["asr_stop_call"], p["asr_return"]),
            ("before_ai_ms", p["asr_return"], p["ai_call"]),
            ("ai_ms", p["ai_call"], ai_end),
            ("after_ai_ms", ai_end, p["text_ready"]),
            ("prepare_ms", p["text_ready"], p["typing_request"]),
            ("queue_ms", p["typing_request"], p["clipboard_slot_acquired"]),
            ("snapshot_ms", p["clipboard_slot_acquired"], p["clipboard_snapshot_complete"]),
            ("write_ms", p["clipboard_snapshot_complete"], p["clipboard_write"]),
            ("dispatch_ms", p["clipboard_write"], p["command_posted"]),
            ("remaining_output_ms", p["command_posted"], end),
        ]
        asr_points = [p["asr_stop_call"], p["capture_stop_begin"], p["capture_stop_return"],
                      p["streaming_drain_end"], p["final_executor_begin"], p["final_executor_end"], p["asr_return"]]
        split_asr = (all(t is not None and math.isfinite(t) for t in asr_points)
                     and all(a <= b for a,b in zip(asr_points, asr_points[1:])))
        asr_keys = ["asr_setup_ms", "capture_stop_ms", "streaming_drain_ms", "final_queue_ms", "final_asr_ms", "asr_return_ms"]
        if split_asr:
            intervals[2:3] = list(zip(asr_keys, asr_points, asr_points[1:]))
        complete = (start is not None and end is not None and
                    math.isfinite(start) and math.isfinite(end) and end >= start)
        total = (end - start) * 1000 if complete else None
        m, previous = {}, start
        for key, begin, finish in intervals:
            # Partial runs still show stages that were measured; they never get a success total.
            if (start is not None and begin is not None and finish is not None
                    and math.isfinite(begin) and math.isfinite(finish)
                    and start <= begin <= finish and begin >= previous
                    and (end is None or finish <= end)):
                m[key] = (finish - begin) * 1000
                previous = finish
            else:
                m[key] = None
        m["unattributed_ms"] = max(0, total - sum(v for v in m.values() if v is not None)) if complete else None
        m["total_ms"] = total
        for key in ["asr_ms"] + asr_keys:
            m.setdefault(key, None)
        row["pipeline"] = {key: round(value, 2) if value is not None else None for key, value in m.items()}
        row["dispatch_uptime"] = end if complete else None


BOUNDARY_STAGES = [
    ("OS stop event → dispatch", "boundaries", "os_event_to_dispatch_ms"),
    ("OS input delivery delay", "boundaries", "input_delivery_ms"),
    ("Input callback → stop request", "boundaries", "input_to_request_ms"),
    ("Held-key time (press → release)", "boundaries", "held_key_ms"),
    ("Stop request → overlay hidden API", "boundaries", "stop_to_hidden_ms"),
    ("Stop request → handler returns", "boundaries", "stop_to_handler_return_ms"),
    ("Stop request → overlay cleanup", "boundaries", "stop_to_cleanup_ms"),
    ("Dispatch → overlay hidden API", "boundaries", "dispatch_to_hidden_ms"),
    ("Main queue wait after dispatch", "boundaries", "dispatch_main_queue_wait_ms"),
    ("Dispatch → text visibly entered", "boundaries", "dispatch_to_visible_ms"),
]

BOUNDARY_NOTES = [
    "Boundary diagnostics overlap: do not add these rows to each other or to the timeline TOTAL.",
    "OS stop event → dispatch includes OS delivery and input-callback time when all are logged. "
    "Held-key time precedes the release event; it is not processing time and is excluded from that total.",
    "Overlay milestones are API/cleanup completion, not proof of text visibility. The main-queue probe "
    "measures callback waiting after dispatch, not receiving-app delay. Missing input or visible-text markers stay —.",
]


def add_boundary_diagnostics(rows):
    """Expose measured times outside dispatch boundaries, without claiming visibility."""
    def number(value):
        try:
            value = float(value)
            return value if math.isfinite(value) and value >= 0 else None
        except (TypeError, ValueError):
            return None

    def duration(start, end):
        start, end = number(start), number(end)
        return (end - start) * 1000 if start is not None and end is not None and end >= start else None

    for row in rows:
        m = {key: None for _, _, key in BOUNDARY_STAGES}
        stop = number(row["stop_callback_uptime"])
        dispatch = number(row.get("dispatch_uptime"))
        requests = [e for e in row["events"] if e["family"] == "HOTKEY_BENCH"
                    and e["name"] == "stop_request"
                    and stop is not None and number(e["fields"].get("stopRequestedAt")) == stop]
        if len(requests) == 1:
            fields = requests[0]["fields"]
            received = number(fields.get("inputReceivedAt"))
            m["input_to_request_ms"] = duration(received, stop)
            if m["input_to_request_ms"] is not None:
                m["input_delivery_ms"] = number(fields.get("inputAgeMs"))
                m["held_key_ms"] = duration(fields.get("pressReceivedAt"), received)
            if dispatch is not None and all(m[key] is not None for key in ("input_to_request_ms", "input_delivery_ms")):
                m["os_event_to_dispatch_ms"] = duration(stop, dispatch) + m["input_to_request_ms"] + m["input_delivery_ms"]
            row["input_context"] = {key: fields.get(key) for key in ("route", "eventType")}
        # Failed/cancelled output never produces a success endpoint. These
        # post-dispatch diagnostics also require a completed dispatch.
        if dispatch is not None:
            for phase, key in (("hidden", "stop_to_hidden_ms"),
                               ("handler_return", "stop_to_handler_return_ms"),
                               ("cleanup", "stop_to_cleanup_ms")):
                milestone = row["phase_uptime"][phase]
                if duration(dispatch, milestone) is not None:
                    m[key] = duration(stop, milestone)
            m["dispatch_to_hidden_ms"] = duration(dispatch, row["phase_uptime"]["hidden"])
            probes = [e for e in row["events"] if e["family"] == "APP_BENCH"
                      and e["name"] == "dispatch_main_queue_probe"
                      and duration(dispatch, e["fields"].get("scheduledAt")) is not None
                      and duration(e["fields"].get("scheduledAt"), e["t"]) is not None]
            if len(probes) == 1:
                m["dispatch_main_queue_wait_ms"] = duration(probes[0]["fields"]["scheduledAt"], probes[0]["t"])
        row["boundaries"] = {key: round(value, 2) if value is not None else None for key, value in m.items()}


def render_terminal_pipeline(rows, width=None):
    add_pipeline_breakdown(rows)
    add_boundary_diagnostics(rows)
    notes = [
        "One column per dictation. Every stage is inside the TOTAL, including handoffs and waiting; "
        "rounding may differ by 0.01 ms. Unknown gaps remain in Other.",
        "Starts at the recorded stop-request callback; ends at text dispatch. "
        "Earlier input delivery and later UI work are shown separately below. Rendering/restoration are outside this interval.",
    ]
    legacy = [str(i) for i,r in enumerate(rows,1) if r["pipeline_start_basis"] == "handler_only"]
    failed = [str(i) for i,r in enumerate(rows,1) if r["pipeline"]["total_ms"] is None]
    if legacy:
        notes.append("Older/missing stop-request marker in #" + ", #".join(legacy) + ": timing starts at the handler only.")
    if failed:
        notes.append("No completed dispatch measured in #" + ", #".join(failed) + "; no successful total is claimed.")
    stages = [stage for stage in PIPELINE_STAGES if stage[2] != "asr_ms" or any(r["pipeline"]["asr_ms"] is not None for r in rows)]
    return render_terminal_stages(rows, width, stages, "FULL TIMELINE: STOP → TEXT DISPATCH", notes, precision=2) + "\n\n" + render_terminal_stages(
        rows, width, BOUNDARY_STAGES, "BOUNDARY DIAGNOSTICS (OVERLAPPING)", BOUNDARY_NOTES, precision=2)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last", type=int, default=5, help="number of recent recordings (default: 5)")
    parser.add_argument("--all", action="store_true", help="include every recording retained in the input logs")
    parser.add_argument("--log", type=Path, action="append", help="explicit log; repeat oldest first")
    parser.add_argument("--details", action="store_true", help="include every benchmark marker from start through tail")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="machine-readable metrics and events")
    output.add_argument("--stages", action="store_true", help="one measured-stage table with recordings as columns")
    output.add_argument("--latency", action="store_true", help="complete stop-to-dispatch timeline (default)")
    output.add_argument("--delivery", action="store_true", help="only the final-text-ready to paste-command-sent subsection")
    parser.add_argument("--target-log", type=Path, help="local test-field receipt JSONL")
    parser.add_argument("--test-runs", action="store_true", help="show only dictations with verified local test-field receipts")
    parser.add_argument("--markdown", action="store_true", help="export Markdown instead of the terminal table")
    args = parser.parse_args()
    if args.last < 1:
        parser.error("--last must be positive")
    base = Path.home() / "Library/Logs/Fluid/Fluid.log"
    paths = args.log if args.log else [p for p in (base.with_name("Fluid.log.1"), base) if p.exists()]
    if not paths:
        parser.error("no FluidVoice logs found; supply --log PATH")
    try:
        # Read-only snapshots. The next invocation picks up any newly appended tail.
        lines = [line for path in paths for line in path.read_text(errors="replace").splitlines()]
    except OSError as error:
        parser.error(str(error))
    rows = [summarize(run) for run in parse_logs(lines)]
    target_log = args.target_log or (base.with_name("DictationLatencyTarget.jsonl") if args.test_runs and not args.log else None)
    if target_log is not None and (args.target_log or target_log.exists()):
        try:
            attach_field_receipts(rows, target_log.read_text().splitlines())
        except OSError as error:
            parser.error(str(error))
    if args.test_runs:
        rows = [row for row in rows if row.get("field_receipt")]
    if not args.all:
        rows = rows[-args.last:]
    if not rows:
        parser.error("no verified test-field runs found" if args.test_runs else "no recording/pipeline start markers found")
    add_latency_breakdown(rows)
    add_delivery_breakdown(rows)
    add_pipeline_breakdown(rows)
    add_boundary_diagnostics(rows)
    if args.markdown and not args.stages and not args.details and not args.json:
        lines = ["# " + ("Text ready → paste command sent" if args.delivery else "Full timeline: Stop → text dispatch"), "", "All durations in ms. — = not measured.", "",
                 "| Stage | " + " | ".join(f"{r['time']} / {r['id']}" for r in rows) + " |",
                 "|---|" + "---:|" * len(rows)]
        for label, source, key in (DELIVERY_STAGES if args.delivery else PIPELINE_STAGES):
            lines.append("| " + label + " | " + " | ".join(
                "—" if r[source][key] is None else f"{r[source][key]:.2f}" for r in rows) + " |")
        lines += ["", "Ends at text dispatch. Start uses the stop-request callback (handler-only in older logs). Rendering and later restoration are excluded."]
        if not args.delivery:
            lines += ["", "## Boundary diagnostics (overlapping)", "",
                      "| Measurement | " + " | ".join(f"{r['time']} / {r['id']}" for r in rows) + " |",
                      "|---|" + "---:|" * len(rows)]
            for label, source, key in BOUNDARY_STAGES:
                lines.append("| " + label + " | " + " | ".join(
                    "—" if r[source][key] is None else f"{r[source][key]:.2f}" for r in rows) + " |")
            for note in BOUNDARY_NOTES:
                lines += ["", note]
        print("\n".join(lines))
        return
    print(json.dumps(rows, indent=2) if args.json else (
        (render_stages(rows) if args.stages else render(rows, args.details))
        if args.markdown or args.details else (
            render_terminal_stages(rows) if args.stages else (
                render_terminal_delivery(rows) if args.delivery else render_terminal_pipeline(rows)))))


if __name__ == "__main__":
    main()
