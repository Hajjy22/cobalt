#!/bin/sh
echo "[start] starting cobalt entrypoint..."

if [ "${ENABLE_WARP:-1}" = "1" ] && command -v wgcf >/dev/null 2>&1 && command -v wireproxy >/dev/null 2>&1; then
    mkdir -p /tmp/warp
    if [ ! -f /tmp/warp/wgcf-profile.conf ]; then
        echo "[warp] registering Cloudflare WARP profile..."
        if (cd /tmp/warp && wgcf register --accept-tos && wgcf generate); then
            sed -i 's/engage\.cloudflareclient\.com:2408/162.159.192.1:2408/g' /tmp/warp/wgcf-profile.conf
            printf '\n[http]\nBindAddress = 127.0.0.1:8118\n' >> /tmp/warp/wgcf-profile.conf
        else
            echo "[warp] wgcf registration/generation failed; continuing without WARP"
        fi
    fi
    if [ -f /tmp/warp/wgcf-profile.conf ]; then
        wireproxy -c /tmp/warp/wgcf-profile.conf >/tmp/warp/wireproxy.log 2>&1 &
        WARP_PID=$!
        i=0
        while [ "$i" -lt 20 ]; do
            if nc -z 127.0.0.1 8118 >/dev/null 2>&1; then
                break
            fi
            i=$((i + 1))
            sleep 0.25
        done
        if node -e 'import("undici").then(async ({ProxyAgent, fetch}) => { const d = new ProxyAgent("http://127.0.0.1:8118"); const r = await fetch("https://1.1.1.1/cdn-cgi/trace", { dispatcher: d, signal: AbortSignal.timeout(5000) }); const t = await r.text(); console.log("[warp] trace:", t.split("\n").filter(l => l.startsWith("ip=") || l.startsWith("warp=")).join(" ")); process.exit(0); }).catch(e => { console.error("[warp] proxy check failed:", e.message); process.exit(1); })'; then
            export OUTBOUND_PROXY_URL="http://127.0.0.1:8118"
            echo "[✓] Cloudflare WARP outbound proxy verified on 127.0.0.1:8118"
        else
            echo "[!] Cloudflare WARP tunnel unreachable on this host; disabling WARP proxy"
            kill "$WARP_PID" >/dev/null 2>&1 || true
        fi
    fi
fi

exec node src/cobalt
