#!/bin/bash
# Fluxbox startup — launched by Fluxbox's startup hook.
# Note: dbus-launch is not used here because it may not be available in all envs.

CHROMIUM_BIN="${CHROMIUM_BIN:-}"
if [ -z "$CHROMIUM_BIN" ]; then
    for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "$candidate" > /dev/null 2>&1; then
            CHROMIUM_BIN=$(command -v "$candidate"); break
        fi
    done
fi

if [ -n "$CHROMIUM_BIN" ]; then
    MESA_NO_ERROR=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    PULSE_RUNTIME_PATH=/tmp/pulse-runtime \
    PULSE_SERVER=unix:/tmp/pulse-runtime/native \
    DISPLAY=:1 \
    nice -n -10 "$CHROMIUM_BIN" \
      --no-sandbox \
      --disable-setuid-sandbox \
      --disable-seccomp-sandbox \
      --disable-dev-shm-usage \
      --disable-gpu \
      --disable-gpu-compositing \
      --disable-gpu-sandbox \
      --use-gl=swiftshader \
      --enable-oop-rasterization \
      --renderer-process-limit=2 \
      --num-raster-threads=4 \
      --disable-renderer-backgrounding \
      --disable-background-timer-throttling \
      --disable-backgrounding-occluded-windows \
      --disable-ipc-flooding-protection \
      --disable-frame-rate-limit \
      --disable-hang-monitor \
      --disable-prompt-on-repost \
      --enable-quic \
      --enable-tcp-fast-open \
      --enable-features=ParallelDownloading,NetworkServiceInProcess,QuicForAll,ScrollUnification,CSSLayoutNG,CompositeAfterPaint,CanvasOopRasterization,BackForwardCache,PaintHolding,AudioWorkletRealtimeThread,ImpulseScrollAnimations,VideoPlaybackQuality,OverlayScrollbar \
      --disable-features=IsolateOrigins,site-per-process,TranslateUI,MediaRouter,CalculateNativeWinOcclusion,HardwareMediaKeyHandling,ThrottleDisplayNoneAndVisibilityHiddenCrossOriginIframes,TabHoverCardImages,OptimizationGuideModelDownloading,DownloadBubble,InterestFeedContentSuggestions,AutofillServerCommunication,SpareRendererForSitePerProcess,MediaCapabilities,MediaCapabilitiesQueryGpuFactories,PreloadMediaEngagementData \
      --memory-pressure-off \
      --disk-cache-size=536870912 \
      --media-cache-size=536870912 \
      --aggressive-cache-discard \
      --js-flags="--max-old-space-size=4096 --max-semi-space-size=128 --turbofan --concurrent-recompilation" \
      --enable-smooth-scrolling \
      --enable-zero-copy \
      --canvas-msaa-sample-count=0 \
      --force-color-profile=srgb \
      --blink-settings=preferCompositingToLCDTextEnabled=true \
      --max-tiles-for-interest-area=512 \
      --default-tile-width=512 \
      --default-tile-height=512 \
      --ignore-gpu-blocklist \
      --disable-partial-raster \
      --audio-buffer-size=2048 \
      --no-first-run \
      --no-default-browser-check \
      --disable-sync \
      --disable-translate \
      --disable-default-apps \
      --disable-component-update \
      --disable-breakpad \
      --disable-domain-reliability \
      --disable-infobars \
      --disable-session-crashed-bubble \
      --disable-safe-browsing \
      --disable-notifications \
      --disable-print-preview \
      --disable-background-networking \
      --no-pings \
      --no-service-autorun \
      --no-proxy-server \
      --metrics-recording-only \
      --autoplay-policy=no-user-gesture-required \
      --allow-file-access-from-files \
      --window-size=1366,768 \
      --window-position=0,0 \
      --force-device-scale-factor=1 \
      --high-dpi-support=1 \
      --disable-low-res-tiling \
      --download-default-directory="$HOME/Downloads" \
      --user-data-dir="$HOME/.chromium" > /dev/null 2>&1 &
fi

# Start fluxbox directly (dbus-launch is optional and may not be present)
if command -v dbus-launch > /dev/null 2>&1; then
    exec dbus-launch --exit-with-session fluxbox
else
    exec fluxbox
fi
