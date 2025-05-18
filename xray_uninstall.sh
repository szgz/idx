#!/bin/bash

# 更新版一键卸载脚本：用于移除由一键安装脚本部署的 Xray 代理服务器和 Cloudflared Tunnel。
# 此脚本将以非交互方式运行，并尝试恢复安装脚本所做的更改。

# --- 辅助函数 ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- 配置 (必须与安装脚本中的默认值匹配) ---
# 安装脚本使用的 Xray 安装目录
PROXY_DIR="$HOME/xray_auto_server"
# 安装脚本使用的 Xray Systemd 用户服务名称
XRAY_SERVICE_NAME="xray-user-proxy"
# Cloudflared APT 仓库列表文件
CLOUDFLARED_APT_LIST_FILE="/etc/apt/sources.list.d/cloudflared.list"
# Cloudflare GPG 密钥文件
CLOUDFLARE_GPG_KEY_FILE="/usr/share/keyrings/cloudflare-main.gpg"
# Cloudflared systemd 系统服务文件路径
CLOUDFLARED_SYSTEM_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
# Cloudflared update service (有时存在)
CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE="/etc/systemd/system/cloudflared-update.service"


# --- 脚本开始 ---
echo "🚀 开始卸载 Xray 代理服务器及 Cloudflared Tunnel..."
echo "--------------------------------------------------------------------"
# 如果任何命令失败，脚本将继续尝试执行后续步骤 (set +e 行为)
# 对于卸载脚本，有时我们希望它“尽力而为”。
# 如果需要严格的错误即停，请取消下一行的注释：
# set -e

# --- 卸载 Xray 用户服务 ---
echo "⚙️  1. 停止并禁用 Xray systemd 用户服务 (${XRAY_SERVICE_NAME})..."
if systemctl --user is-active --quiet ${XRAY_SERVICE_NAME}.service; then
    systemctl --user stop ${XRAY_SERVICE_NAME}.service || echo "    尝试停止 Xray 用户服务时遇到问题 (可能服务已自行停止)。"
    echo "    Xray 用户服务已尝试停止。"
else
    echo "    Xray 用户服务未在运行或已停止。"
fi

if systemctl --user is-enabled --quiet ${XRAY_SERVICE_NAME}.service; then
    systemctl --user disable ${XRAY_SERVICE_NAME}.service || echo "    尝试禁用 Xray 用户服务时遇到问题。"
    echo "    Xray 用户服务已尝试禁用。"
else
    echo "    Xray 用户服务未设置为用户登录后自启或已被禁用。"
fi

XRAY_SERVICE_FILE_PATH="$HOME/.config/systemd/user/${XRAY_SERVICE_NAME}.service"
echo "🗑️  2. 移除 Xray systemd 用户服务文件 (${XRAY_SERVICE_FILE_PATH})..."
if [ -f "${XRAY_SERVICE_FILE_PATH}" ]; then
    rm -f "${XRAY_SERVICE_FILE_PATH}"
    echo "    Xray 用户服务文件已移除。"
else
    echo "    Xray 用户服务文件未找到。"
fi

echo "🔄  3. 重新加载 systemd 用户守护进程..."
systemctl --user daemon-reload
echo "    systemd 用户守护进程已重新加载。"

echo "🗑️  4. 移除 Xray 安装目录 (${PROXY_DIR})..."
if [ -d "${PROXY_DIR}" ]; then
    # 使用 rm -rf 直接强制递归删除，无需交互
    rm -rf "${PROXY_DIR}"
    echo "    Xray 安装目录 (${PROXY_DIR}) 已直接移除。"
else
    echo "    Xray 安装目录 (${PROXY_DIR}) 未找到。"
fi
echo "--------------------------------------------------------------------"

# --- 卸载 Cloudflared 系统服务和相关组件 (需要 sudo) ---
echo "⚙️  5. 尝试卸载 Cloudflared 系统服务和相关组件 (需要 sudo 权限)..."

if ! command_exists "sudo"; then
    echo "⚠️ 'sudo' 命令未找到。无法执行需要特权的操作来卸载 cloudflared。"
    echo "   请手动执行后续的 cloudflared 卸载步骤（如果需要）。"
