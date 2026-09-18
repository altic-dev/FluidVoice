#!/bin/sh
set -eu

input_dir="${FLUID_ASR_BASELINE_INPUTS:-${SRCROOT}/Tests/FluidASRBaselineHost/Inputs}"
output_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ASRBaselineInputs"

case "$input_dir" in
    /*) ;;
    *)
        echo "error: FLUID_ASR_BASELINE_INPUTS must be an absolute path, got: $input_dir" >&2
        exit 1
        ;;
esac

if [ ! -d "$input_dir" ]; then
    echo "error: ASR baseline inputs directory not found: $input_dir" >&2
    exit 1
fi

mkdir -p "$output_dir"
ditto "$input_dir" "$output_dir"
