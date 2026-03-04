#!/bin/bash

# Pre-authenticate sudo for the background process
sudo -v

# Allow passing the storage directory as an argument
if [ ! -z "$1" ]; then
    STORAGE_ROOT=$(readlink -f "$1")
else
    # Fallback to current directory or a default (user should ideally provide it)
    DEFAULT_STORAGE="$HOME/.local/share/fluidvoice"
    STORAGE_ROOT="${FLUIDVOICE_DATA_DIR:-$DEFAULT_STORAGE}"
fi

VENV_PYTHON="$STORAGE_ROOT/venv/bin/python"
CACHE_DIR="$STORAGE_ROOT/cache"
TMP_DIR="$STORAGE_ROOT/tmp"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "Error: Virtual environment not found at $STORAGE_ROOT/venv"
    echo "Please run: ./install_and_run.sh $STORAGE_ROOT"
    exit 1
fi

mkdir -p "$TMP_DIR"

echo "Starting FluidVoice from $STORAGE_ROOT..."

# Run in background with sudo -E to preserve the storage and cache env vars
nohup sudo -E FLUIDVOICE_DATA_DIR="$STORAGE_ROOT" \
               HF_HOME="$CACHE_DIR/huggingface" \
               TORCH_HOME="$CACHE_DIR/torch" \
               NEMO_CACHE_DIR="$CACHE_DIR/nemo" \
               TMPDIR="$TMP_DIR" \
               "$VENV_PYTHON" app.py > "$STORAGE_ROOT/fluidvoice.log" 2>&1 &

echo "------------------------------------------------"
echo " FluidVoice is now RUNNING."
echo " Logs: tail -f $STORAGE_ROOT/fluidvoice.log"
echo " Stop: ./stop.sh"
echo "------------------------------------------------"
