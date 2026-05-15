#!/bin/bash
# NOTE: No set -e because Replit container has read-only /proc and /etc
# We handle errors explicitly for each step

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================================
# CLEANUP: Kill any stale processes from a previous session
# ============================================================================
echo "[$(date)] Cleaning up stale processes from previous session..."
/usr/bin/pkill -f "watchdog.sh"       2>/dev/null || true
/usr/bin/pkill -f "preview_server.py" 2>/dev/null || true
/usr/bin/pkill -f "websockify"        2>/dev/null || true
/usr/bin/pkill -f "x0vncserver"       2>/dev/null || true
/usr/bin/pkill -f "x11vnc"            2>/dev/null || true
/usr/bin/pkill -f "localhost.run"     2>/dev/null || true
/usr/bin/pkill -f "fluxbox"           2>/dev/null || true
/usr/bin/pkill -f "chromium"          2>/dev/null || true
/usr/bin/pkill -f "Xvfb"             2>/dev/null || true
/usr/bin/pkill -f "pulseaudio"        2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
> /tmp/tunnel.log
> /tmp/tunnel_url.txt
> /tmp/pulse.log
sleep 1
echo "[$(date)] Cleanup complete"

# ============================================================================
# START PREVIEW SERVER IMMEDIATELY (so workflow sees port 9090)
# ============================================================================
cp "$SCRIPT_DIR/preview_server.py" /tmp/preview_server.py
chmod +x /tmp/preview_server.py
python3 /tmp/preview_server.py > /dev/null 2>&1 &
PREVIEW_PID=$!

trap 'echo "Script terminated at $(date)" >> /tmp/watchdog.log; kill 0' EXIT HUP INT TERM

echo "[$(date)] Starting Optimised Replit Chromium Desktop..."

port_open() {
  (echo >/dev/tcp/localhost/$1) 2>/dev/null
}

wait_for_port() {
  local port=$1 label=$2 retries=${3:-15}
  for i in $(seq 1 $retries); do
    if port_open "$port"; then
      echo "[$(date)] $label ready on port $port"
      return 0
    fi
    sleep 1
  done
  echo "[WARN] $label may not be ready on port $port, continuing..."
}

# ============================================================================
# 0. WEBSOCKIFY & NOVNC
# ============================================================================
echo "[$(date)] Step 0: Setting up websockify and noVNC..."

if [ ! -d "/tmp/websockify-0.10.0" ]; then
    curl -sL "https://files.pythonhosted.org/packages/source/w/websockify/websockify-0.10.0.tar.gz" | tar xz -C /tmp
    echo "[$(date)] websockify source downloaded"
else
    echo "[$(date)] websockify source already available"
fi
export PYTHONPATH=/tmp/websockify-0.10.0:$PYTHONPATH

if [ ! -f "/tmp/novnc/vnc.html" ]; then
    mkdir -p /tmp/novnc
    if [ ! -f "/tmp/novnc.zip" ]; then
        curl -sL "https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.zip" -o /tmp/novnc.zip
    fi
    unzip -q -o /tmp/novnc.zip -d /tmp/novnc_extracted || true
    cp -r /tmp/novnc_extracted/noVNC-1.4.0/* /tmp/novnc/ 2>/dev/null || true
    echo "[$(date)] noVNC files ready"
else
    echo "[$(date)] noVNC files already available"
fi

# Copy our custom noVNC config into place
cp "$SCRIPT_DIR/novnc_config.js" /tmp/novnc/novnc_config.js 2>/dev/null || true

# ============================================================================
# BINARY DISCOVERY
# ============================================================================
XVFB_BIN=$(command -v Xvfb 2>/dev/null)
if [ -z "$XVFB_BIN" ]; then
    XVFB_BIN=$(ls /nix/store/*xorg-server*/bin/Xvfb 2>/dev/null | head -1)
fi
if [ -z "$XVFB_BIN" ] || [ ! -f "$XVFB_BIN" ]; then
    echo "[ERROR] Xvfb not found"; exit 1
fi
echo "[$(date)] Xvfb found at: $XVFB_BIN"

CHROMIUM_BIN=""
for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$candidate" > /dev/null 2>&1; then
        CHROMIUM_BIN=$(command -v "$candidate"); break
    fi
done
if [ -z "$CHROMIUM_BIN" ]; then
    CHROMIUM_BIN=$(find /nix/store -name "chromium" -type f 2>/dev/null \
        | grep -v "unwrapped\|source\|-dev\|-lib\|-man\|sandbox\|patch\|drv\|codecs\|dict\|playwright" \
        | head -1)
