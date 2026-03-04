#!/bin/bash
# Pre-authenticate sudo for the background process
sudo -v

# Use same storage as the installer
DEFAULT_STORAGE="$HOME/.local/share/fluidvoice"
STORAGE_ROOT="${FLUIDVOICE_DATA_DIR:-$DEFAULT_STORAGE}"
VENV_PYTHON="$STORAGE_ROOT/venv/bin/python"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "Error: Virtual environment not found at $STORAGE_ROOT/venv"
    echo "Please run ./install_and_run.sh first."
    exit 1
fi

echo "Starting FluidVoice in the background..."
# Run in background with nohup, preserving the storage root env var
nohup sudo -E FLUIDVOICE_DATA_DIR="$STORAGE_ROOT" "$VENV_PYTHON" app.py > "$STORAGE_ROOT/fluidvoice.log" 2>&1 &

echo "------------------------------------------------"
echo " FluidVoice is now RUNNING."
echo " Logs: tail -f $STORAGE_ROOT/fluidvoice.log"
echo " Stop: ./stop.sh"
echo "------------------------------------------------"
