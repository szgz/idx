#!/bin/bash

# 检查是否以 root 身份运行，如果不是，则尝试使用 sudo 重新运行
if [ "$(id -u)" -ne 0 ]; then
  echo "[INFO] 此脚本需要 root 权限才能修改系统配置和管理服务。"
  echo "[INFO] 正在尝试使用 sudo 重新运行脚本..."
  exec sudo "$0" "$@"
  echo "[ERROR]无法使用 sudo 执行脚本。请确保 sudo 已安装，并且您有权限使用它，或者直接以 root 用户身份运行此脚本。" >&2
  exit 126
fi

# --- 从这里开始，脚本拥有 root 权限 ---

# --- 配置 ---
# 修改为你自己的 Cloudflare 域名 (如果使用 Token 且 DNS 已在 CF Dashboard 配置，此项仅用于信息展示)
CLOUDFLARE_DOMAIN="your-domain.com"
# 隧道名称 (如果使用 Token，此名称仅用于信息展示，实际隧道由 Token 决定)
TUNNEL_NAME="ssh-tunnel-via-script" # 如果使用 token，实际隧道名由 token 决定
# SSH 服务将要监听的 *额外* 端口 (Cloudflare Tunnel 将连接到这个端口)
# SSHD 将同时监听此端口和标准的 22 端口
ADDITIONAL_SSH_PORT="8022"
STANDARD_SSH_PORT="22"

# 【可选】如果您已经有一个通过 Cloudflare Dashboard 创建的隧道，并拥有其 TOKEN，请在此处填写。
# 如果留空，脚本将尝试通过 cloudflared login 和 tunnel create 创建新隧道。
# TOKEN 通常以 "ey..." 开头。
# 示例: PRECONFIGURED_TUNNEL_TOKEN="eyJhIjoiNORTHERN_LIGHTS..."
PRECONFIGURED_TUNNEL_TOKEN="" # <--- 在此输入您的隧道 TOKEN (如果已有)

# 主机名 (如果使用 Token 且 DNS 已在 CF Dashboard 配置，此项仅用于信息展示)
# 如果不使用 Token，脚本会尝试创建 ssh.${CLOUDFLARE_DOMAIN}
SSH_HOSTNAME_INFO="ssh.${CLOUDFLARE_DOMAIN}" # 用于最终的提示信息
# --- 结束配置 ---

# 函数 (log_info, log_warn, log_error, install_package 与之前版本相同)
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') (root) - $1"; }
log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') (root) - $1" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') (root) - $1" >&2; exit 1; }
install_package() {
  local package_name="$1"
  log_info "尝试安装软件包: $package_name"
  if command -v apt-get &>/dev/null; then
    apt-get update -yq >/dev/null; apt-get install -yq "$package_name" >/dev/null || log_error "apt-get 安装 $package_name 失败。"
  elif command -v yum &>/dev/null; then
    yum install -y "$package_name" >/dev/null || log_error "yum 安装 $package_name 失败。"
  elif command -v dnf &>/dev/null; then
    dnf install -y "$package_name" >/dev/null || log_error "dnf 安装 $package_name 失败。"
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm "$package_name" >/dev/null || log_error "pacman 安装 $package_name 失败。"
  else log_error "不支持的包管理器。请手动安装 $package_name。"; fi
  log_info "$package_name 已成功安装/确认已安装。"
}