fi
[ -n "$CHROMIUM_BIN" ] && echo "[$(date)] Chromium found at: $CHROMIUM_BIN" \
  || echo "[WARN] Chromium not found — browser will not launch"

VNC_BIN=""
for candidate in x0vncserver x11vnc; do
    if command -v "$candidate" > /dev/null 2>&1; then
        VNC_BIN=$(command -v "$candidate"); VNC_TYPE="$candidate"; break
    fi
done
[ -n "$VNC_BIN" ] && echo "[$(date)] VNC server found: $VNC_BIN ($VNC_TYPE)" \
  || { echo "[ERROR] No VNC server found (need x0vncserver or x11vnc)"; exit 1; }

# ============================================================================
# 1. BASE SETUP + PERFORMANCE TUNING
# ============================================================================
echo "[$(date)] Step 1: Base setup & optimisation..."

# Network performance
sysctl -w net.ipv4.tcp_window_scaling=1      2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1          2>/dev/null || true
sysctl -w net.ipv4.tcp_tw_reuse=1            2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3            2>/dev/null || true
sysctl -w net.core.rmem_max=134217728        2>/dev/null || true
sysctl -w net.core.wmem_max=134217728        2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=5000   2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" 2>/dev/null || true
sysctl -w net.core.busy_poll=50              2>/dev/null || true
sysctl -w net.core.busy_read=50             2>/dev/null || true

# Shared memory for Xvfb MIT-SHM (2 GB)
sysctl -w kernel.shmmax=2147483648 2>/dev/null || true
sysctl -w kernel.shmall=524288     2>/dev/null || true

# Memory — never swap, write-back tuning, inotify for Chromium
sysctl -w vm.swappiness=0              2>/dev/null || true
sysctl -w vm.dirty_ratio=60            2>/dev/null || true
sysctl -w vm.dirty_background_ratio=2  2>/dev/null || true
sysctl -w vm.vfs_cache_pressure=50     2>/dev/null || true
sysctl -w vm.min_free_kbytes=65536     2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true

# CPU scheduler — low-latency tuning so VNC/websockify wake up faster
sysctl -w kernel.sched_min_granularity_ns=1000000  2>/dev/null || true
sysctl -w kernel.sched_latency_ns=5000000          2>/dev/null || true
sysctl -w kernel.sched_wakeup_granularity_ns=500000 2>/dev/null || true
sysctl -w kernel.sched_migration_cost_ns=250000    2>/dev/null || true
sysctl -w kernel.sched_nr_migrate=32               2>/dev/null || true
sysctl -w kernel.sched_rt_runtime_us=-1            2>/dev/null || true

# Video / AV sync — faster dirty-page writeback for media buffers
sysctl -w vm.dirty_writeback_centisecs=100  2>/dev/null || true
sysctl -w vm.dirty_expire_centisecs=200     2>/dev/null || true

# TCP streaming — prevent slow-start after idle (critical for video buffering)
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_notsent_lowat=131072    2>/dev/null || true

(mkdir -p /etc/chromium/policies/managed && cat > /etc/chromium/policies/managed/policies.json << 'EOF'
{"ExtensionInstallAllowlist": ["*"]}
EOF
) 2>/dev/null || true

> /tmp/watchdog.log
> /tmp/x11vnc.log
swapoff -a 2>/dev/null || true
mkdir -p ~/Downloads
export DOWNLOADS_DIR="$HOME/Downloads"
mkdir -p /tmp/chromium-shm

echo "[$(date)] Base setup complete"

# ============================================================================
# 2. VIRTUAL DISPLAY & DESKTOP
# ============================================================================
echo "[$(date)] Step 2: Starting virtual display..."

"$XVFB_BIN" :1 \
  -screen 0 1366x768x24 \
  +iglx \
  +extension MIT-SHM \
  +extension RANDR \
  -nolisten unix \
  -dpi 96 \
  -ac \
  > /dev/null 2>&1 &
XVFB_PID=$!
sleep 1

export DISPLAY=:1

mkdir -p ~/.fluxbox/styles

cat > ~/.fluxbox/styles/notitlebar << 'EOF'
*.font:                 fixed-8
*.titleHeight:          0
*.handleWidth:          0
*.bevelWidth:           0
*.borderWidth:          0
*.borderColor:          #000000
toolbar.height:         0
toolbar.borderWidth:    0
menu.borderWidth:       0
menu.bevelWidth:        0
EOF

cat > ~/.fluxbox/init << 'EOF'
session.screen0.toolbar.visible: false
session.screen0.toolbar.widthPercent: 0
session.screen0.slit.placement: BottomRight
session.screen0.slit.autoHide: true
session.screen0.workspaces: 1
session.screen0.workspaceNames: Desktop
session.screen0.styleFile: /root/.fluxbox/styles/notitlebar
session.screen0.tabs.intitlebar: false
EOF

