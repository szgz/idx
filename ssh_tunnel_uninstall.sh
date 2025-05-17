#!/bin/bash

# --- 配置 ---
# 与部署脚本中的配置保持一致
CLOUDFLARE_DOMAIN="your-domain.com" # 确保这个与部署时使用的域名一致
TUNNEL_NAME="ssh-tunnel"
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

# 函数：打印错误（但不一定退出，以便尝试清理更多内容）
log_warn() {
  echo "[WARN] $1" >&2
}

log_info "开始卸载 Cloudflare Tunnel for SSH..."

# 1. 停止并卸载 cloudflared 服务
log_info "正在停止并卸载 cloudflared 服务..."
if systemctl list-units --type=service --all | grep -Fq 'cloudflared.service'; then
  systemctl stop cloudflared >/dev/null 2>&1
  systemctl disable cloudflared >/dev/null 2>&1
  # cloudflared service uninstall 可能会尝试与 API 交互，如果失败则忽略
  cloudflared service uninstall >/dev/null 2>&1
  rm -f /etc/systemd/system/cloudflared.service # 确保 systemd 文件被移除
  systemctl daemon-reload >/dev/null 2>&1
  log_info "cloudflared 服务已停止并卸载。"
else
  log_warn "未找到 cloudflared 服务或已被卸载。"
fi

# 2. 删除 DNS CNAME 记录 和 隧道
# 尝试登录以确保有权限操作 (如果 cert.pem 仍然有效)
# CERT_PATH_SERVICE="/etc/cloudflared/cert.pem"
# if [ ! -f "$CERT_PATH_SERVICE" ] && [ -f "$HOME/.cloudflared/cert.pem" ]; then
#   # 如果服务证书不在，但用户证书在，尝试使用它
#   export CLOUDFLARED_CERT="$HOME/.cloudflared/cert.pem"
# elif [ -f "$CERT_PATH_SERVICE" ]; then
#   export CLOUDFLARED_CERT="$CERT_PATH_SERVICE"
# fi
# 新版本的 cloudflared 倾向于使用 login 信息，而不是直接依赖 cert 文件进行 CLI 操作

# 检查 cloudflared 是否安装
if command -v cloudflared &>/dev/null; then
    log_info "Cloudflared 已安装，尝试删除隧道和 DNS 记录。"

    SSH_HOSTNAME="ssh.${CLOUDFLARE_DOMAIN}"
    # 获取隧道 ID，因为删除隧道需要 ID
    TUNNEL_ID=$(cloudflared tunnel list -o json | grep -E "\"name\":\"${TUNNEL_NAME}\"" -B1 | grep "\"id\":" | awk -F'"' '{print $4}' | head -n 1)

    if [ -n "$TUNNEL_ID" ]; then
        log_info "找到隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID)。"
        log_info "正在删除隧道的 DNS 路由 '$SSH_HOSTNAME'..."
        # 删除 CNAME 记录 (需要隧道名称或ID)
        # cloudflared tunnel route dns <TUNNEL_NAME_OR_ID> <HOSTNAME> -d  <- 老版本
        # 新版本中，删除隧道时会自动清理关联的 DNS 记录
        # cloudflared tunnel route delete <TUNNEL_NAME_OR_ID> <HOSTNAME> <- 这个命令不存在
        # 通常是 cloudflared tunnel delete <TUNNEL_NAME_OR_ID> 会处理，或者手动在 Dashboard 删除
        # 为了保险，可以尝试用 cloudflared tunnel route dns 命令删除，但它的主要作用是创建。
        # Cloudflare Dashboard 是最可靠的删除 CNAME 的地方如果脚本失败。
        # 我们将主要依赖 `tunnel delete` 来清理 DNS。

        log_info "正在删除隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID)..."
        # 删除隧道 (需要隧道名称或ID)
        cloudflared tunnel delete -f "$TUNNEL_NAME" >/dev/null 2>&1 || cloudflared tunnel delete -f "$TUNNEL_ID" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_info "隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 已删除。"
        else
            log_warn "删除隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 失败。可能需要手动在 Cloudflare Dashboard 删除。确保您已通过 'cloudflared login' 登录。"
        fi
    else
        log_warn "未找到名为 '$TUNNEL_NAME' 的隧道来删除。"
    fi

    # 如果只想删除 CNAME 而不删除隧道本身（不推荐，因为隧道会 orphaned）
    # log_info "正在尝试删除 DNS CNAME 记录 '$SSH_HOSTNAME'..."
    # cloudflared tunnel route dns "$TUNNEL_NAME" "$SSH_HOSTNAME" --delete (假设有此选项，实际没有)
    # 通常 CNAME 需要在 Cloudflare Dashboard 手动删除，或者删除隧道时一并删除。
    # 对于脚本，主要关注点是删除隧道本身。

