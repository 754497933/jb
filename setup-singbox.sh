#!/bin/bash
# 一键安装 sing-box + 增强版保活脚本 (带自动重启功能) + cron 开机自启
# 用法: 
#   ./setup-singbox.sh --uuid <your-uuid> [--dir <path>] [--version <ver>] [--port <port>]
# 示例:
#   ./setup-singbox.sh --uuid d252c2bd-d080-4fc0-931c-26f21d9c609a
#   ./setup-singbox.sh --uuid xxxx --dir /workspaces/myproject --port 8080

set -e

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
    BASE_DIR="$(pwd)"
fi

# 确保 BASE_DIR 是绝对路径
mkdir -p "$BASE_DIR"
BASE_DIR="$(cd "$BASE_DIR" && pwd)"
SINGBOX_DIR="$BASE_DIR/sing-box-${SINGBOX_VERSION}-linux-amd64"

echo ""
echo "========================================="
echo "部署配置："
echo "  工作目录: $BASE_DIR"
echo "  sing-box 版本: $SINGBOX_VERSION"
echo "  sing-box 端口: $SINGBOX_PORT"
echo "  VLESS UUID: $VLESS_UUID"
echo "========================================="
echo ""

# ========== 1. 下载并解压 sing-box ==========
cd "$BASE_DIR"
SINGBOX_TAR="sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"

if [ -f "$SINGBOX_DIR/sing-box" ]; then
    echo ">>> sing-box 已存在，跳过下载解压"
else
    echo ">>> 下载 sing-box ${SINGBOX_VERSION}"
    wget -q --show-progress "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/$SINGBOX_TAR"
    echo ">>> 解压"
    tar -zxf "$SINGBOX_TAR"
    rm "$SINGBOX_TAR"
fi

# ========== 2. 生成 config.json ==========
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

# ========== 3. 安装依赖 ==========
echo ">>> 安装依赖 (cron, bc)..."
apt update -qq && apt install -y -qq cron bc

# ========== 4. 创建增强版保活脚本（带自动重启 sing-box 功能）==========
cat > "$BASE_DIR/keepalive.sh" << EOF
#!/bin/bash
# 增强版保活脚本 - 防止 Codespace 休眠 + 自动重启 sing-box

BASE_DIR="$BASE_DIR"
SINGBOX_DIR="$SINGBOX_DIR"
LOG_FILE="$BASE_DIR/keepalive.log"

echo "\$(date): ========== 增强版保活脚本启动 ==========" >> "\$LOG_FILE"

while true; do
    # 检查并重启 sing-box（如果未运行）
    if ! pgrep -f "sing-box run" > /dev/null; then
        echo "\$(date): ❌ sing-box 未运行，正在重启..." >> "\$LOG_FILE"
        rm -f "\$SINGBOX_DIR/sing-box.pid"
        cd "\$SINGBOX_DIR"
        nohup ./sing-box run -c ./config.json >> "\$BASE_DIR/sing-box.log" 2>&1 &
        PID=\$!
        echo \$PID > "\$SINGBOX_DIR/sing-box.pid"
        echo "\$(date): ✅ sing-box 已重启 (PID: \$PID)" >> "\$LOG_FILE"
        sleep 3
        if pgrep -f "sing-box run" > /dev/null; then
            echo "\$(date): ✅ sing-box 启动确认成功" >> "\$LOG_FILE"
        else
            echo "\$(date): ⚠️ sing-box 启动失败，请检查日志" >> "\$LOG_FILE"
        fi
    fi
    
    # 随机间隔（30~300 秒）
    SLEEP_TIME=\$(( RANDOM % 271 + 30 ))
    echo "\$(date): 💓 保活信号，下次检查间隔 \${SLEEP_TIME} 秒" >> "\$LOG_FILE"
    
    # 模拟 CPU 活动（防止休眠）
    echo "scale=5000; 4*a(1)" | bc -l > /dev/null 2>&1
    
    sleep \$SLEEP_TIME
done
EOF
chmod +x "$BASE_DIR/keepalive.sh"
echo ">>> 增强版保活脚本已创建"

# ========== 5. 创建启动脚本 ==========
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
echo ">>> 启动脚本已创建"

# ========== 6. 配置 crontab 开机自启 ==========
(crontab -l 2>/dev/null | grep -v "$SINGBOX_DIR/start_services.sh" ; echo "@reboot $SINGBOX_DIR/start_services.sh") | crontab -
echo ">>> crontab @reboot 已添加"

# ========== 7. 配置 .bashrc 启动 cron ==========
if ! grep -q "service cron start" /root/.bashrc 2>/dev/null; then
    echo 'service cron start 2>/dev/null || /etc/init.d/cron start' >> /root/.bashrc
    echo ">>> .bashrc 已配置"
fi

# ========== 8. 立即启动所有服务 ==========
service cron start 2>/dev/null || /etc/init.d/cron start
"$SINGBOX_DIR/start_services.sh"

# ========== 9. 输出完成信息 ==========
echo ""
echo "========================================="
echo "✅ 一键部署完成！"
echo "========================================="
echo ""
echo "📋 sing-box 配置："
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
echo "🌐 端口转发："
echo "  将 Codespace 的 $SINGBOX_PORT 端口设为 Public"
echo ""
echo "========================================="
echo "📱 客户端配置 (v2rayN 示例)"
echo "========================================="
echo "  地址 (Address): 127.0.0.1 (通过端口转发后)"
echo "  端口 (Port): $SINGBOX_PORT"
echo "  用户 ID (UUID): $VLESS_UUID"
echo "  传输协议 (Network): ws"
echo "  伪装类型 (Header type): none"
echo "  路径 (Path): /vless"
echo "  底层传输安全 (TLS): none"
echo ""
echo "  本地端口转发命令:"
echo "  gh codespace ports forward $SINGBOX_PORT:$SINGBOX_PORT"
echo "========================================="
echo ""
echo "📥 脚本下载与使用指南"
echo "========================================="
echo "  在其他 Codespace 中快速部署:"
echo "  wget -O setup-singbox.sh <你的raw链接>"
echo "  chmod +x setup-singbox.sh"
echo "  ./setup-singbox.sh --uuid <你的UUID>"
echo "========================================="