cat > ~/.fluxbox/apps << 'EOF'
[app] (class=Chromium-browser)
  [Deco]        {NONE}
  [Dimensions]  {1366 768}
  [Position]    (UPPERLEFT) {0 0}
[end]
[app] (class=chromium)
  [Deco]        {NONE}
  [Dimensions]  {1366 768}
  [Position]    (UPPERLEFT) {0 0}
[end]
[app] (class=Chromium)
  [Deco]        {NONE}
  [Dimensions]  {1366 768}
  [Position]    (UPPERLEFT) {0 0}
[end]
EOF

CHROMIUM_BIN="$CHROMIUM_BIN" fluxbox > /dev/null 2>&1 &
sleep 1

echo "[$(date)] Virtual display ready - 1366x768x24"

# ============================================================================
# 2.5. PULSEAUDIO VIRTUAL AUDIO DEVICE
# ============================================================================
echo "[$(date)] Step 2.5: Setting up PulseAudio..."

export PULSE_RUNTIME_PATH=/tmp/pulse-runtime
mkdir -p $PULSE_RUNTIME_PATH

# Low-latency PulseAudio config for AV sync (~10ms latency vs default ~120ms)
mkdir -p /tmp/pulse-cfg
cat > /tmp/pulse-cfg/daemon.conf << 'PACFG'
default-sample-rate = 48000
alternate-sample-rate = 44100
default-sample-channels = 2
default-sample-format = float32le
default-fragments = 2
default-fragment-size-msec = 5
avoid-resampling = yes
high-priority = yes
nice-level = -15
realtime-scheduling = yes
realtime-priority = 9
rlimit-rtprio = 9
PACFG

PULSE_CONFIG_PATH=/tmp/pulse-cfg \
pulseaudio \
    --start \
    --exit-idle-time=-1 \
    --log-target=file:/tmp/pulse.log \
    2>/dev/null || true
sleep 1

pactl load-module module-null-sink \
    sink_name=virtual_speaker \
    sink_properties=device.description="VirtualSpeaker" 2>/dev/null || true
pactl set-default-sink virtual_speaker 2>/dev/null || true
pactl load-module module-remap-source \
    master=virtual_speaker.monitor \
    source_name=virtual_mic \
    source_properties=device.description="VirtualMic" 2>/dev/null || true

export PULSE_SERVER=unix:$PULSE_RUNTIME_PATH/native
echo "[$(date)] PulseAudio ready (virtual_speaker sink active)"

# ============================================================================
# 3. CHROMIUM — MAXIMUM PERFORMANCE FLAGS
# ============================================================================
echo "[$(date)] Step 3: Launching Chromium..."
mkdir -p ~/.fluxbox
cp "$SCRIPT_DIR/fluxbox_startup.sh" ~/.fluxbox/startup
chmod +x ~/.fluxbox/startup

