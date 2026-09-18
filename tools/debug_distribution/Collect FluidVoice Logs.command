#!/bin/zsh

set -u

fv_log_dir="${HOME}/Desktop/FluidVoice Debug Logs"
fv_timestamp="$(date '+%Y%m%d-%H%M%S')"
fv_collection="${fv_log_dir}/collection-${fv_timestamp}"
fv_zip="${fv_log_dir}/FluidVoice-Diagnostics-${fv_timestamp}.zip"

mkdir -p "${fv_collection}"

find "${fv_log_dir}" -maxdepth 1 -type f \
    \( -name 'fluidvoice-audio-topology-*.jsonl' -o \
       -name 'fluidvoice-audio-topology-*.stall' -o \
       -name 'fluidvoice-audio-topology-stall-*.jsonl' \) \
    -exec cp -p {} "${fv_collection}/" \;

fv_pid="$(pgrep -f '/Applications/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug' | head -1)"
if [[ -n "${fv_pid}" ]]; then
    sample "${fv_pid}" 8 -file "${fv_collection}/FluidVoice-process-sample.txt" >/dev/null 2>&1 || true
    ps -p "${fv_pid}" -o pid,ppid,%cpu,%mem,state,lstart,command > "${fv_collection}/FluidVoice-process-state.txt" 2>&1 || true
else
    echo "FluidVoice Debug was not running when logs were collected." > "${fv_collection}/FluidVoice-process-state.txt"
fi

log show --last 20m --style compact \
    --predicate 'process == "FluidVoice Debug"' \
    > "${fv_collection}/FluidVoice-system-log.txt" 2>&1 || true

system_profiler SPAudioDataType \
    > "${fv_collection}/macOS-audio-devices.txt" 2>&1 || true

sw_vers > "${fv_collection}/macOS-version.txt" 2>&1 || true

ditto -c -k --sequesterRsrc --keepParent "${fv_collection}" "${fv_zip}"

echo "Diagnostic bundle created:"
echo "${fv_zip}"
echo
echo "No meeting audio or transcript files are intentionally included."
echo "Review the ZIP before sharing because application and system logs can still contain private metadata."
open -R "${fv_zip}"
read -r "?Press Return to close."
