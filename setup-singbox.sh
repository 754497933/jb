#!/bin/bash
# 一键安装 sing-box + 保活脚本 + cron 开机自启 (支持参数配置)
# 用法: 
#   ./setup-singbox.sh --uuid <your-uuid> [--dir <path>] [--version <ver>] [--port <port>]
# 示例:
#   ./setup-singbox.sh --uuid d252c2bd-d080-4fc0-931c-26f21d9c609a
#   ./setup-singbox.sh --uuid xxxx --dir /workspaces/myproject --port 8080

set -e  # 遇到错误立即退出

# ========== 默认值 ==========
DEFAULT_VERSION="1.10.1"
DEFAULT_PORT="8080"
# ===========================

# 初始化变量
VLESS_UUID=""
BASE_DIR=""
SINGBOX_VERSION=""
SINGBOX_PORT=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --uuid)
            VLESS_UUID="$2"
            shift 2
            ;;
        --dir)
            BASE_DIR="$2"
            shift 2
            ;;
        --version)
            SINGBOX_VERSION="$2"
            shift 2
            ;;
        --port)
            SINGBOX_PORT="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            echo "用法: $0 --uuid <uuid> [--dir <path>] [--version <ver>] [--port <port>]"
            exit 1
            ;;
    esac
done

# 检查必须参数
if [ -z "$VLESS_UUID" ]; then
    echo "错误: 必须提供 --uuid 参数 (VLESS 用户 UUID)"
    exit 1
fi

# 设置默认值
if [ -z "$SINGBOX_VERSION" ]; then
    SINGBOX_VERSION="$DEFAULT_VERSION"
fi
if [ -z "$SINGBOX_PORT" ]; then
    SINGBOX_PORT="$DEFAULT_PORT"
fi
if [ -z "$BASE_DIR" ]; then
    BASE_DIR="$(pwd)"   # 自适应：当前工作目录
fi

# 确保 BASE_DIR 是绝对路径
mkdir -p "$BASE_DIR"
BASE_DIR="$(cd "$BASE_DIR" && pwd)"

echo ">>> 配置信息:"
echo "   工作目录: $BASE_DIR"
echo "   sing-box 版本: $SINGBOX_VERSION"
echo "   sing-box 端口: $SINGBOX_PORT"
echo "   VLESS UUID: $VLESS_UUID"
echo ""

# ========== 开始部署 ==========
echo ">>> 开始一键部署 sing-box + 保活脚本..."

cd "$BASE_DIR"

# 1. 下载并解压 sing-box（如果已存在则跳过）
SINGBOX_TAR="sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
SINGBOX_DIR="$BASE_DIR/sing-box-${SINGBOX_VERSION}-linux-amd64"

if [ -f "$SINGBOX_DIR/sing-box" ]; then
    echo ">>> sing-box 已存在，跳过下载解压"
else
    echo ">>> 下载 sing-box ${SINGBOX_VERSION}"
    wget -q "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/$SINGBOX_TAR"
    echo ">>> 解压"
    tar -zxf "$SINGBOX_TAR"
    rm "$SINGBOX_TAR"
fi

# 2. 生成 config.json
cat > "$SINGBOX_DIR/config.json" << EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": ${SINGBOX_PORT},
    "users": [{ "uuid": "${VLESS_UUID}" }],
    "transport": { "type": "ws", "path": "/vless" }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
echo ">>> config.json 已生成"

# 3. 安装 cron 和 bc
apt update && apt install -y cron bc

# 4. 创建保活脚本（随机间隔 30~300 秒）
cat > "$BASE_DIR/keepalive.sh" << EOF
#!/bin/bash
LOG_FILE="$BASE_DIR/keepalive.log"

while true; do
    SLEEP_TIME=\$(( RANDOM % 271 + 30 ))
    echo "\$(date): 保活信号，下次间隔 \${SLEEP_TIME} 秒" >> "\$LOG_FILE"
    echo "scale=5000; 4*a(1)" | bc -l > /dev/null 2>&1
    sleep \$SLEEP_TIME
done
EOF
chmod +x "$BASE_DIR/keepalive.sh"

# 5. 创建统一启动脚本（启动 sing-box + 保活脚本）
cat > "$SINGBOX_DIR/start_services.sh" << EOF
#!/bin/bash
BASE_DIR="$BASE_DIR"
SINGBOX_DIR="$SINGBOX_DIR"

