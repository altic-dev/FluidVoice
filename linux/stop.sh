#!/bin/bash
echo "Stopping FluidVoice..."
# Kill the specific python process running app.py
sudo pkill -f "python app.py"
echo "FluidVoice stopped."