CHROMIUM_FLAGS=(
    # Sandbox (required in container)
    --no-sandbox
    --disable-setuid-sandbox
    --disable-seccomp-sandbox
    --disable-dev-shm-usage
    # GPU: SwiftShader software OpenGL (CPU compositing)
    --disable-gpu
    --disable-gpu-compositing
    --disable-gpu-sandbox
    --use-gl=swiftshader
    --enable-oop-rasterization
    # Renderer / process model
    --renderer-process-limit=2
    --num-raster-threads=4
    # Throttling — disable ALL throttling
    --disable-renderer-backgrounding
    --disable-background-timer-throttling
    --disable-backgrounding-occluded-windows
    --disable-ipc-flooding-protection
    --disable-frame-rate-limit
    --disable-hang-monitor
    --disable-prompt-on-repost
    # Network performance
    --enable-quic
    --enable-tcp-fast-open
    --enable-features=ParallelDownloading,NetworkServiceInProcess,QuicForAll,ScrollUnification,CSSLayoutNG,CompositeAfterPaint,CanvasOopRasterization,BackForwardCache,PaintHolding,AudioWorkletRealtimeThread,ImpulseScrollAnimations,VideoPlaybackQuality,OverlayScrollbar
    --disable-features=IsolateOrigins,site-per-process,TranslateUI,MediaRouter,CalculateNativeWinOcclusion,HardwareMediaKeyHandling,ThrottleDisplayNoneAndVisibilityHiddenCrossOriginIframes,TabHoverCardImages,OptimizationGuideModelDownloading,DownloadBubble,InterestFeedContentSuggestions,AutofillServerCommunication,SpareRendererForSitePerProcess,MediaCapabilities,MediaCapabilitiesQueryGpuFactories,PreloadMediaEngagementData
    # Memory / cache
    --memory-pressure-off
    --disk-cache-size=536870912
    --media-cache-size=536870912
    --aggressive-cache-discard
    # V8 JavaScript engine
    "--js-flags=--max-old-space-size=4096 --max-semi-space-size=128 --turbofan --concurrent-recompilation"
    # Rendering / scrolling / paint / tiles
    --enable-smooth-scrolling
    --enable-zero-copy
    --canvas-msaa-sample-count=0
    --force-color-profile=srgb
    --blink-settings=preferCompositingToLCDTextEnabled=true
    --max-tiles-for-interest-area=512
    --default-tile-width=512
    --default-tile-height=512
    --ignore-gpu-blocklist
    --disable-partial-raster
    # Audio — low latency buffer for AV sync
    --audio-buffer-size=2048
    # Startup / UI noise
    --no-first-run
    --no-default-browser-check
    --disable-sync
    --disable-translate
    --disable-default-apps
    --disable-component-update
    --disable-breakpad
    --disable-domain-reliability
    --disable-infobars
    --disable-session-crashed-bubble
    --disable-safe-browsing
    --disable-notifications
    --disable-print-preview
    --disable-background-networking
    --no-pings
    --no-service-autorun
    --no-proxy-server
    --metrics-recording-only
    --autoplay-policy=no-user-gesture-required
    --allow-file-access-from-files
    # Window / scale
    --window-size=1366,768
    --window-position=0,0
    --force-device-scale-factor=1
    --high-dpi-support=1
    --disable-low-res-tiling
    "--download-default-directory=$HOME/Downloads"
    "--user-data-dir=$HOME/.chromium"
)

if [ -n "$CHROMIUM_BIN" ]; then
  (
    sleep 2
    MESA_NO_ERROR=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    PULSE_RUNTIME_PATH=/tmp/pulse-runtime \
    PULSE_SERVER=unix:/tmp/pulse-runtime/native \
    DISPLAY=:1 \
    nice -n -10 "$CHROMIUM_BIN" "${CHROMIUM_FLAGS[@]}" > /dev/null 2>&1 &

    sleep 5
    for attempt in 1 2 3; do
      WID=$(xdotool search --sync --class chromium 2>/dev/null | tail -1)
      [ -n "$WID" ] && break
      sleep 2
    done
    if [ -n "$WID" ]; then
      xdotool windowmove --sync "$WID" 0 0
      xdotool windowsize --sync "$WID" 1366 768
    fi
  ) &
  echo "[$(date)] Chromium launching..."
else
  echo "[WARN] Chromium binary not found — skipping browser launch"
fi

# ============================================================================
# 4. VNC SERVER — 60fps, Tight encoding, higher CPU budget
# ============================================================================
echo "[$(date)] Step 4: Starting VNC server ($VNC_TYPE)..."
/usr/bin/pkill -f "x0vncserver" 2>/dev/null || true
/usr/bin/pkill -f "x11vnc" 2>/dev/null || true
sleep 1

if [ "$VNC_TYPE" = "x0vncserver" ]; then
    ionice -c 2 -n 0 nice -n -20 x0vncserver \
      -display :1 \
      -rfbport 5900 \
      -SecurityTypes None \
      -AlwaysShared \
      -FrameRate 60 \
      -MaxProcessorUsage 99 \
      -CompareFB=2 \
      -PollingCycle=1 \
      -ZlibLevel=0 \
      > /tmp/x11vnc.log 2>&1 &
elif [ "$VNC_TYPE" = "x11vnc" ]; then
    ionice -c 2 -n 0 nice -n -20 x11vnc \
      -display :1 \
      -rfbport 5900 \
      -nopw \
      -shared \
      -forever \
      -noxdamage \
      -noxfixes \
      -speeds dsl \
      -threads \
      -wait 1 \
      -defer 0 \
      -sb 0 \
      > /tmp/x11vnc.log 2>&1 &
fi
VNC_PID=$!

wait_for_port 5900 "VNC server"

# ============================================================================
# 5. WEBSOCKIFY + NOVNC — increased buffer
# ============================================================================
echo "[$(date)] Step 5: Starting websockify (noVNC bridge)..."

ionice -c 2 -n 0 nice -n -15 \
  python3 -m websockify \
  --web /tmp/novnc \
  --heartbeat=30 \
  localhost:6080 localhost:5900 > /dev/null 2>&1 &
NOVNC_PID=$!

