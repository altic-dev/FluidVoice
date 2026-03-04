import os
import queue
import tempfile
import threading
import sounddevice as sd
import soundfile as sf
import keyboard
import numpy as np
import time
import tkinter as tk

# Path Configuration: Use environment variables set by the runner or fall back to defaults
DATA_DIR = os.getenv("FLUIDVOICE_DATA_DIR", os.path.expanduser("~/.local/share/fluidvoice"))
CACHE_DIR = os.path.join(DATA_DIR, "cache")
os.makedirs(CACHE_DIR, exist_ok=True)

# Point ASR engine caches to our data directory
os.environ["NEMO_CACHE_DIR"] = os.path.join(CACHE_DIR, "nemo")
os.environ["HF_HOME"] = os.path.join(CACHE_DIR, "huggingface")
os.environ["TORCH_HOME"] = os.path.join(CACHE_DIR, "torch")

# Suppress warnings
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
import logging
logging.getLogger("nemo_logger").setLevel(logging.ERROR)

class VisualCue:
    def __init__(self):
        self.root = None
        self.label = None
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", 0.8)
        
        screen_width = self.root.winfo_screenwidth()
        self.root.geometry(f"200x40+{screen_width - 220}+20")
        
        self.label = tk.Label(self.root, text="", font=("Helvetica", 12, "bold"), fg="white", width=20, height=2)
        self.label.pack()
        
        self.root.withdraw()
        self.root.mainloop()

    def show(self, text, color):
        if self.root and self.label:
            self.root.after(0, lambda: self._update(text, color))

    def _update(self, text, color):
        self.label.config(text=text, bg=color)
        self.root.deiconify()

    def hide(self):
        if self.root:
            self.root.after(0, self.root.withdraw)

cue = VisualCue()

print(f"Loading NVIDIA Parakeet... (Data dir: {DATA_DIR})")
import nemo.collections.asr as nemo_asr
model = nemo_asr.models.EncDecCTCModelBPE.from_pretrained(model_name="nvidia/parakeet-ctc-0.6b")
model.eval()
model = model.to('cuda')
print("Model loaded successfully!")

audio_queue = queue.Queue()
is_recording = False
samplerate = 16000
stream = None

def callback(indata, frames, time, status):
    if status: print(status, flush=True)
    if is_recording: audio_queue.put(indata.copy())

def start_recording():
    global is_recording, stream
    if not is_recording:
        cue.show(" ● RECORDING", "#ff4444")
        is_recording = True
        while not audio_queue.empty(): audio_queue.get()
        stream = sd.InputStream(samplerate=samplerate, channels=1, callback=callback, dtype='float32')
        stream.start()

def stop_recording():
    global is_recording, stream
    if is_recording:
        is_recording = False
        cue.show(" ⋯ TRANSCRIBING", "#f1c40f")
        stream.stop()
        stream.close()
        
        audio_data = []
        while not audio_queue.empty(): audio_data.append(audio_queue.get())
        if not audio_data:
            cue.hide()
            return

        audio_np = np.concatenate(audio_data, axis=0)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            temp_path = f.name
        sf.write(temp_path, audio_np, samplerate)
        
        try:
            transcriptions = model.transcribe([temp_path])
            result = transcriptions[0][0] if isinstance(transcriptions, tuple) else transcriptions[0]
            text = result.text if hasattr(result, 'text') else str(result)
            
            if text:
                print(f"Transcribed: {text}", flush=True)
                time.sleep(0.1)
                keyboard.write(text + " ")
        except Exception as e:
            print(f"Error: {e}", flush=True)
        finally:
            cue.hide()
            if os.path.exists(temp_path): os.remove(temp_path)

def on_key_event(e):
    if e.name in ['alt', 'left alt', 'right alt']:
        if e.event_type == 'down': start_recording()
        elif e.event_type == 'up': threading.Thread(target=stop_recording).start()

print("Ready! Hold [Alt] to dictate.")
keyboard.hook(on_key_event)
keyboard.wait()
