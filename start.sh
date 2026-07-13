#!/bin/bash

export UUID="a29738e5-bee1-c0fc-b484-ae7c49cbc828"
echo "🔑 核心 UUID 密码已强制锁定为固定值: $UUID"

echo "🔍 正在打捞当前容器的真实外网出口 IP 与归属地..."
REAL_IP=$(curl -s --max-time 3 ifconfig.me)
REAL_COUNTRY=$(curl -s --max-time 3 ipinfo.io/country)

if [ -z "$REAL_IP" ]; then REAL_IP="DynamicIP"; fi
if [ -z "$REAL_COUNTRY" ]; then REAL_COUNTRY="Cloud"; fi

NODE_REMARK="${REAL_COUNTRY}_${REAL_IP}"
echo "📍 探测成功！当前主机实际地理标记: $NODE_REMARK"

sed -i "s/UUID_PLACEHOLDER/$UUID/g" /app/sb-config.json
sed -i "s/UUID_PLACEHOLDER/$UUID/g" /app/www/index.html
sed -i "s/NODE_REMARK_PLACEHOLDER/$NODE_REMARK/g" /app/www/index.html

httpd -p 8081 -h /app/www &
echo "🌐 静态网页服务已在内部 8081 端口挂载"

# ======================= WARP 注册 + 注入 sing-box =======================
NO_WARP="${NO_WARP:-false}"

if [ "$NO_WARP" != "true" ]; then
  echo "🛡️ 正在配置 WARP 出站..."

  cp /app/sb-config.json /app/sb-config.json.bak 2>/dev/null
  WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"
  WARP_ADDRESS="${WARP_ADDRESS:-}"
  WARP_RESERVED_JSON="${WARP_RESERVED_JSON:-}"

  if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_ADDRESS" ]; then
    echo "⬇️ 下载 wgcf 并注册 WARP..."
    ARCH="amd64"
    [ "$(uname -m)" = "aarch64" ] && ARCH="arm64"

    WGCF_PATH="/app/wgcf"
    if [ ! -f "$WGCF_PATH" ]; then
      curl -sL -o /tmp/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${ARCH}" && \
      mv /tmp/wgcf "$WGCF_PATH" && chmod +x "$WGCF_PATH"
    fi

    rm -f /app/wgcf-account.toml /app/wgcf-profile.conf
    echo Yes | timeout 30 "$WGCF_PATH" register 2>/dev/null || echo "⚠️ wgcf register 超时"
    timeout 30 "$WGCF_PATH" generate 2>/dev/null || echo "⚠️ wgcf generate 超时"

    if [ -f /app/wgcf-profile.conf ]; then
      WARP_PRIVATE_KEY=$(grep '^PrivateKey' /app/wgcf-profile.conf | cut -d'=' -f2- | tr -d ' ')
      WARP_ADDRESS=$(grep '^Address' /app/wgcf-profile.conf | head -1 | cut -d'=' -f2- | tr -d ' ' | cut -d',' -f1)
    fi

    if [ -z "$WARP_RESERVED_JSON" ] && [ -f /app/wgcf-account.toml ]; then
      WARP_RESERVED_JSON=$(grep -oP 'reserved\s*=\s*\K\[.*?\]' /app/wgcf-account.toml 2>/dev/null)
    fi
  fi

  if [ -n "$WARP_PRIVATE_KEY" ] && [ -n "$WARP_ADDRESS" ]; then
    WARP_ADDRESS_IP=$(echo "$WARP_ADDRESS" | cut -d'/' -f1)
    [ -z "$WARP_RESERVED_JSON" ] && WARP_RESERVED_JSON="[0,0,0]"

    jq --arg key "$WARP_PRIVATE_KEY" --arg addr "$WARP_ADDRESS_IP" --argjson reserved "$WARP_RESERVED_JSON" '
      .outbounds += [{
        "type": "wireguard",
        "tag": "warp-wg",
        "server": "engage.cloudflareclient.com",
        "server_port": 2408,
        "local_address": [$addr + "/32"],
        "private_key": $key,
        "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "reserved": $reserved,
        "mtu": 1280
      }]
      | .route.rules += [{
        "inbound": ["vless-in"],
        "outbound": "warp-wg"
      }]
    ' /app/sb-config.json > /tmp/sb-config.json

    if jq empty /tmp/sb-config.json 2>/dev/null; then
      mv /tmp/sb-config.json /app/sb-config.json
      echo "✅ WARP WireGuard 已注入 sing-box 配置"
    else
      cp /app/sb-config.json.bak /app/sb-config.json
      echo "⚠️ WARP 注入失败，已回滚"
    fi
  else
    echo "⚠️ WARP 注册失败，跳过"
  fi