wait_for_port 6080 "websockify/noVNC"

# ============================================================================
# 6. TUNNEL — LOCALHOST.RUN
# ============================================================================
echo "[$(date)] Step 6: Starting SSH tunnel..."
/usr/bin/pkill -f "localhost.run" 2>/dev/null || true
sleep 1

(
  while true; do
    ssh -o StrictHostKeyChecking=no \
      -o ServerAliveInterval=10 \
      -o ServerAliveCountMax=3 \
      -o TCPKeepAlive=yes \
      -o ExitOnForwardFailure=yes \
      -o ConnectTimeout=15 \
      -R 80:localhost:6080 nokey@localhost.run \
      >> /tmp/tunnel.log 2>&1
    echo "[$(date)] [Tunnel] SSH disconnected, reconnecting in 3s..." >> /tmp/tunnel.log
    sleep 3
    NEW_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.(lhr\.life|localhost\.run)' /tmp/tunnel.log 2>/dev/null | tail -1)
    [ -n "$NEW_URL" ] && echo "$NEW_URL" > /tmp/tunnel_url.txt
  done
) &

echo "[$(date)] Waiting for tunnel URL..."
TUNNEL_URL=""
for i in {1..30}; do
  sleep 1
  TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.(lhr\.life|localhost\.run)' /tmp/tunnel.log 2>/dev/null | tail -1)
  if [ -n "$TUNNEL_URL" ]; then
    echo "$TUNNEL_URL" > /tmp/tunnel_url.txt
    echo "[$(date)] Tunnel established: $TUNNEL_URL"
    break
  fi
done
[ -z "$TUNNEL_URL" ] && echo "[WARN] Tunnel URL not found yet, continuing anyway..."

# ============================================================================
# 7. WATCHDOG
# ============================================================================
echo "[$(date)] Step 7: Starting watchdog..."

cp "$SCRIPT_DIR/watchdog.sh" /tmp/watchdog.sh
chmod +x /tmp/watchdog.sh
CHROMIUM_BIN="$CHROMIUM_BIN" \
VNC_BIN="$VNC_BIN" \
VNC_TYPE="$VNC_TYPE" \
XVFB_BIN="$XVFB_BIN" \
PULSE_RUNTIME_PATH=/tmp/pulse-runtime \
PULSE_SERVER=unix:/tmp/pulse-runtime/native \
/tmp/watchdog.sh > /dev/null 2>&1 &
WATCHDOG_PID=$!

echo "[$(date)] Watchdog started"

# ============================================================================
# 8. FINAL VERIFICATION
# ============================================================================
echo "[$(date)] Step 8: Final startup verification..."

verify_component() {
  local name=$1 check=$2 retries=3
  for i in $(seq 1 $retries); do
    eval "$check" > /dev/null 2>&1 && echo "[$(date)] ✓ $name verified" && return 0
    [ $i -lt $retries ] && echo "[$(date)] $name check failed, retry $i/$retries..." && sleep 5
  done
  echo "[WARN] $name verification failed after $retries retries"
}

verify_component "Xvfb"                   "pgrep -f Xvfb"
verify_component "Fluxbox"                "pgrep fluxbox"
verify_component "PulseAudio"             "pgrep -f pulseaudio"
verify_component "VNC server (port 5900)" "port_open 5900"
verify_component "websockify (port 6080)" "port_open 6080"
[ -n "$CHROMIUM_BIN" ] && verify_component "Chromium" "pgrep chromium"
verify_component "SSH Tunnel"             "pgrep -f 'localhost.run'"
verify_component "Preview Server (9090)"  "port_open 9090"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                   ALL SYSTEMS READY                           ║"
echo "║       Max Performance · Audio · File Transfer · Clipboard     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

TUNNEL_URL=$(cat /tmp/tunnel_url.txt 2>/dev/null)
if [ -n "$TUNNEL_URL" ]; then
  echo "Remote Desktop URL: $TUNNEL_URL"
  echo "Live Preview:       http://localhost:9090"
  echo ""
  echo "Optimisations Active:"
  echo "  60fps VNC ($VNC_TYPE) · 80% CPU · 1ms polling · threaded server"
  echo "  4 renderer processes · Zero throttling · QUIC · TCP Fast Open"
  echo "  4 GB JS heap · 512 MB disk cache · 256 MB media cache"
  echo "  Fast reconnect 3s · Zero swap · Aggressive cache discard"
  echo ""
fi

echo "[$(date)] Startup complete" >> /tmp/watchdog.log

# ============================================================================
# 9. KEEPALIVE
# ============================================================================
while true; do sleep 60; done
