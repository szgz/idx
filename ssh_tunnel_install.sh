#!/bin/bash

# --- 配置 ---
# 修改为你自己的 Cloudflare 域名
CLOUDFLARE_DOMAIN="your-domain.com"
# 隧道名称 (可以自定义)
TUNNEL_NAME="ssh-tunnel"
# SSH 服务通常运行在 22 端口
SSH_PORT="22"
# --- 结束配置 ---

# 确保以 root 身份运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本。" >&2
  exit 1
fi

# 函数：打印信息
log_info() {
  echo "[INFO] $1"
}

# 函数：打印错误并退出
log_error() {
  echo "[ERROR] $1" >&2
  exit 1
}

# 函数：安装软件包
install_package() {
  local package_name="$1"
  if command -v apt-get &>/dev/null; then
    apt-get update -y >/dev/null
    apt-get install -y "$package_name" >/dev/null || log_error "使用 apt-get 安装 $package_name 失败。"
  elif command -v yum &>/dev/null; then
    yum install -y "$package_name" >/dev/null || log_error "使用 yum 安装 $package_name 失败。"
  elif command -v dnf &>/dev/null; then
    dnf install -y "$package_name" >/dev/null || log_error "使用 dnf 安装 $package_name 失败。"
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm "$package_name" >/dev/null || log_error "使用 pacman 安装 $package_name 失败。"
  else
    log_error "不支持的包管理器。请手动安装 $package_name。"
  fi
  log_info "$package_name 已安装。"
}

# 1. 检测并安装 curl 和 gpg (如果需要)
if ! command -v curl &>/dev/null; then
  log_info "正在安装 curl..."
  install_package "curl"
fi
if ! command -v gpg &>/dev/null; then
  log_info "正在安装 gnupg..."
  install_package "gnupg"
fi

# 2. 下载并安装 cloudflared
log_info "正在下载并安装 cloudflared..."
ARCH=$(uname -m)
CLOUDFLARED_VERSION="latest" # 或者指定一个版本，例如 "2024.4.1"

if [ "$ARCH" = "x86_64" ]; then
  ARCH_SUFFIX="amd64"
elif [ "$ARCH" = "aarch64" ]; then
  ARCH_SUFFIX="arm64"
elif [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv6l" ]; then
  ARCH_SUFFIX="arm"
else
  log_error "不支持的系统架构: $ARCH"
fi

# 尝试确定 Linux 发行版以使用包管理器安装（如果可用）
# Debian/Ubuntu
if command -v apt-get &>/dev/null; then
    apt-get update -y >/dev/null
    apt-get install -y curl gnupg >/dev/null
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -y >/dev/null
    apt-get install -y cloudflared >/dev/null || log_error "使用 apt-get 安装 cloudflared 失败。"
# RHEL/CentOS/Fedora
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    rpm --import https://pkg.cloudflare.com/cloudflare-main.gpg
    if command -v dnf &>/dev/null; then
        dnf install -y 'https://pkg.cloudflare.com/cloudflared-latest.x86_64.rpm' >/dev/null || dnf install -y "https://pkg.cloudflare.com/cloudflared-${CLOUDFLARED_VERSION}-1.${ARCH_SUFFIX}.rpm" >/dev/null || log_error "使用 dnf 安装 cloudflared 失败。"
    elif command -v yum &>/dev/null; then
        yum install -y 'https://pkg.cloudflare.com/cloudflared-latest.x86_64.rpm' >/dev/null || yum install -y "https://pkg.cloudflare.com/cloudflared-${CLOUDFLARED_VERSION}-1.${ARCH_SUFFIX}.rpm" >/dev/null || log_error "使用 yum 安装 cloudflared 失败。"
    fi
# Arch Linux
elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm cloudflared >/dev/null || log_error "使用 pacman 安装 cloudflared 失败。"
# Fallback to binary download if package manager fails or is not common
else
    log_info "尝试直接下载 cloudflared 二进制文件..."
    CLOUDFLARED_PKG_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH_SUFFIX}"
    if [ "$CLOUDFLARED_VERSION" = "latest" ]; then
        CLOUDFLARED_PKG_URL=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "browser_download_url.*cloudflared-linux-${ARCH_SUFFIX}"\" | cut -d '"' -f 4)
        if [ -z "$CLOUDFLARED_PKG_URL" ]; then
            log_error "无法获取最新的 cloudflared-linux-${ARCH_SUFFIX} 下载链接。"
        fi
    fi
    curl -L --output /usr/local/bin/cloudflared "$CLOUDFLARED_PKG_URL" || log_error "下载 cloudflared 失败。"
    chmod +x /usr/local/bin/cloudflared
fi

if ! command -v cloudflared &>/dev/null; then
    log_error "cloudflared 安装失败或未在 PATH 中。"
fi
log_info "cloudflared 已安装。"
cloudflared --version

