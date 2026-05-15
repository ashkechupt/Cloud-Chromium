# Cloud-Chromium
A cloud Chromium that self heals (Daas) and an optimised headless chromium with secure tunnel multiplexing.
Optimised Chromium Desktop
A Replit-hosted Chromium desktop environment running inside VNC + noVNC, with a localhost.run tunnel for remote access.

What it does
Boots a virtual X desktop with Fluxbox and Chromium
Streams the desktop through VNC and noVNC
Exposes a local preview UI on port 9090
Creates a remote desktop tunnel through localhost.run
Includes a watchdog that auto-recovers crashed services
Enables audio, file transfer, and clipboard support
How to run
Click Run in Replit.

The startup flow will:

Prepare noVNC and websockify
Start Xvfb
Launch Fluxbox
Start PulseAudio
Open Chromium with performance-focused flags
Start the VNC server
Start the noVNC bridge
Create the tunnel
Start the watchdog
Main files
File	Purpose
main.sh	Main startup orchestrator
fluxbox_startup.sh	Launches Chromium inside Fluxbox
watchdog.sh	Restarts failed services automatically
preview_server.py	Local preview UI on port 9090
novnc_config.js	noVNC runtime settings
OPTIMIZATIONS.md	Performance notes
zipFile.zip	Original imported archive, kept intact
Performance focus
This project is tuned for:

smoother video playback
lower input latency
faster reconnects
less UI throttling
better responsiveness under load

Notes
The preview UI is served locally on port 9090
The remote desktop tunnel URL is generated automatically at startup
The watchdog keeps the session alive and recovers common failures