# sing-box 启动
PIDFILE="\$SINGBOX_DIR/sing-box.pid"
LOGFILE="\$BASE_DIR/sing-box.log"
cd "\$SINGBOX_DIR"
if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
    echo "\$(date): sing-box already running (PID \$(cat \$PIDFILE))" >> "\$LOGFILE"
else
    nohup ./sing-box run -c ./config.json >> "\$LOGFILE" 2>&1 &
    PID=\$!
    echo \$PID > "\$PIDFILE"
    echo "\$(date): sing-box started with PID \$PID" >> "\$LOGFILE"
fi

# 保活脚本启动
KEEPALIVE_PIDFILE="\$BASE_DIR/keepalive.pid"
KEEPALIVE_LOG="\$BASE_DIR/keepalive.log"
if [ -f "\$KEEPALIVE_PIDFILE" ] && kill -0 \$(cat "\$KEEPALIVE_PIDFILE") 2>/dev/null; then
    echo "\$(date): keepalive already running (PID \$(cat \$KEEPALIVE_PIDFILE))" >> "\$KEEPALIVE_LOG"
else
    nohup "\$BASE_DIR/keepalive.sh" >> "\$KEEPALIVE_LOG" 2>&1 &
    PID=\$!
    echo \$PID > "\$KEEPALIVE_PIDFILE"
    echo "\$(date): keepalive started with PID \$PID" >> "\$KEEPALIVE_LOG"
fi
EOF
chmod +x "$SINGBOX_DIR/start_services.sh"

# 6. 添加 crontab @reboot 任务
(crontab -l 2>/dev/null | grep -v "$SINGBOX_DIR/start_services.sh" ; echo "@reboot $SINGBOX_DIR/start_services.sh") | crontab -

# 7. 在 .bashrc 中添加启动 cron 的逻辑
if ! grep -q "service cron start" /root/.bashrc 2>/dev/null; then
    echo 'service cron start 2>/dev/null || /etc/init.d/cron start' >> /root/.bashrc
fi

# 8. 立即启动 cron 并拉起所有服务
service cron start 2>/dev/null || /etc/init.d/cron start
"$SINGBOX_DIR/start_services.sh"

# 9. 输出状态和提示（包含客户端配置和脚本使用指南）
echo ""
echo "========================================="
echo "✅ 一键部署完成！"
echo "========================================="
echo "sing-box 配置："
echo "  端口: $SINGBOX_PORT"
echo "  UUID: $VLESS_UUID"
echo "  WS 路径: /vless"
echo ""
echo "📂 日志位置："
echo "  sing-box: $BASE_DIR/sing-box.log"
echo "  保活脚本: $BASE_DIR/keepalive.log"
echo ""
echo "🔍 验证命令："
echo "  ps aux | grep -E 'sing-box|keepalive' | grep -v grep"
echo "  tail -f $BASE_DIR/sing-box.log"
echo "  tail -f $BASE_DIR/keepalive.log"
echo ""
echo "🌐 端口转发（如果未自动公开，请手动设置）："
echo "  将 Codespace 的 $SINGBOX_PORT 端口设为 Public"
echo ""
echo "========================================="
echo "📱 客户端配置 (v2rayN 示例)"
echo "========================================="
echo "若要在本地通过端口转发使用 (推荐):"
echo "  1. 建立隧道: gh codespace ports forward $SINGBOX_PORT:$SINGBOX_PORT"
echo "  2. v2rayN 参数:"
echo "     地址 (Address): 127.0.0.1"
echo "     端口 (Port): $SINGBOX_PORT"
echo "     用户 ID (UUID): $VLESS_UUID"
echo "     传输协议 (Network): ws"
echo "     伪装类型 (Header type): none"
echo "     路径 (Path): /vless"
echo "     底层传输安全 (TLS): none"
echo ""
echo "若需要直接使用 GitHub 预览域名 (https):"
echo "  需额外配置 TLS 证书 (略复杂，推荐端口转发方式)"
echo ""
echo "========================================="
echo "📥 脚本下载与使用指南"
echo "========================================="
echo "在其他 Codespace 中快速部署:"
echo "  wget -O setup-singbox.sh <你的raw链接>"
echo "  chmod +x setup-singbox.sh"
echo "  ./setup-singbox.sh --uuid <你的UUID>"
echo ""
echo "脚本已保存到当前目录，下次可用相同命令重新运行。"
echo "========================================="
