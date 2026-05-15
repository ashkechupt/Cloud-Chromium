#!/bin/bash
# Self-healing watchdog — 5s cycle, real HTTP health checks, no external tools.

WATCHDOG_LOG="/tmp/watchdog.log"
TUNNEL_LOG="/tmp/tunnel.log"
TUNNEL_URL_FILE="/tmp/tunnel_url.txt"
LOCK_FILE="/tmp/watchdog_restarting.lock"
DISPLAY=:1
export DISPLAY
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/tmp/pulse-runtime}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/tmp/pulse-runtime/native}"

# ── Binary discovery ────────────────────────────────────────────────────────
if [ -z "$XVFB_BIN" ]; then
    XVFB_BIN=$(command -v Xvfb 2>/dev/null)
    if [ -z "$XVFB_BIN" ]; then
        XVFB_BIN=$(ls /nix/store/*xorg-server*/bin/Xvfb 2>/dev/null | head -1)
    fi
fi

if [ -z "$CHROMIUM_BIN" ]; then
    for _c in chromium chromium-browser google-chrome google-chrome-stable; do
        command -v "$_c" > /dev/null 2>&1 && CHROMIUM_BIN=$(command -v "$_c") && break
    done
fi

if [ -z "$VNC_BIN" ]; then
    for _v in x0vncserver x11vnc; do
        command -v "$_v" > /dev/null 2>&1 && VNC_BIN=$(command -v "$_v") && VNC_TYPE="$_v" && break
    done
fi
VNC_TYPE="${VNC_TYPE:-x0vncserver}"

# ── Helpers ─────────────────────────────────────────────────────────────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"; }
port_open() { (echo >/dev/tcp/localhost/"$1") 2>/dev/null; }