# 3. 登录 Cloudflare (这一步通常需要人工交互，脚本会尝试执行，但您可能需要手动完成)
# 注意: 为了完全自动化，您应该预先在机器上完成认证，
# 并确保 ~/.cloudflared/cert.pem (用户运行) 或 /etc/cloudflared/cert.pem (服务运行) 存在。
log_info "尝试登录 Cloudflare。如果浏览器打开，请授权。"
log_info "如果此步骤卡住或失败，请手动运行 'cloudflared login'，然后重新运行此脚本或手动完成后续步骤。"
# 检查是否已经登录
CERT_PATH_USER="$HOME/.cloudflared/cert.pem" # 通常用户执行 login 后的路径
CERT_PATH_SERVICE="/etc/cloudflared/cert.pem" # 服务通常寻找的路径

NEEDS_LOGIN=true
if [ -f "$CERT_PATH_SERVICE" ]; then
    log_info "在 $CERT_PATH_SERVICE 找到 Cloudflare 证书。"
    NEEDS_LOGIN=false
elif [ -f "$CERT_PATH_USER" ]; then
    log_info "在 $CERT_PATH_USER 找到 Cloudflare 证书。将尝试复制到服务路径。"
    mkdir -p /etc/cloudflared
    cp "$CERT_PATH_USER" "$CERT_PATH_SERVICE"
    chown cloudflared:cloudflared "$CERT_PATH_SERVICE" 2>/dev/null || chown nobody:nogroup "$CERT_PATH_SERVICE" 2>/dev/null # 尝试设置权限
    chmod 600 "$CERT_PATH_SERVICE"
    NEEDS_LOGIN=false
fi

if [ "$NEEDS_LOGIN" = true ]; then
    cloudflared login
    # 登录后，证书通常在 ~/.cloudflared/cert.pem
    # 为了让服务能够使用，需要复制到 /etc/cloudflared/ (如果作为服务运行)
    # 脚本假设如果登录成功，用户会处理证书位置或服务能找到它。
    # 理想情况下，对于无提示脚本，证书应该已经存在于 /etc/cloudflared/cert.pem
    if [ -f "$CERT_PATH_USER" ] && [ ! -f "$CERT_PATH_SERVICE" ]; then
        log_info "登录后，将证书从用户目录复制到服务目录..."
        mkdir -p /etc/cloudflared
        cp "$CERT_PATH_USER" "$CERT_PATH_SERVICE"
        # 尝试为 cloudflared 服务设置用户和组
        if id cloudflared >/dev/null 2>&1; then
            chown cloudflared:cloudflared "$CERT_PATH_SERVICE"
        else
             # 如果 cloudflared 用户不存在 (例如，二进制安装)，使用 nobody 或 root
            chown root:root "$CERT_PATH_SERVICE"
        fi
        chmod 600 "$CERT_PATH_SERVICE"
        log_info "证书已复制到 $CERT_PATH_SERVICE。"
    elif [ ! -f "$CERT_PATH_SERVICE" ] && [ ! -f "$CERT_PATH_USER" ]; then
        log_info "警告：Cloudflare 登录后未在预期路径找到证书。隧道服务可能无法启动。请确保 $CERT_PATH_SERVICE 存在。"
    fi
else
    log_info "Cloudflare 已登录或证书已存在。"
fi

# 4. 创建隧道
log_info "正在创建隧道 '$TUNNEL_NAME'..."
# 检查隧道是否已存在
TUNNEL_ID=$(cloudflared tunnel list -o json | grep -E "\"name\":\"${TUNNEL_NAME}\"" -B1 | grep "\"id\":" | awk -F'"' '{print $4}' | head -n 1)

if [ -z "$TUNNEL_ID" ]; then
  TUNNEL_CREATE_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
  TUNNEL_ID=$(echo "$TUNNEL_CREATE_OUTPUT" | grep -oP 'ID: \K[0-9a-fA-F-]+')
  if [ -z "$TUNNEL_ID" ]; then
    log_error "创建隧道 '$TUNNEL_NAME' 失败。输出: $TUNNEL_CREATE_OUTPUT"
  fi
  log_info "隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 已创建。"
else
  log_info "隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 已存在。"
fi

# 5. 为隧道创建 DNS CNAME 记录
# CNAME 记录格式: ssh.<your-domain.com> -> <TUNNEL_ID>.cfargotunnel.com
SSH_HOSTNAME="ssh.${CLOUDFLARE_DOMAIN}"
log_info "正在为隧道 '$TUNNEL_NAME' 创建 DNS CNAME 记录 '$SSH_HOSTNAME'..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$SSH_HOSTNAME" || cloudflared tunnel route dns "$TUNNEL_ID" "$SSH_HOSTNAME"
# 检查 CNAME 是否成功 (cloudflared route dns 的退出码可能不总是可靠)
# 实际验证可以通过 Cloudflare Dashboard 或 nslookup/dig 完成
# 为了脚本简单，这里假设成功或用户会检查
log_info "尝试为 '$SSH_HOSTNAME' 创建 CNAME 记录。请在 Cloudflare Dashboard 中验证。"

