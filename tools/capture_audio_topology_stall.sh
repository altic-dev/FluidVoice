#!/bin/zsh

set -eu

trace_directory="${1:-/tmp/fluidvoice-audio-evidence}"

if [[ ! -d "$trace_directory" ]]; then
    print -u2 "Trace directory does not exist: $trace_directory"
    exit 2
fi

marker="$(find "$trace_directory" -maxdepth 1 -type f -name 'fluidvoice-audio-topology-*.stall' -print | sort | tail -n 1)"
if [[ -z "$marker" ]]; then
    print -u2 "No stall marker found in: $trace_directory"
    exit 3
fi

pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$marker" | head -n 1)"
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    print -u2 "Marker does not reference a live process: $marker"
    exit 4
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
sample_path="$trace_directory/fluidvoice-audio-sample-$pid-$timestamp.txt"

print "Capturing live process $pid to $sample_path"
/usr/bin/sample "$pid" 10 1 -file "$sample_path"
print "Captured: $sample_path"
print "If the stack is inconclusive, capture sysdiagnose now and record its timestamp outside the repository."
