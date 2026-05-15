// noVNC runtime config — loaded before noVNC v1.4.0 connects.
// Pre-sets all connection parameters using exact noVNC v1.4.0 param names.
window.rfbConfig = {
    qualityLevel: 6,          // balanced quality — faster JPEG encode for video
    compressionLevel: 0,      // zero compression CPU cost
    shared: true,
    reconnect: true,
    reconnect_delay: 100,     // 100ms fast reconnect (was 300ms)
    resizeSession: true,
    viewOnly: false,
    showDotCursor: true,
    view_clip: true,
    preferRaw: false,         // let noVNC pick best encoding (Tight better for video)
    // Clipboard bidirectional sync
    clipboardUp: true,
    clipboardDown: true,
    clipboardSeamless: true,
    // Pointer events
    dragViewport: false,
    // Scaling
    scaleViewport: true,
};