# 6. 创建 Cloudflare Tunnel 配置文件
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CRED_FILE="$CONFIG_DIR/${TUNNEL_ID}.json" # cloudflared tunnel create 命令应该会生成这个

mkdir -p "$CONFIG_DIR"

# 如果 cloudflared tunnel create 命令已经创建了 credentials 文件，则 config.yml 中只需要 tunnel ID
# 新版本的 cloudflared (>=2022.3.0) tunnel create 会生成 <TUNNEL_ID>.json，并且 config.yml 只需要 tunnel ID
# 老版本可能需要 tunnel token 或 credentials-file 路径在 config.yml 中
if [ -f "$CRED_FILE" ]; then
  log_info "找到隧道凭证文件: $CRED_FILE"
  cat << EOF > "$CONFIG_FILE"
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $SSH_HOSTNAME
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404 # 默认的 ingress 规则
EOF
else
  # 尝试从 cloudflared tunnel token 获取 token (如果 tunnel create 输出了 token)
  # 或者依赖于 cert.pem (对于 named tunnels)
  # 对于 named tunnel 并且 cert.pem 存在，通常不需要显式指定 credentials-file 或 token
  log_info "未找到明确的隧道凭证文件 $CRED_FILE。将依赖 cert.pem 和隧道名称。"
  cat << EOF > "$CONFIG_FILE"
tunnel: $TUNNEL_NAME # 或者使用 TUNNEL_ID
# 如果不使用 <TUNNEL_ID>.json，则依赖于 ~/.cloudflared/cert.pem 或 /etc/cloudflared/cert.pem
# 以及 cloudflared 会自动查找与 TUNNEL_NAME 关联的隧道 ID

ingress:
  - hostname: $SSH_HOSTNAME
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404 # 默认的 ingress 规则
EOF
  # 如果指定了隧道 ID 且 cert.pem 存在，可以简化为：
  # cat << EOF > "$CONFIG_FILE"
  # tunnel: $TUNNEL_ID
  # ingress:
  #   - hostname: $SSH_HOSTNAME
  #     service: ssh://localhost:$SSH_PORT
  #   - service: http_status:404
  # EOF
fi

log_info "Cloudflare Tunnel 配置文件已创建: $CONFIG_FILE"
cat "$CONFIG_FILE"

# 7. 安装并启动 cloudflared 服务
log_info "正在安装并启动 cloudflared 服务..."
cloudflared service install >/dev/null 2>&1 # 某些情况下可能会输出 token，重定向掉
# 上面的命令会尝试使用当前用户的 cloudflared token
# 如果之前是以 root 登录的 cloudflared，证书在 /root/.cloudflared/cert.pem
# 服务通常以 cloudflared 用户运行，需要 /etc/cloudflared/cert.pem
# 确保 /etc/cloudflared/cert.pem 存在且可被 cloudflared 服务用户读取
if [ ! -f "/etc/cloudflared/cert.pem" ]; then
    if [ -f "/root/.cloudflared/cert.pem" ]; then
        log_info "将 root 的 cert.pem 复制到 /etc/cloudflared/cert.pem"
        mkdir -p /etc/cloudflared
        cp /root/.cloudflared/cert.pem /etc/cloudflared/cert.pem
        # 尝试为 cloudflared 服务设置用户和组
        if id cloudflared >/dev/null 2>&1; then
            chown cloudflared:cloudflared /etc/cloudflared/cert.pem
        else
            chown root:root /etc/cloudflared/cert.pem
        fi
        chmod 600 /etc/cloudflared/cert.pem
    else
        log_info "警告: 未在 /etc/cloudflared/cert.pem 或 /root/.cloudflared/cert.pem 找到证书。服务可能无法正确认证。"
    fi
fi

# 确保 cloudflared 服务用户可以访问配置文件
if id cloudflared >/dev/null 2>&1; then
    chown -R cloudflared:cloudflared "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    chmod 600 "$CONFIG_FILE"
    if [ -f "$CRED_FILE" ]; then
        chmod 600 "$CRED_FILE"
    fi
    if [ -f "/etc/cloudflared/cert.pem" ]; then
        chmod 600 "/etc/cloudflared/cert.pem"
    fi
fi


if systemctl list-units --type=service --all | grep -Fq 'cloudflared.service'; then
    systemctl enable cloudflared >/dev/null
    systemctl restart cloudflared
    # 等待几秒钟让服务启动
    sleep 5
    if systemctl is-active --quiet cloudflared; then
        log_info "cloudflared 服务已启动并激活。"
    else
        log_error "cloudflared 服务启动失败。请检查日志: journalctl -u cloudflared"
    fi
else
    log_error "cloudflared 服务单元文件未找到。服务安装可能失败。"
fi

log_info "部署完成！"
log_info "您现在应该可以通过 ssh <your-username>@$SSH_HOSTNAME 访问您的 SSH 服务。"
log_info "确保您的 Cloudflare 域名 '$CLOUDFLARE_DOMAIN' 配置正确，并且 DNS 记录已传播。"
log_info "您可能需要在 Cloudflare Access 中配置策略来保护此隧道。"

exit 0
