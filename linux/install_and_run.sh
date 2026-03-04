#!/bin/bash
set -e

# Default storage location
DEFAULT_STORAGE="$HOME/.local/share/fluidvoice"

echo "============================================"
echo " FluidVoice Linux - Universal Setup"
echo "============================================"

read -p "Choose installation directory [Default: $DEFAULT_STORAGE]: " USER_STORAGE
STORAGE_ROOT="${USER_STORAGE:-$DEFAULT_STORAGE}"
VENV_DIR="$STORAGE_ROOT/venv"
CACHE_DIR="$STORAGE_ROOT/cache"
TMP_DIR="$STORAGE_ROOT/tmp"

echo "Installing to: $STORAGE_ROOT"

# Ensure directories exist
mkdir -p "$STORAGE_ROOT" "$TMP_DIR" "$CACHE_DIR"

# Set environment variables for the current session
export FLUIDVOICE_DATA_DIR="$STORAGE_ROOT"
export PIP_CACHE_DIR="$CACHE_DIR/pip"
export TMPDIR="$TMP_DIR"

# Install system dependencies
if command -v apt-get &> /dev/null; then
    echo "[1/4] Installing system dependencies..."
    sudo apt-get update
    sudo apt-get install -y python3-venv python3-pip python3-dev libportaudio2 libportaudiocpp0 portaudio19-dev build-essential ffmpeg libsndfile1 python3-tk > /dev/null
fi

# Setup Venv
echo "[2/4] Setting up virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

# Install dependencies
echo "[3/4] Installing Python dependencies (this may take a few minutes)..."
pip install --upgrade pip

# Detect if CUDA is available (basic check)
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected. Installing CUDA-optimized Torch..."
    pip install --no-input --cache-dir "$CACHE_DIR/pip" "torch==2.5.1+cu121" "torchaudio==2.5.1+cu121" --index-url https://download.pytorch.org/whl/cu121
else
    echo "No NVIDIA GPU detected. Installing CPU version of Torch..."
    pip install --no-input --cache-dir "$CACHE_DIR/pip" torch torchaudio
fi

pip install --no-input --cache-dir "$CACHE_DIR/pip" "nemo_toolkit[asr]>=2.0.0" sounddevice soundfile numpy keyboard

echo "[4/4] Setup complete!"
echo "Starting FluidVoice..."

# Verify binary link
python -c "import torch; import torchaudio; print('System Status: OK')"

# Run with sudo to capture Alt key globally
sudo -E FLUIDVOICE_DATA_DIR="$STORAGE_ROOT" "$VENV_DIR/bin/python" app.py
