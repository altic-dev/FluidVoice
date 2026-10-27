#!/bin/zsh

set -euo pipefail

fv_app="/Applications/FluidVoice Debug.app"
fv_log_dir="${HOME}/Desktop/FluidVoice Debug Logs"

if [[ ! -d "${fv_app}" ]]; then
    echo "FluidVoice Debug is not installed."
    echo "Drag FluidVoice Debug.app from the DMG into Applications, then run this helper again."
    read -r "?Press Return to close."
    exit 1
fi

if pgrep -f '/Applications/FluidVoice Debug.app/Contents/MacOS/FluidVoice Debug' >/dev/null 2>&1; then
    echo "FluidVoice Debug is already running."
    echo "Quit it normally, then run this helper again so diagnostics are enabled at launch."
    read -r "?Press Return to close."
    exit 1
fi

mkdir -p "${fv_log_dir}"

open \
    --env FLUIDVOICE_AUDIO_TOPOLOGY_DIAGNOSTICS=1 \
    --env "FLUIDVOICE_AUDIO_TOPOLOGY_TRACE_DIRECTORY=${fv_log_dir}" \
    --env FLUIDVOICE_AUDIO_TOPOLOGY_STALL_SECONDS=2 \
    -a "${fv_app}"

echo "FluidVoice Debug started with diagnostics enabled."
echo "Logs will be written to: ${fv_log_dir}"
echo
echo "Reproduce the issue. If the app freezes, leave it running and use Collect FluidVoice Logs.command."
read -r "?Press Return to close."