else
    echo "    检测到 'sudo' 命令，将尝试执行特权操作。"
    # 停止 cloudflared 服务
    echo "    停止 cloudflared 系统服务 (如果正在运行)..."
    if sudo systemctl is-active --quiet cloudflared.service; then
        sudo systemctl stop cloudflared.service || echo "        尝试停止 cloudflared 服务失败 (可能服务已停止)。"
        echo "        cloudflared 服务已尝试停止。"
    else
        echo "        cloudflared 服务未在运行或已停止。"
    fi
    if sudo systemctl is-active --quiet cloudflared-update.service; then
        sudo systemctl stop cloudflared-update.service || echo "        尝试停止 cloudflared-update 服务失败。"
        echo "        cloudflared-update 服务已尝试停止。"
    else
        echo "        cloudflared-update 服务未在运行或已停止。"
    fi

    # 禁用 cloudflared 服务
    if sudo systemctl is-enabled --quiet cloudflared.service; then
        sudo systemctl disable cloudflared.service || echo "        尝试禁用 cloudflared 服务失败。"
        echo "        cloudflared 服务已尝试禁用。"
    else
        echo "        cloudflared 服务未设置为开机自启或已被禁用。"
    fi
    if sudo systemctl is-enabled --quiet cloudflared-update.service; then
        sudo systemctl disable cloudflared-update.service || echo "        尝试禁用 cloudflared-update 服务失败。"
        echo "        cloudflared-update 服务已尝试禁用。"
    else
        echo "        cloudflared-update 服务未设置为开机自启或已被禁用。"
    fi

    # 尝试使用 cloudflared 自身的 uninstall 命令
    if command_exists "cloudflared"; then
        echo "    尝试使用 'cloudflared service uninstall' 命令..."
        sudo cloudflared service uninstall || echo "        'cloudflared service uninstall' 执行完毕或遇到问题。"
    else
        echo "    cloudflared 命令本身未找到，跳过 'service uninstall'步骤。"
    fi

    # 显式移除 systemd 服务文件
    if [ -f "${CLOUDFLARED_SYSTEM_SERVICE_FILE}" ]; then
        echo "    显式移除 systemd 服务文件: ${CLOUDFLARED_SYSTEM_SERVICE_FILE} ..."
        sudo rm -f "${CLOUDFLARED_SYSTEM_SERVICE_FILE}"
        echo "        服务文件 ${CLOUDFLARED_SYSTEM_SERVICE_FILE} 已尝试移除。"
    else
        echo "    systemd 服务文件 ${CLOUDFLARED_SYSTEM_SERVICE_FILE} 未找到。"
    fi
    if [ -f "${CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE}" ]; then
        echo "    显式移除 systemd 服务文件: ${CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE} ..."
        sudo rm -f "${CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE}"
        echo "        服务文件 ${CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE} 已尝试移除。"
    else
        echo "    systemd 服务文件 ${CLOUDFLARED_UPDATE_SYSTEM_SERVICE_FILE} 未找到。"
    fi

    echo "    重新加载 systemd 系统守护进程..."
    sudo systemctl daemon-reload

    # 移除 cloudflared 软件包
    echo "    正在尝试移除 cloudflared 软件包..."
    PACKAGE_INSTALLED_VIA_MGR=false
    if command_exists "apt-get"; then
        if dpkg -s cloudflared &> /dev/null; then PACKAGE_INSTALLED_VIA_MGR=true; fi
    elif command_exists "dnf"; then
        if rpm -q cloudflared &> /dev/null; then PACKAGE_INSTALLED_VIA_MGR=true; fi
    elif command_exists "yum"; then
        if rpm -q cloudflared &> /dev/null; then PACKAGE_INSTALLED_VIA_MGR=true; fi
    fi

    if [ "$PACKAGE_INSTALLED_VIA_MGR" = true ] ; then
        if command_exists "apt-get"; then
            sudo apt-get purge -y cloudflared
            sudo apt-get autoremove -y
            echo "        cloudflared 软件包尝试移除和清理完成 (apt)。"
        elif command_exists "dnf"; then
            sudo dnf remove -y cloudflared
            echo "        cloudflared 软件包尝试移除完成 (dnf)。"
        elif command_exists "yum"; then
            sudo yum remove -y cloudflared
            echo "        cloudflared 软件包尝试移除完成 (yum)。"
        fi
    else
        echo "        cloudflared 软件包未通过已知包管理器安装或已移除。"
    fi

    # 移除 Cloudflare APT 仓库配置和 GPG 密钥
    if [ -f "${CLOUDFLARED_APT_LIST_FILE}" ]; then
        echo "    正在移除 Cloudflare APT 仓库配置文件 (${CLOUDFLARED_APT_LIST_FILE})..."
        sudo rm -f "${CLOUDFLARED_APT_LIST_FILE}"
        echo "        APT 仓库配置文件已移除。"
    else
        echo "    Cloudflare APT 仓库配置文件未找到。"
    fi

    if [ -f "${CLOUDFLARE_GPG_KEY_FILE}" ]; then
        echo "    正在移除 Cloudflare GPG 密钥文件 (${CLOUDFLARE_GPG_KEY_FILE})..."
        sudo rm -f "${CLOUDFLARE_GPG_KEY_FILE}"
        echo "        GPG 密钥文件已移除。"
    else
        echo "    Cloudflare GPG 密钥文件未找到。"
    fi

    if command_exists "apt-get"; then
        if [ ! -f "${CLOUDFLARED_APT_LIST_FILE}" ]; then
            echo "    正在更新 APT 包列表缓存 (在移除了 cloudflared 仓库后)..."
            sudo apt-get update -qq || echo "        apt-get update 执行完毕。"
        fi
    fi
    echo "    Cloudflared 相关组件卸载尝试完成。"
fi

echo "--------------------------------------------------------------------"
echo "✅ Xray 及 Cloudflared 卸载流程执行完毕。"
echo ""
echo "重要提示:"
echo "  - 此脚本已尝试移除 Xray 用户服务、其文件目录，以及 Cloudflared 系统服务、软件包和仓库配置（如果适用）。"
echo "  - 通用依赖项 (例如 curl, unzip) 未被卸载。"
echo "  - Cloudflare Tunnel 可能在 ~/.cloudflared/ 目录下留有凭证文件 (如 cert.pem 和可能的 .json 文件)，"
echo "    如果您希望完全清除，请考虑手动删除 ~/.cloudflared/ 目录 (请注意这会影响所有使用该目录的 Tunnel)。"
echo "  - 如果您之前为您的用户手动启用了 lingering (例如通过: sudo loginctl enable-linger user)，"
echo "    并且您不再需要任何用户服务在登出后继续运行，您可以考虑手动禁用它。命令如下："
echo "    sudo loginctl disable-linger user"
echo "    (请注意：此命令需要 sudo 权限)。"
echo "  - 如果您曾为 Xray 或 Cloudflare 手动添加过防火墙规则，您需要手动移除这些规则。"
echo "--------------------------------------------------------------------"

exit 0