# --- Cloudflared 安装 ---
install_cloudflared_binary() {
    if ! command -v cloudflared &>/dev/null; then
        log_info "cloudflared 未安装，开始安装..."
        if ! command -v curl &>/dev/null; then install_package "curl"; fi
        if ! command -v gpg &>/dev/null && command -v apt-get &>/dev/null; then install_package "gnupg"; fi
        ARCH=$(uname -m)
        # 优先使用包管理器安装 cloudflared
        if command -v apt-get &>/dev/null && command -v lsb_release &>/dev/null; then
            log_info "使用 apt 安装 cloudflared..."
            apt-get update -yq >/dev/null; apt-get install -yq curl gnupg lsb-release >/dev/null
            mkdir -p --mode=0755 /usr/share/keyrings
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
            apt-get update -yq >/dev/null; apt-get install -yq cloudflared >/dev/null || log_error "apt-get 安装 cloudflared 失败。"
        elif command -v dnf &>/dev/null; then
            log_info "使用 dnf 安装 cloudflared..."
            rpm --import https://pkg.cloudflare.com/cloudflare-main.gpg
            dnf install -y "https://pkg.cloudflare.com/cloudflared-latest.$( [ "$ARCH" = "x86_64" ] && echo "x86_64" || echo "$ARCH" ).rpm" >/dev/null || log_error "dnf 安装 cloudflared 失败。"
        elif command -v yum &>/dev/null; then
            log_info "使用 yum 安装 cloudflared..."
            rpm --import https://pkg.cloudflare.com/cloudflare-main.gpg
            yum install -y "https://pkg.cloudflare.com/cloudflared-latest.$( [ "$ARCH" = "x86_64" ] && echo "x86_64" || echo "$ARCH" ).rpm" >/dev/null || log_error "yum 安装 cloudflared 失败。"
        elif command -v pacman &>/dev/null; then
            log_info "使用 pacman 安装 cloudflared..."
            pacman -Syu --noconfirm cloudflared >/dev/null || log_error "pacman 安装 cloudflared 失败。"
        else
            log_info "未找到主流包管理器或 cloudflared 包安装失败，尝试直接下载 cloudflared 二进制文件..."
            local arch_suffix=""
            if [ "$ARCH" = "x86_64" ]; then arch_suffix="amd64";
            elif [ "$ARCH" = "aarch64" ]; then arch_suffix="arm64";
            elif [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv6l" ]; then arch_suffix="arm";
            else log_error "不支持的系统架构: $ARCH 用于直接下载。"; fi
            CLOUDFLARED_PKG_URL=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep "browser_download_url.*cloudflared-linux-${arch_suffix}"\" | cut -d '"' -f 4 | head -n 1)
            if [ -z "$CLOUDFLARED_PKG_URL" ]; then log_error "无法获取最新的 cloudflared-linux-${arch_suffix} 下载链接。"; fi
            curl -L --output /usr/local/bin/cloudflared "$CLOUDFLARED_PKG_URL" || log_error "下载 cloudflared 失败。"
            chmod +x /usr/local/bin/cloudflared
        fi
        if ! command -v cloudflared &>/dev/null; then log_error "cloudflared 安装失败或未在 PATH 中。"; fi
        log_info "cloudflared 已安装: $(cloudflared --version)"
    else
        log_info "cloudflared 已安装: $(cloudflared --version)"
    fi
}

# --- SSH 端口修改逻辑 (确保监听多个端口) ---
# (与之前脚本中的 configure_sshd_multi_port 函数相同)
configure_sshd_multi_port() {
    local port1="$1" local port2="$2" local sshd_config_file="/etc/ssh/sshd_config"
    log_info "开始配置 SSHD 以监听端口 $port1 和 $port2..."
    local backup_file="${sshd_config_file}.bak_$(date +%F_%T_multiport)"
    cp "$sshd_config_file" "$backup_file" || log_error "备份 SSH 配置文件失败。"
    # 确保 Port port1 存在且未被注释
    if grep -qE "^\s*#\s*Port\s+$port1" "$sshd_config_file"; then sed -i -E "s/^\s*#\s*(Port\s+$port1)/\1/" "$sshd_config_file"; log_info "已取消端口 $port1 的注释。";
    elif ! grep -qE "^\s*Port\s+$port1" "$sshd_config_file"; then echo -e "\nPort $port1" >> "$sshd_config_file"; log_info "已添加 Port $port1 到配置文件。";
    else log_info "端口 $port1 似乎已在配置文件中激活。"; fi
    # 确保 Port port2 存在且未被注释
    if [ "$port1" != "$port2" ]; then
        if grep -qE "^\s*#\s*Port\s+$port2" "$sshd_config_file"; then sed -i -E "s/^\s*#\s*(Port\s+$port2)/\1/" "$sshd_config_file"; log_info "已取消端口 $port2 的注释。";
        elif ! grep -qE "^\s*Port\s+$port2" "$sshd_config_file"; then echo -e "\nPort $port2" >> "$sshd_config_file"; log_info "已添加 Port $port2 到配置文件。";
        else log_info "端口 $port2 似乎已在配置文件中激活。"; fi
    fi
    # 验证
    local port1_active=false; local port2_active=false
    if grep -qE "^\s*Port\s+$port1" "$sshd_config_file"; then port1_active=true; fi
    if [ "$port1" = "$port2" ] || grep -qE "^\s*Port\s+$port2" "$sshd_config_file"; then port2_active=true; fi
    if ! ($port1_active && $port2_active) ; then log_error "修改 SSH 配置文件以监听多端口失败。手动检查 $sshd_config_file。恢复备份: $backup_file"; fi
    log_info "SSH 配置文件已更新为监听端口 $port1 和 $port2。"
    # SELinux
    for p_selinux in $port1 $port2; do
      if command -v semanage &>/dev/null && command -v sestatus &>/dev/null && sestatus | grep -q "SELinux status:\s*enabled"; then
        if ! semanage port -l | grep -qw "ssh_port_t" | grep -qw "$p_selinux"; then
          log_info "SELinux: 正在为端口 $p_selinux 添加 ssh_port_t 类型..."; semanage port -a -t ssh_port_t -p tcp "$p_selinux"
          if [ $? -eq 0 ]; then log_info "SELinux: 已将端口 $p_selinux 添加到 ssh_port_t 类型。"; else log_warn "SELinux: 添加端口 $p_selinux 到 ssh_port_t 类型失败。"; fi
        else log_info "SELinux: 端口 $p_selinux 已允许 ssh_port_t 类型。"; fi
      fi
    done
    # 防火墙
    log_info "正在配置防火墙以允许端口 $port1 和 $port2..."
    local firewall_reloaded=false
    for p_fw in $port1 $port2; do
        if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
            if ! ufw status verbose | grep -qw "$p_fw/tcp.*ALLOW IN"; then ufw allow "$p_fw/tcp" comment "Allow SSH on port $p_fw" >/dev/null; log_info "UFW: 已添加允许 TCP 端口 $p_fw 的规则。";
            else log_info "UFW: TCP 端口 $p_fw 的规则已存在。"; fi
        fi
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            DEFAULT_ZONE=$(firewall-cmd --get-default-zone)
            if ! firewall-cmd --permanent --zone="$DEFAULT_ZONE" --query-port="$p_fw/tcp" >/dev/null; then firewall-cmd --permanent --zone="$DEFAULT_ZONE" --add-port="$p_fw/tcp" >/dev/null; log_info "firewalld: 已为区域 $DEFAULT_ZONE 添加端口 $p_fw/tcp。"; firewall_reloaded=true;
            else log_info "firewalld: 端口 $p_fw/tcp 已在区域 $DEFAULT_ZONE 中允许。"; fi
        fi
        if ! command -v ufw &>/dev/null && ! (command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld) && command -v iptables &>/dev/null; then
             if ! iptables -C INPUT -p tcp --dport "$p_fw" -j ACCEPT 2>/dev/null; then iptables -A INPUT -p tcp --dport "$p_fw" -j ACCEPT; log_info "iptables: 已添加允许 TCP 端口 $p_fw 的规则 (可能非持久化)。"; fi
        fi
    done
    if $firewall_reloaded; then firewall-cmd --reload >/dev/null; log_info "firewalld: 规则已重载。"; fi
    # 重启 SSH 服务
    log_info "正在重启 SSH 服务 (sshd)..."
    if command -v systemctl &>/dev/null; then systemctl daemon-reload; systemctl restart sshd || systemctl restart ssh; sleep 2
      if ! (systemctl is-active --quiet sshd || systemctl is-active --quiet ssh); then log_error "SSH 服务重启失败。检查日志。恢复备份: $backup_file"; fi
    elif command -v service &>/dev/null; then service sshd restart || service ssh restart; else log_error "无法确定如何重启 SSH 服务。"; fi
    log_info "SSH 服务已成功重启，应监听端口 $port1 和 $port2。"
    log_info "SSHD 多端口配置完成。"
}


# --- 主执行流程 ---

# 步骤 1: 安装 cloudflared (如果尚未安装)
install_cloudflared_binary

# 步骤 2: 配置本地 SSHD 监听多端口 (Cloudflare Tunnel 将连接到 ADDITIONAL_SSH_PORT)
configure_sshd_multi_port "$STANDARD_SSH_PORT" "$ADDITIONAL_SSH_PORT"

# 步骤 3: 根据是否提供 Token 来配置和安装 Cloudflare Tunnel 服务
if [ -n "$PRECONFIGURED_TUNNEL_TOKEN" ]; then
    # --- 使用提供的 Token ---
    log_info "检测到 PRECONFIGURED_TUNNEL_TOKEN，将使用此 Token 安装服务。"
    log_info "请确保此 Token 对应的隧道在 Cloudflare Dashboard 中已正确配置，"
    log_info "包括其入口规则 (例如，将公共主机名指向源服务器的 localhost:$ADDITIONAL_SSH_PORT)。"

    # 清理旧的 Cloudflare Tunnel 配置文件 (如果存在)，因为 Token 方式不需要它来定义隧道本身。
    # 但如果用户想用 config.yml 来配置日志等级等非隧道定义的参数，可以保留。
    # 为简单起见，如果用 Token，我们假设 config.yml 主要用于 ingress 和 tunnel ID，这些由 Token 处理。
    CONFIG_DIR_TOKEN_MODE="/etc/cloudflared"
    if [ -f "$CONFIG_DIR_TOKEN_MODE/config.yml" ]; then
        log_info "检测到旧的 config.yml，由于使用 Token，将重命名它以避免冲突: $CONFIG_DIR_TOKEN_MODE/config.yml.bak_token_mode"
        mv "$CONFIG_DIR_TOKEN_MODE/config.yml" "$CONFIG_DIR_TOKEN_MODE/config.yml.bak_token_mode_$(date +%F_%T)"
    fi
    # 确保 /etc/cloudflared 目录存在，服务安装可能会在这里放东西
    mkdir -p "$CONFIG_DIR_TOKEN_MODE"

    log_info "正在使用 Token 安装 cloudflared 服务: $PRECONFIGURED_TUNNEL_TOKEN"
    cloudflared service install "$PRECONFIGURED_TUNNEL_TOKEN"
    if [ $? -ne 0 ]; then
        log_error "使用 Token 安装 cloudflared 服务失败。请检查 Token 是否有效以及 cloudflared 的输出。"
    fi
    log_info "Cloudflared 服务已使用 Token 配置安装。"

else
    # --- 不使用 Token，执行完整登录、隧道创建流程 ---
    log_info "未提供 PRECONFIGURED_TUNNEL_TOKEN，将执行完整的隧道创建和配置流程。"
    CERT_PATH_ROOT_CONFIG_DIR="/etc/cloudflared"
    CERT_PATH_ROOT_SERVICE="$CERT_PATH_ROOT_CONFIG_DIR/cert.pem"
    CERT_PATH_LOGIN_DEFAULT="/root/.cloudflared/cert.pem"
    mkdir -p "$CERT_PATH_ROOT_CONFIG_DIR"

    if [ ! -f "$CERT_PATH_ROOT_SERVICE" ]; then
        if [ -f "$CERT_PATH_LOGIN_DEFAULT" ]; then
            cp "$CERT_PATH_LOGIN_DEFAULT" "$CERT_PATH_ROOT_SERVICE"; chown root:root "$CERT_PATH_ROOT_SERVICE"; chmod 600 "$CERT_PATH_ROOT_SERVICE"
        else
            cloudflared login || log_error "cloudflared login 失败。"
            if [ -f "$CERT_PATH_LOGIN_DEFAULT" ]; then
                cp "$CERT_PATH_LOGIN_DEFAULT" "$CERT_PATH_ROOT_SERVICE"; chown root:root "$CERT_PATH_ROOT_SERVICE"; chmod 600 "$CERT_PATH_ROOT_SERVICE"
            elif [ ! -f "$CERT_PATH_ROOT_SERVICE" ]; then log_warn "登录后证书未找到。"; fi
        fi
    fi
    if [ ! -f "$CERT_PATH_ROOT_SERVICE" ]; then log_error "Cloudflare 认证证书 ($CERT_PATH_ROOT_SERVICE) 未找到。"; fi

    TUNNEL_ID=$(cloudflared tunnel list --config "$CERT_PATH_ROOT_CONFIG_DIR/initial_config.yaml" --cred-file "$CERT_PATH_ROOT_SERVICE" -o json | grep -E "\"name\":\"${TUNNEL_NAME}\"" -B1 | grep "\"id\":" | awk -F'"' '{print $4}' | head -n 1)
    if [ -z "$TUNNEL_ID" ]; then
      touch "$CERT_PATH_ROOT_CONFIG_DIR/config.yml" # Dummy for create context
      TUNNEL_CREATE_OUTPUT=$(cloudflared tunnel --config "$CERT_PATH_ROOT_CONFIG_DIR/config.yml" --cred-file "$CERT_PATH_ROOT_SERVICE" create "$TUNNEL_NAME" 2>&1)
      TUNNEL_ID=$(echo "$TUNNEL_CREATE_OUTPUT" | grep -oP 'ID: \K[0-9a-fA-F-]+')
      if [ -z "$TUNNEL_ID" ]; then log_error "创建隧道 '$TUNNEL_NAME' 失败: $TUNNEL_CREATE_OUTPUT"; fi
      log_info "隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 已创建。"
    else
      log_info "隧道 '$TUNNEL_NAME' (ID: $TUNNEL_ID) 已存在。"
    fi
    CRED_FILE_PATH="$CERT_PATH_ROOT_CONFIG_DIR/${TUNNEL_ID}.json"
    if [ ! -f "$CRED_FILE_PATH" ]; then log_warn "隧道凭证文件 $CRED_FILE_PATH 未找到。"; fi

    SSH_HOSTNAME_INFO="ssh.${CLOUDFLARE_DOMAIN}" # 确保 SSH_HOSTNAME_INFO 在此作用域也设置
    log_info "为隧道 '$TUNNEL_NAME' 创建 DNS CNAME 记录 '$SSH_HOSTNAME_INFO'..."
    cloudflared tunnel --config "$CERT_PATH_ROOT_CONFIG_DIR/config.yml" --cred-file "$CERT_PATH_ROOT_SERVICE" route dns "$TUNNEL_NAME" "$SSH_HOSTNAME_INFO"
    if [ $? -ne 0 ]; then log_warn "为 '$SSH_HOSTNAME_INFO' 创建 CNAME 记录可能失败。"; else log_info "CNAME 记录 '$SSH_HOSTNAME_INFO' 请求已发送。"; fi

    CONFIG_FILE_FINAL="$CERT_PATH_ROOT_CONFIG_DIR/config.yml"
    log_info "创建 cloudflared 最终配置文件 $CONFIG_FILE_FINAL..."
    cat << EOF > "$CONFIG_FILE_FINAL"
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE_PATH
logfile: /var/log/cloudflared.log
autoupdate-freq: 24h

ingress:
  - hostname: $SSH_HOSTNAME_INFO
    service: ssh://localhost:$ADDITIONAL_SSH_PORT
  - service: http_status:404
EOF
    log_info "Cloudflare Tunnel 配置文件已创建。内容:"; cat "$CONFIG_FILE_FINAL"

    if id cloudflared >/dev/null 2>&1; then chown -R cloudflared:cloudflared "$CERT_PATH_ROOT_CONFIG_DIR";
    else chown -R root:root "$CERT_PATH_ROOT_CONFIG_DIR"; fi
    chmod 700 "$CERT_PATH_ROOT_CONFIG_DIR"; chmod 600 "$CONFIG_FILE_FINAL"
    if [ -f "$CRED_FILE_PATH" ]; then chmod 600 "$CRED_FILE_PATH"; fi
    if [ -f "$CERT_PATH_ROOT_SERVICE" ]; then chmod 600 "$CERT_PATH_ROOT_SERVICE"; fi

    log_info "正在安装 cloudflared 服务 (将使用 $CONFIG_FILE_FINAL)..."
    cloudflared service install >/dev/null 2>&1 # This should pick up the config.yml
    if [ $? -ne 0 ]; then
        # service install 可能会因为服务已存在而返回非0，这里尝试忽略特定错误
        # 但如果服务真的安装失败，后续启动会出问题
        log_warn "cloudflared service install 命令返回非零状态，可能服务已存在或发生其他错误。"
    fi
    log_info "Cloudflared 服务已通过配置文件配置安装。"
fi

# 步骤 4: 启动/重启并验证 cloudflared 服务
log_info "正在启动/重启并验证 cloudflared 服务..."
if systemctl list-units --type=service --all | grep -Fq 'cloudflared.service'; then
    systemctl enable cloudflared.service >/dev/null
    systemctl restart cloudflared.service
    sleep 5
    if systemctl is-active --quiet cloudflared.service; then
        log_info "cloudflared 服务已成功启动并激活。"
    else
        log_error "cloudflared 服务启动失败。请检查日志: journalctl -u cloudflared.service"
    fi
else
    log_error "cloudflared 服务单元文件 ('cloudflared.service') 未找到或安装失败。"
fi

log_info "--------------------------------------------------------------------"
log_info "部署完成！"
if [ -n "$PRECONFIGURED_TUNNEL_TOKEN" ]; then
    log_info "Cloudflare Tunnel 已通过提供的 TOKEN 启动。"
    log_info "请确保您在 Cloudflare Dashboard 中为该隧道配置的公共主机名"
    log_info "正确指向您服务器的 localhost:$ADDITIONAL_SSH_PORT。"
    log_info "您用于连接的公共主机名是您在 Dashboard 中设置的那个。"
else
    log_info "Cloudflare Tunnel '$TUNNEL_NAME' 已通过脚本创建并启动。"
    log_info "  - 它将通过 '$SSH_HOSTNAME_INFO' 将 SSH 流量转发到您服务器的端口 $ADDITIONAL_SSH_PORT。"
fi
log_info "服务器 SSH 服务现在应该监听端口: $STANDARD_SSH_PORT 和 $ADDITIONAL_SSH_PORT。"
log_info "您可以通过以下方式访问 SSH 服务:"
log_info "  1. 通过 Cloudflare Tunnel (公共主机名在 Dashboard 设置或为 $SSH_HOSTNAME_INFO):"
log_info "     ssh <your-username>@<您的公共隧道主机名>"
log_info "  2. 直接通过服务器 IP (连接到服务器的 $STANDARD_SSH_PORT 端口):"
log_info "     ssh <your-username>@<server_ip_address> -p $STANDARD_SSH_PORT"
log_info "  3. 直接通过服务器 IP (连接到服务器的 $ADDITIONAL_SSH_PORT 端口):"
log_info "     ssh <your-username>@<server_ip_address> -p $ADDITIONAL_SSH_PORT"
log_info "重要 SSH 配置文件备份: /etc/ssh/sshd_config.bak_*"
if [ -z "$PRECONFIGURED_TUNNEL_TOKEN" ]; then
    log_info "Cloudflare Tunnel 配置文件: /etc/cloudflared/config.yml"
fi
log_info "--------------------------------------------------------------------"

exit 0