else
    log_warn "cloudflared 命令未找到。跳过隧道和 DNS 记录的删除。请手动在 Cloudflare Dashboard 中检查并清理。"
fi


# 3. 删除 Cloudflare Tunnel 配置文件和凭证
log_info "正在删除 Cloudflare Tunnel 配置文件..."
CONFIG_DIR="/etc/cloudflared"
rm -rf "$CONFIG_DIR"
log_info "目录 $CONFIG_DIR 已删除。"

# 4. 删除 cloudflared 登录凭证 (cert.pem)
# 用户目录的凭证
USER_CLOUDFLARED_DIR="$HOME/.cloudflared" # 脚本以 root 运行时, $HOME 是 /root
if [ -d "$USER_CLOUDFLARED_DIR" ]; then
  log_info "正在删除用户 Cloudflare 凭证目录: $USER_CLOUDFLARED_DIR"
  rm -rf "$USER_CLOUDFLARED_DIR"
fi
# 检查可能的其他用户家目录下的 .cloudflared (如果知道哪个用户执行了 login)
# 例如，如果普通用户 sudo 执行脚本，login 证书可能在 /home/普通用户/.cloudflared/
# 为了通用性，只删除 root 的和 /etc/cloudflared/ (已在上面删除)

# 5. 卸载 cloudflared 软件包
log_info "正在卸载 cloudflared 软件包..."
if command -v apt-get &>/dev/null; then
  apt-get purge -y cloudflared >/dev/null || log_warn "使用 apt-get 卸载 cloudflared 失败。"
  apt-get autoremove -y >/dev/null
  rm -f /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y >/dev/null
elif command -v yum &>/dev/null; then
  yum remove -y cloudflared >/dev/null || log_warn "使用 yum 卸载 cloudflared 失败。"
  rm -f /etc/yum.repos.d/cloudflared.repo # 假设包管理器创建了这个
elif command -v dnf &>/dev/null; then
  dnf remove -y cloudflared >/dev/null || log_warn "使用 dnf 卸载 cloudflared 失败。"
  rm -f /etc/yum.repos.d/cloudflared.repo # 假设包管理器创建了这个
elif command -v pacman &>/dev/null; then
  pacman -Rns --noconfirm cloudflared >/dev/null || log_warn "使用 pacman 卸载 cloudflared 失败。"
else
  # 如果是手动二进制安装
  if [ -f "/usr/local/bin/cloudflared" ]; then
    rm -f "/usr/local/bin/cloudflared"
    log_info "/usr/local/bin/cloudflared 已删除。"
  else
    log_warn "未找到 cloudflared 二进制文件 /usr/local/bin/cloudflared 或通过包管理器安装。"
  fi
fi
log_info "cloudflared 软件包卸载尝试完成。"

log_info "卸载完成！"
log_info "请检查您的 Cloudflare Dashboard，确保隧道 '$TUNNEL_NAME' 和相关的 DNS 记录 (如 ssh.$CLOUDFLARE_DOMAIN) 已被彻底删除。"
log_info "可能需要手动删除 $HOME/.cloudflared (如果非 root 用户运行过 cloudflared login)。"

exit 0
