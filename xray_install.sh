#!/bin/bash

set -e

XRAY_DIR="/usr/local/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
LISTEN_MODE="$1"  # 参数可为: local 或 public

# 自动选择监听地址
if [[ "$LISTEN_MODE" == "public" ]]; then
    LISTEN_ADDR="0.0.0.0"
else
    LISTEN_ADDR="127.0.0.1"
fi

UUID="8db9caf1-82d1-4d68-a1d0-6c2ad861e530"
SHORT_ID="d99b"
DEST="www.microsoft.com"
FINGERPRINT="chrome"
PRIVATE_KEY="2OqnjrVB7X-ZoWQyREceSl-gFjZxRGQvWkgdJQzHB20"
PORT="32156"

# 生成对应公钥
PUB_KEY=$(curl -Ls https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip | busybox unzip -p - xray | ./xray x25519 -i "$PRIVATE_KEY" | grep "Public key" | awk '{print $3}')
if [[ -z "$PUB_KEY" ]]; then
    echo "❌ 公钥生成失败，请手动执行：xray x25519 -i $PRIVATE_KEY"
    exit 1
fi

echo "🔑 公钥: $PUB_KEY"

# 安装 xray
mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"
wget -qO xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o xray.zip
chmod +x xray

# 写入配置文件
cat > "$XRAY_CONFIG" <<EOF
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

# 创建 systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=$XRAY_DIR/xray -config $XRAY_CONFIG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

echo "✅ Xray Reality 已安装并监听 $LISTEN_ADDR:$PORT"
echo "👉 UUID: $UUID"
echo "👉 Short ID: $SHORT_ID"
echo "👉 Public Key: $PUB_KEY"
