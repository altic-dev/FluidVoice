FluidVoice Debug diagnostics build
==================================

1. Drag FluidVoice Debug.app to the Applications shortcut in this DMG.
2. Grant macOS permissions if prompted. Permissions are expected once on a new Mac.
3. Quit FluidVoice Debug if it is already running.
4. Control-click "Start FluidVoice Diagnostics.command" and choose Open.
5. Start a meeting transcription, let it run for at least 30-60 seconds, then end it.
6. If FluidVoice freezes, leave it running.
7. Control-click "Collect FluidVoice Logs.command" and choose Open.
8. Send back the ZIP created inside "FluidVoice Debug Logs" on the Desktop.

The collector intentionally does not copy meeting audio or transcript files. It collects
the diagnostic trace, a process sample, recent FluidVoice system logs, macOS version,
and the visible audio-device topology. Review the ZIP before sharing because logs may
still contain private metadata such as device names and file paths.

This is an internal Apple Development-signed build and is not notarized for public
distribution. macOS may require Control-click > Open or confirmation in Privacy &
Security the first time it is opened.
