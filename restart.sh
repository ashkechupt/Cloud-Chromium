#!/bin/bash
echo "Stopping all services..."
/usr/bin/pkill -9 -f "Xvfb" 2>/dev/null
/usr/bin/pkill -9 -f "x0vncserver" 2>/dev/null
/usr/bin/pkill -9 -f "websockify" 2>/dev/null
/usr/bin/pkill -9 -f "fluxbox" 2>/dev/null
/usr/bin/pkill -9 -f "chromium" 2>/dev/null
/usr/bin/pkill -9 -f "localhost.run" 2>/dev/null
/usr/bin/pkill -9 -f "watchdog.sh" 2>/dev/null
/usr/bin/pkill -9 -f "preview_server" 2>/dev/null
rm -f /tmp/watchdog_restarting.lock /tmp/tunnel_url.txt /tmp/tunnel.log
sleep 3
echo "Starting..."
exec bash main.sh
