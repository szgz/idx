#!/bin/bash

set -e

XRAY_DIR="/usr/local/xray"
XRAY_BIN="$XRAY_DIR/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
LISTEN_MODE="$1"  # 参数: local 或 public

# 自动判断监听地址
if [[ "$LISTEN_MODE" == "public" ]]; then
  LISTEN_ADDR="0.0.0.0"
else
  LISTEN_ADDR="127.0.0.1"
fi

# Reality 基本参数
UUID="8db9caf1-82d1-4d68-a1d0-6c2ad861e530"
SHORT_ID="d99b"
DEST="www.microsoft.com"
FINGERPRINT="chrome"
PRIVATE_KEY="2OqnjrVB7X-ZoWQyREceSl-gFjZxRGQvWkgdJQzHB20"
PORT="32156"

# 安装依赖
sudo apt update -y
sudo apt install -y unzip curl wget

# 下载并解压 Xray
sudo mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"
sudo wget -qO xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
sudo unzip -o xray.zip
sudo chmod +x xray

# 生成公钥
PUB_KEY=$(sudo "$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | grep "Public key" | awk '{print $3}')
if [[ -z "$PUB_KEY" ]]; then
  echo "❌ 公钥生成失败"
  exit 1
fi

echo "🔑 公钥: $PUB_KEY"

# 写入配置文件
sudo tee "$XRAY_CONFIG" > /dev/null <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
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
  "outbounds": [
    {
      "protocol": "freedom"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ]
}
EOF

# 写入 systemd 服务
sudo tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=$XRAY_BIN -config $XRAY_CONFIG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl restart xray

echo "✅ Xray Reality 启动成功，监听 $LISTEN_ADDR:$PORT"
echo "👉 UUID: $UUID"
echo "👉 Short ID: $SHORT_ID"
echo "👉 Public Key: $PUB_KEY"