url_alive() {
    local url="$1"
    [ -z "$url" ] && return 1
    python3 -c "
import urllib.request, sys
try:
    urllib.request.urlopen('$url', timeout=4)
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# ── Restart functions ────────────────────────────────────────────────────────
restart_xvfb() {
    log "[Xvfb] restarting..."
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
    "$XVFB_BIN" :1 -screen 0 1366x768x24 +iglx +extension MIT-SHM +extension RANDR \
        -nolisten unix -dpi 96 -ac > /dev/null 2>&1 &
    sleep 2
}

restart_fluxbox() {
    log "[Fluxbox] restarting..."
    CHROMIUM_BIN="$CHROMIUM_BIN" fluxbox > /dev/null 2>&1 &
    sleep 1
}

restart_pulseaudio() {
    log "[PulseAudio] restarting..."
    /usr/bin/pkill -f pulseaudio 2>/dev/null; sleep 1
    pulseaudio --start --exit-idle-time=-1 --log-target=file:/tmp/pulse.log 2>/dev/null || true
    sleep 1
    pactl load-module module-null-sink sink_name=virtual_speaker \
        sink_properties=device.description="VirtualSpeaker" 2>/dev/null || true
    pactl set-default-sink virtual_speaker 2>/dev/null || true
    pactl load-module module-remap-source master=virtual_speaker.monitor \
        source_name=virtual_mic source_properties=device.description="VirtualMic" 2>/dev/null || true
}

restart_vnc() {
    log "[VNC] restarting ($VNC_TYPE)..."
    /usr/bin/pkill -f "x0vncserver" 2>/dev/null
    /usr/bin/pkill -f "x11vnc" 2>/dev/null
    sleep 1
    if [ "$VNC_TYPE" = "x0vncserver" ]; then
        ionice -c 2 -n 0 nice -n -20 x0vncserver \
            -display :1 -rfbport 5900 \
            -SecurityTypes None -AlwaysShared \
            -FrameRate 60 -MaxProcessorUsage 99 \
            -CompareFB=2 -PollingCycle=1 \
            -ZlibLevel=0 \
            > /tmp/x11vnc.log 2>&1 &
    else
        ionice -c 2 -n 0 nice -n -20 x11vnc \
            -display :1 -rfbport 5900 \
            -nopw -shared -forever \
            -noxdamage -noxfixes -speeds dsl \
            -threads -wait 1 -defer 0 -sb 0 \
            > /tmp/x11vnc.log 2>&1 &
    fi
    sleep 1
}

restart_websockify() {
    log "[websockify] restarting..."
    /usr/bin/pkill -f "websockify" 2>/dev/null; sleep 1
    ionice -c 2 -n 0 nice -n -15 \
        python3 -m websockify --web /tmp/novnc \
        --heartbeat=30 \
        localhost:6080 localhost:5900 > /dev/null 2>&1 &
    sleep 2
}

restart_chromium() {
    [ -z "$CHROMIUM_BIN" ] && return
    log "[Chromium] restarting..."
    MESA_NO_ERROR=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    PULSE_RUNTIME_PATH=/tmp/pulse-runtime \
    PULSE_SERVER=unix:/tmp/pulse-runtime/native \
    DISPLAY=:1 nice -n -10 "$CHROMIUM_BIN" \
        --no-sandbox --disable-setuid-sandbox --disable-seccomp-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu --disable-gpu-compositing --disable-gpu-sandbox \
        --use-gl=swiftshader --enable-oop-rasterization \
        --no-first-run --no-default-browser-check \
        --disable-default-apps --disable-sync --disable-translate \
        --renderer-process-limit=2 \
        --num-raster-threads=4 \
        --disable-renderer-backgrounding \
        --disable-background-timer-throttling \
        --disable-backgrounding-occluded-windows \
        --disable-ipc-flooding-protection \
        --disable-frame-rate-limit \
        --enable-quic --enable-tcp-fast-open \
        --enable-features=ParallelDownloading,NetworkServiceInProcess,QuicForAll,ScrollUnification,CSSLayoutNG,CompositeAfterPaint,CanvasOopRasterization,BackForwardCache,PaintHolding,AudioWorkletRealtimeThread,ImpulseScrollAnimations,VideoPlaybackQuality,OverlayScrollbar \
        --disable-features=IsolateOrigins,site-per-process,TranslateUI,MediaRouter,CalculateNativeWinOcclusion,HardwareMediaKeyHandling,ThrottleDisplayNoneAndVisibilityHiddenCrossOriginIframes,TabHoverCardImages,OptimizationGuideModelDownloading,DownloadBubble,InterestFeedContentSuggestions,AutofillServerCommunication,SpareRendererForSitePerProcess,MediaCapabilities,MediaCapabilitiesQueryGpuFactories,PreloadMediaEngagementData \
        --memory-pressure-off \
        --disk-cache-size=536870912 --media-cache-size=536870912 \
        --aggressive-cache-discard \
        "--js-flags=--max-old-space-size=4096 --max-semi-space-size=128 --turbofan --concurrent-recompilation" \
        --enable-smooth-scrolling --enable-zero-copy \
        --canvas-msaa-sample-count=0 \
        --force-color-profile=srgb \
        --blink-settings=preferCompositingToLCDTextEnabled=true \
        --max-tiles-for-interest-area=512 \
        --default-tile-width=512 --default-tile-height=512 \
        --ignore-gpu-blocklist \
        --disable-partial-raster \
        --audio-buffer-size=2048 \
        --disable-background-networking \
        --no-pings --no-service-autorun \
        --no-proxy-server --metrics-recording-only \
        --autoplay-policy=no-user-gesture-required \
        --user-data-dir="$HOME/.chromium" \
        --allow-file-access-from-files \
        --download-default-directory="$HOME/Downloads" \
        --window-size=1366,768 \
        --window-position=0,0 > /dev/null 2>&1 &
}

restart_tunnel() {
    log "[Tunnel] restarting SSH tunnel..."
    /usr/bin/pkill -f "localhost.run" 2>/dev/null; sleep 2
    (
        while true; do
            ssh -o StrictHostKeyChecking=no \
                -o ServerAliveInterval=10 \
                -o ServerAliveCountMax=3 \
                -o TCPKeepAlive=yes \
                -o ExitOnForwardFailure=yes \
                -o ConnectTimeout=15 \
                -R 80:localhost:6080 nokey@localhost.run >> "$TUNNEL_LOG" 2>&1
            log "[Tunnel] SSH dropped — reconnecting in 3s..."
            sleep 3
            NEW_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.(lhr\.life|localhost\.run)' \
                "$TUNNEL_LOG" 2>/dev/null | tail -1)
            [ -n "$NEW_URL" ] && echo "$NEW_URL" > "$TUNNEL_URL_FILE"
        done
    ) &
    for _i in $(seq 1 30); do
        sleep 1
        NEW_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.(lhr\.life|localhost\.run)' \
            "$TUNNEL_LOG" 2>/dev/null | tail -1)
        if [ -n "$NEW_URL" ]; then
            echo "$NEW_URL" > "$TUNNEL_URL_FILE"
            log "[Tunnel] new URL: $NEW_URL"
            break
        fi
    done
}

# ── Prevent duplicate instances ──────────────────────────────────────────────
MYPID=$$
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && [ "$OLD_PID" != "$MYPID" ]; then
        exit 0
    fi
fi
echo "$MYPID" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "[Watchdog] started (PID $$, VNC=$VNC_TYPE)"

# ── Main loop ────────────────────────────────────────────────────────────────
COUNTER=0
TUNNEL_FAIL_STREAK=0

while true; do
    COUNTER=$((COUNTER + 1))

    # Xvfb — every cycle (5s)
    if ! /usr/bin/pgrep -f Xvfb > /dev/null 2>&1; then restart_xvfb; fi

    # VNC port — every cycle (5s)
    if ! port_open 5900; then restart_vnc; fi

    # websockify port — every cycle (5s)
    if ! port_open 6080; then restart_websockify; fi

    # Tunnel — SSH alive check every 2 cycles (10s)
    if [ $((COUNTER % 2)) -eq 0 ]; then
        CURRENT_URL=$(cat "$TUNNEL_URL_FILE" 2>/dev/null)
        SSH_ALIVE=$(/usr/bin/pgrep -f "localhost.run" > /dev/null 2>&1 && echo yes || echo no)
        if [ "$SSH_ALIVE" = "no" ]; then
            TUNNEL_FAIL_STREAK=$((TUNNEL_FAIL_STREAK + 1))
            [ $TUNNEL_FAIL_STREAK -ge 2 ] && restart_tunnel && TUNNEL_FAIL_STREAK=0
        elif ! url_alive "$CURRENT_URL"; then
            TUNNEL_FAIL_STREAK=$((TUNNEL_FAIL_STREAK + 1))
            if [ $TUNNEL_FAIL_STREAK -ge 3 ]; then
                log "[Tunnel] URL not responding — forcing reconnect"
                restart_tunnel; TUNNEL_FAIL_STREAK=0
            fi
        else
            TUNNEL_FAIL_STREAK=0
        fi
    fi

    # PulseAudio — every 3 cycles (15s)
    if [ $((COUNTER % 3)) -eq 0 ]; then
        if ! /usr/bin/pgrep -f "pulseaudio" > /dev/null 2>&1; then restart_pulseaudio; fi
    fi

    # Chromium — every 3 cycles (15s)
    if [ $((COUNTER % 3)) -eq 0 ]; then
        if [ -n "$CHROMIUM_BIN" ] && ! /usr/bin/pgrep chromium > /dev/null 2>&1; then
            restart_chromium
        fi
    fi

    # Fluxbox — every 4 cycles (20s)
    if [ $((COUNTER % 4)) -eq 0 ]; then
        if ! /usr/bin/pgrep fluxbox > /dev/null 2>&1; then restart_fluxbox; fi
    fi

    sleep 5
done