fi

/usr/bin/sing-box run -c /app/sb-config.json &
echo "🚀 sing-box 核心已在本地 8080 端口拉起"

sync

# ======================= 哪吒探针 =======================
NEZHA_SERVER="${NEZHA_SERVER:-}"
NEZHA_KEY="${NEZHA_KEY:-}"
NEZHA_TLS="${NEZHA_TLS:-true}"

if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
  echo "📡 正在启动哪吒探针..."

  ARCH="amd64"
  [ "$(uname -m)" = "aarch64" ] && ARCH="arm64"

  NEZHA_BIN="/app/nezha-agent"
  if [ ! -f "$NEZHA_BIN" ]; then
    echo "⬇️ 下载 nezha-agent (${ARCH})..."
    curl -sL -o /tmp/nezha.zip "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip"
    unzip -o /tmp/nezha.zip -d /app/ && chmod +x "$NEZHA_BIN"
    rm -f /tmp/nezha.zip
  fi

  cat > /app/nezha-config.yml <<EOF
client_secret: ${NEZHA_KEY}
server: ${NEZHA_SERVER}
tls: ${NEZHA_TLS}
debug: false
disable_auto_update: true
disable_command_execute: true
report_delay: 3
EOF

  "$NEZHA_BIN" -c /app/nezha-config.yml &
  echo "✅ 哪吒探针已启动"
fi

# ======================= Cloudflare Tunnel =======================
echo "🚇 正在解析云端隧道环境变量..."

if [ -n "$TUNNEL_TOKEN" ]; then
  echo "👉 模式 [A] 激活：检测到 TUNNEL_TOKEN，正在建立官方固定隧道..."
  /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$TUNNEL_TOKEN" &

elif [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    echo "👉 模式 [B-1] 激活：检测到 JSON 证书凭证，正在本地流式重组隧道..."
    echo "$ARGO_AUTH" > /app/tunnel.json

    TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -oE '"TunnelID":"[^"]+"' | cut -d'"' -f4)
    cat <<EOF > /app/tunnel.yml
tunnel: $TUNNEL_ID
credentials-file: /app/tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF
    /usr/local/bin/cloudflared tunnel --config /app/tunnel.yml run &
  else
    echo "👉 模式 [B-2] 激活：检测到 Token 形式的 ARGO_AUTH，正在向域名 $ARGO_DOMAIN 绑定大桥..."
    /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" &
  fi

else
  echo "👉 模式 [C] 激活：未检测到任何固定密钥，正在拉起 TryCloudflare 临时随机隧道..."
  /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:8080 &
fi

# ======================= 保活循环 =======================
while true; do
  sleep 15

  if ! netstat -tln | grep -q :8080; then
    echo "🚨 sing-box 端口 8080 未监听，尝试重启..."
    /usr/bin/sing-box run -c /app/sb-config.json &
  fi

  if ! pidof cloudflared > /dev/null; then
    echo "🚨 cloudflared 进程已退出"
    if [ -n "$TUNNEL_TOKEN" ]; then
      /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$TUNNEL_TOKEN" &
    fi
  fi
done
