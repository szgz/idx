#!/bin/bash

set -e

# ====== Reality 参数配置 ======
UUID="8db9caf1-82d1-4d68-a1d0-6c2ad861e530"
SHORT_ID="d99b"
DEST="www.microsoft.com"
FINGERPRINT="chrome"
PRIVATE_KEY="2OqnjrVB7X-ZoWQyREceSl-gFjZxRGQvWkgdJQzHB20"
PORT="32156"
XRAY_DIR="/usr/local/xray"
XRAY_BIN="$XRAY_DIR/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
LISTEN_ADDR="127.0.0.1"  # Cloudflare Tunnel 模式仅监听本地

# ====== Cloudflare Tunnel Token（你提供的）======
CF_TUNNEL_TOKEN='eyJhIjoiYTlkMmY1NzJiYTRiMzNlYTY4OWQ4Y2Q2MzMxNWZiN2MiLCJ0IjoiNzU2YTBkMzctNjNiZC00ODAxLTkyNDItZjJkOWU5Y2IwYjQyIiwicyI6Ik4ySmxObVl4WkdRdFlqRXpNeTAwWmpBekxUazJPRFV0WkdKbFpURmlNbU01TW1ReCJ9'

# ====== 安装依赖 ======
echo "📦 安装依赖..."
sudo apt update -y
sudo apt install -y unzip curl wget

# ====== 安装 Xray ======
echo "⬇️ 下载并安装 Xray..."
sudo mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"
sudo wget -qO xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
sudo unzip -o xray.zip
sudo chmod +x xray

echo "🔐 生成 Reality 公钥..."
PUB_KEY=$(sudo "$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | grep "Public key" | awk '{print $3}')
if [[ -z "$PUB_KEY" ]]; then
  echo "❌ 公钥生成失败"
  exit 1
fi

# ====== 写入 Xray 配置 ======
echo "⚙️ 写入 Xray 配置..."
sudo tee "$XRAY_CONFIG" > /dev/null <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST:443",
          "xver": 0,
          "serverNames": ["$DEST"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"],
          "fingerprint": "$FINGERPRINT"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }, { "protocol": "blackhole", "tag": "blocked" }]
}
EOF

# ====== 配置 Xray systemd 服务 ======
echo "🔧 配置 systemd 服务..."
sudo tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray Reality Service
After=network.target

[Service]
ExecStart=$XRAY_BIN -config $XRAY_CONFIG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl restart xray

# ====== 安装 Cloudflared ======
echo "☁️ 安装 Cloudflared..."
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update -y
sudo apt install -y cloudflared

# ====== 注册并安装 tunnel ======
echo "🔗 注册并绑定 tunnel..."
sudo cloudflared service install "$CF_TUNNEL_TOKEN"

# ====== 自动提取 Tunnel ID 和凭证路径 ======
TUNNEL_ID=$(basename /etc/cloudflared/*.json | cut -d. -f1)
CF_CRED_FILE="/etc/cloudflared/$TUNNEL_ID.json"

# ====== 写入 cloudflared 配置并建立映射 ======
echo "⚙️ 写入 Cloudflared 配置..."
sudo mkdir -p /etc/cloudflared
sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_CRED_FILE

ingress:
  - hostname: idx.frankdevcn.dpdns.org
    service: tcp://127.0.0.1:$PORT
  - service: http_status:404
EOF

# ====== 重启 cloudflared 隧道 ======
sudo systemctl restart cloudflared

# ====== 展示部署信息 ======
echo ""
echo "✅ 所有部署已完成！"
echo "🌐 Cloudflare 隧道地址: idx.frankdevcn.dpdns.org"
echo "🧩 Reality 本地监听: $LISTEN_ADDR:$PORT"
echo "🆔 UUID: $UUID"
echo "🔑 Short ID: $SHORT_ID"
echo "🔐 Public Key: $PUB_KEY"
