#!/bin/sh
echo "[start] starting cobalt entrypoint..."

if [ "${ENABLE_WARP:-1}" = "1" ] && command -v wgcf >/dev/null 2>&1 && command -v wireproxy >/dev/null 2>&1; then
    mkdir -p /tmp/warp
    if [ ! -f /tmp/warp/wgcf-profile.conf ]; then
        echo "[warp] registering Cloudflare WARP profile..."
        if (cd /tmp/warp && wgcf register --accept-tos && wgcf generate); then
            printf '\n[http]\nBindAddress = 127.0.0.1:8118\n' >> /tmp/warp/wgcf-profile.conf
        else
            echo "[warp] wgcf registration/generation failed; continuing without WARP"
        fi
    fi
    if [ -f /tmp/warp/wgcf-profile.conf ]; then
        wireproxy -c /tmp/warp/wgcf-profile.conf >/tmp/warp/wireproxy.log 2>&1 &
        i=0
        while [ "$i" -lt 20 ]; do
            if nc -z 127.0.0.1 8118 >/dev/null 2>&1; then
                export OUTBOUND_PROXY_URL="http://127.0.0.1:8118"
                echo "[✓] Cloudflare WARP outbound proxy ready on 127.0.0.1:8118"
                break
            fi
            i=$((i + 1))
            sleep 0.25
        done
    fi
fi

exec node src/cobalt
