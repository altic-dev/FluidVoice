#!/bin/bash

# Ensure we have a target directory
if [ -z "$1" ]; then
    echo "Usage: $0 <target_installation_directory>"
    echo "Example: $0 /media/your_username/external_drive/fluidvoice"
    exit 1
fi

TARGET_DIR=$(readlink -f "$1")

# --- ROOT DRIVE CHECK ---
# Check if the target directory is on the root partition (/)
ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
TARGET_DEV=$(df "$1" 2>/dev/null | tail -1 | awk '{print $1}' || df $(dirname "$1") | tail -1 | awk '{print $1}')

if [ "$ROOT_DEV" == "$TARGET_DEV" ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "WARNING: $TARGET_DIR is on your ROOT partition ($ROOT_DEV)!"
    echo "Your root drive is nearly full. Please provide a path to"
    echo "an EXTERNAL drive (usually under /media/your_username/)."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    read -p "Do you REALLY want to continue? (y/N) " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

mkdir -p "$TARGET_DIR"

# Define paths within the target directory
VENV_DIR="$TARGET_DIR/venv"
CACHE_DIR="$TARGET_DIR/cache"
TMP_DIR="$TARGET_DIR/tmp"

# Export variables for the script process
export FLUIDVOICE_DATA_DIR="$TARGET_DIR"
export HF_HOME="$CACHE_DIR/huggingface"
export TORCH_HOME="$CACHE_DIR/torch"
export NEMO_CACHE_DIR="$CACHE_DIR/nemo"
export PIP_CACHE_DIR="$CACHE_DIR/pip"
export TMPDIR="$TMP_DIR"

mkdir -p "$HF_HOME" "$TORCH_HOME" "$NEMO_CACHE_DIR" "$PIP_CACHE_DIR" "$TMPDIR"

echo "Installing system dependencies..."
sudo apt-get update && sudo apt-get install -y \
    python3-venv python3-dev libasound2-dev libportaudio2 python3-tk ffmpeg

# Create virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

echo "Installing Python dependencies (STRICTLY using $TARGET_DIR for build/cache)..."
# Force pip to use our TMPDIR and NO global cache
"$VENV_DIR/bin/pip" install --upgrade pip

# We use --no-cache-dir and --build to ensure NOTHING touches /root/.cache or /tmp
# Note: --build is deprecated in newer pip, we use TMPDIR instead which is respected
"$VENV_DIR/bin/pip" install --no-cache-dir \
    numpy \
    sounddevice \
    soundfile \
    keyboard \
    torch \
    torchvision \
    torchaudio \
    Cython \
    "nemo_toolkit[asr]"

echo "Installation complete!"
echo "Starting FluidVoice in the background..."

# Use sudo -E to preserve all our redirected paths (TMPDIR, HF_HOME, etc.)
nohup sudo -E FLUIDVOICE_DATA_DIR="$TARGET_DIR" \
               HF_HOME="$HF_HOME" \
               TORCH_HOME="$TORCH_HOME" \
               NEMO_CACHE_DIR="$NEMO_CACHE_DIR" \
               TMPDIR="$TMP_DIR" \
               "$VENV_DIR/bin/python3" app.py > "$TARGET_DIR/fluidvoice.log" 2>&1 &

echo "------------------------------------------------"
echo " FluidVoice is now RUNNING in the background."
echo " Logs: tail -f $TARGET_DIR/fluidvoice.log"
echo " Stop: ./stop.sh"
echo "------------------------------------------------"
