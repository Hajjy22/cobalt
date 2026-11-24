#!/bin/sh
echo "[start] starting cobalt entrypoint..."

start_usque() {
    usque http-proxy --http2 --always-reconnect -k 15s -c /tmp/warp/config.json -b 127.0.0.1 -p 8118 -d 1.1.1.1 >/tmp/warp/usque.log 2>&1 &
    WARP_PID=$!
}

check_warp() {
    node -e 'import("undici").then(async ({ProxyAgent, fetch}) => { const d = new ProxyAgent("http://127.0.0.1:8118"); const r = await fetch("https://1.1.1.1/cdn-cgi/trace", { dispatcher: d, signal: AbortSignal.timeout(6000) }); const t = await r.text(); if (!t.includes("warp=on")) process.exit(1); console.log("[warp] trace:", t.split("\n").filter(l => l.startsWith("ip=") || l.startsWith("warp=")).join(" ")); process.exit(0); }).catch(e => { console.error("[warp] proxy check failed:", e.message); process.exit(1); })'
}

if [ -z "${OUTBOUND_PROXY_URL:-}" ] && [ "${ENABLE_WARP:-1}" = "1" ] && command -v usque >/dev/null 2>&1; then
    mkdir -p /tmp/warp
    if [ ! -f /tmp/warp/config.json ]; then
        echo "[warp] registering Cloudflare WARP MASQUE profile via usque..."
        if ! usque register --accept-tos -c /tmp/warp/config.json; then
            echo "[warp] usque registration failed; continuing without WARP"
        fi
    fi
    if [ -f /tmp/warp/config.json ]; then
        echo "[warp] starting usque HTTP/2 TCP proxy on 127.0.0.1:8118..."
        start_usque
        i=0
        while [ "$i" -lt 40 ]; do
            if nc -z 127.0.0.1 8118 >/dev/null 2>&1; then
                break
            fi
            i=$((i + 1))
            sleep 0.25
        done
        if check_warp; then
            export OUTBOUND_PROXY_URL="http://127.0.0.1:8118"
            echo "[✓] Cloudflare WARP HTTP/2 outbound proxy verified on 127.0.0.1:8118"
            # Background watchdog: keep WARP HTTP/2 tunnel warm & auto-restart if idle-stalled
            (
                fails=0
                while true; do
                    sleep 60
                    if check_warp >/dev/null 2>&1; then
                        fails=0
                    else
                        fails=$((fails + 1))
                        if [ "$fails" -ge 2 ]; then
                            echo "[warp] watchdog restarting stalled usque tunnel..."
                            kill "$WARP_PID" >/dev/null 2>&1 || true
                            sleep 1
                            start_usque
                            fails=0
                        fi
                    fi
                done
            ) &
        else
            echo "[!] Cloudflare WARP HTTP/2 tunnel unreachable on this host; disabling WARP proxy"
            tail -n 20 /tmp/warp/usque.log 2>/dev/null || true
            kill "$WARP_PID" >/dev/null 2>&1 || true
        fi
    fi
fi

exec node src/cobalt
