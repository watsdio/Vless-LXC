#!/bin/bash
# seven-busybox.sh - BusyBox 兼容版

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 路径定义
WORKDIR="$HOME/.seven-proxy"
BIN_DIR="$WORKDIR/bin"
CONFIG_DIR="$WORKDIR/config"
LOG_DIR="$WORKDIR/logs"
PID_DIR="$WORKDIR/pid"

# 初始化目录
init_dirs() {
    mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"
}

# BusyBox 兼容的进程检查
check_process() {
    local pid=$1
    local name=$2
    if [ -f "/proc/$pid/cmdline" ]; then
        if grep -q "$name" "/proc/$pid/cmdline" 2>/dev/null; then
            echo "running"
            return 0
        fi
    fi
    echo "stopped"
    return 1
}

# 清理端口 (BusyBox 兼容)
clean_port() {
    local port=10581
    echo -e "${YELLOW}清理端口 $port...${NC}"
    
    # 使用 netstat 查找进程
    local pids=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f1 | sort -u)
    
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}发现占用端口 $port 的进程: $pids${NC}"
        for pid in $pids; do
            # 检查进程名，避免杀死系统进程
            local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
            if [[ "$cmdline" == *"sing-box"* ]] || [[ "$cmdline" == *"cloudflared"* ]] || [[ "$cmdline" == *"seven"* ]]; then
                echo -e "停止进程 $pid: $cmdline"
                kill "$pid" 2>/dev/null || true
                sleep 1
            else
                echo -e "跳过系统进程 $pid: $cmdline"
            fi
        done
    fi
    
    # 额外检查 sing-box 和 cloudflared 进程
    pkill -f "sing-box" 2>/dev/null || true
    pkill -f "cloudflared" 2>/dev/null || true
    
    echo -e "${GREEN}端口清理完成${NC}"
}

# 生成UUID
generate_uuid() {
    if [ -f "/proc/sys/kernel/random/uuid" ]; then
        cat "/proc/sys/kernel/random/uuid"
    else
        # 简单的UUID生成
        echo "$(hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/urandom)" | \
        sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# 下载文件
download_file() {
    local url=$1
    local output=$2
    echo -e "${CYAN}下载: $(basename $output)${NC}"
    
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L -o "$output" "$url"
    else
        echo -e "${RED}需要 wget 或 curl${NC}"
        return 1
    fi
    
    if [ -f "$output" ]; then
        chmod +x "$output"
        echo -e "${GREEN}下载完成${NC}"
        return 0
    else
        echo -e "${RED}下载失败${NC}"
        return 1
    fi
}

# 安装流程
install_guided() {
    echo -e "${GREEN}=== Seven Proxy 安装 (BusyBox兼容版) ===${NC}"
    
    # 清理
    clean_port
    init_dirs
    
    # UUID
    echo -e "\n${CYAN}UUID配置${NC}"
    echo -e "${YELLOW}是否自动生成UUID? (y/n)[y]: ${NC}\c"
    read auto_uuid
    auto_uuid=${auto_uuid:-y}
    
    if [[ "$auto_uuid" =~ ^[Yy]$ ]]; then
        uuid=$(generate_uuid)
        echo -e "UUID: ${GREEN}$uuid${NC}"
    else
        echo -e "${YELLOW}请输入UUID: ${NC}\c"
        read uuid
        if [ -z "$uuid" ]; then
            uuid=$(generate_uuid)
            echo -e "使用自动生成的 UUID: ${GREEN}$uuid${NC}"
        fi
    fi
    
    # 隧道模式
    echo -e "\n${CYAN}隧道模式选择${NC}"
    echo "1) 临时隧道 (推荐)"
    echo "2) 固定隧道"
    echo -e "${YELLOW}请选择[1]: ${NC}\c"
    read mode
    mode=${mode:-1}
    
    # 下载二进制
    echo -e "\n${CYAN}下载必要组件...${NC}"
    
    # 下载 sing-box
    if [ ! -f "$BIN_DIR/sing-box" ]; then
        download_file "https://github.com/SagerNet/sing-box/releases/download/v1.8.11/sing-box-1.8.11-linux-amd64.tar.gz" "/tmp/sing-box.tar.gz"
        mkdir -p /tmp/sing-box-temp
        tar -xz -f "/tmp/sing-box.tar.gz" -C /tmp/sing-box-temp
        find /tmp/sing-box-temp -name "sing-box" -type f -executable | head -1 | xargs -I {} cp {} "$BIN_DIR/sing-box"
        rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-temp
    fi
    
    # 下载 cloudflared
    if [ ! -f "$BIN_DIR/cloudflared" ]; then
        download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$BIN_DIR/cloudflared"
    fi
    
    # 创建配置
    echo -e "\n${CYAN}生成配置文件...${NC}"
    cat > "$CONFIG_DIR/seven.json" <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    { 
      "type": "vless", 
      "tag": "proxy", 
      "listen": "0.0.0.0", 
      "listen_port": 10581,
      "users": [ 
        { 
          "uuid": "$uuid", 
          "flow": "" 
        }
      ],
      "transport": { 
        "type": "ws", 
        "path": "/$uuid", 
        "max_early_data": 2048, 
        "early_data_header_name": "Sec-WebSocket-Protocol" 
      }
    }
  ],
  "outbounds": [ 
    { 
      "type": "direct", 
      "tag": "direct"
    }
  ]
}
EOF
    
    # 启动 sing-box
    echo -e "\n${CYAN}启动 sing-box...${NC}"
    cd "$WORKDIR"
    nohup "$BIN_DIR/sing-box" run -c "$CONFIG_DIR/seven.json" > "$LOG_DIR/sing-box.log" 2>&1 &
    local singbox_pid=$!
    echo $singbox_pid > "$PID_DIR/sing-box.pid"
    
    sleep 3
    if [ -f "/proc/$singbox_pid/status" ]; then
        echo -e "${GREEN}sing-box 启动成功 (PID: $singbox_pid)${NC}"
    else
        echo -e "${RED}sing-box 启动失败${NC}"
        tail -10 "$LOG_DIR/sing-box.log"
        exit 1
    fi
    
    if [ "$mode" = "1" ]; then
        # 临时隧道
        echo -e "\n${CYAN}启动临时隧道...${NC}"
        nohup "$BIN_DIR/cloudflared" tunnel --url http://localhost:10581 > "$LOG_DIR/cloudflared.log" 2>&1 &
        echo $! > "$PID_DIR/cloudflared.pid"
        
        echo -e "${YELLOW}等待隧道建立...${NC}"
        for i in {1..10}; do
            sleep 3
            if grep -q "Connection established" "$LOG_DIR/cloudflared.log"; then
                echo -e "${GREEN}隧道连接已建立${NC}"
                break
            fi
            echo -n "."
        done
    else
        # 固定隧道
        echo -e "\n${CYAN}固定隧道配置${NC}"
        echo -e "${YELLOW}请输入 Cloudflare Tunnel Token: ${NC}"
        read token
        echo -e "${YELLOW}请输入域名: ${NC}"
        read domain
        
        echo "$token" > "$CONFIG_DIR/token.txt"
        echo "$domain" > "$CONFIG_DIR/domain.txt"
        
        echo -e "\n${CYAN}启动固定隧道...${NC}"
        nohup "$BIN_DIR/cloudflared" tunnel run --token "$token" > "$LOG_DIR/cloudflared.log" 2>&1 &
        echo $! > "$PID_DIR/cloudflared.pid"
        
        echo -e "${YELLOW}等待隧道建立...${NC}"
        sleep 5
    fi
    
    # 显示结果
    show_results
}

# 显示结果
show_results() {
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🎉 Seven Proxy 安装完成！${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    
    # 获取UUID
    local uuid=""
    if [ -f "$CONFIG_DIR/seven.json" ]; then
        uuid=$(grep -o '"uuid": "[^"]*"' "$CONFIG_DIR/seven.json" | head -1 | cut -d'"' -f4)
    fi
    
    echo -e "${CYAN}配置信息:${NC}"
    echo -e "  UUID: ${uuid:-未知}"
    echo -e "  本地端口: 10581"
    
    # 获取域名
    local domain=""
    if [ -f "$CONFIG_DIR/domain.txt" ]; then
        domain=$(cat "$CONFIG_DIR/domain.txt")
    fi
    
    if [ -z "$domain" ] && [ -f "$LOG_DIR/cloudflared.log" ]; then
        domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -1 | sed 's#https://##')
    fi
    
    if [ -n "$domain" ] && [ -n "$uuid" ]; then
        echo -e "  隧道域名: $domain"
        
        # 生成链接
        local path_encoded="%2F${uuid}%3Fed%3D2048"
        local link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&host=${domain}&fp=chrome&type=ws&path=${path_encoded}#SevenProxy_BusyBox"
        
        echo -e "\n${CYAN}节点链接:${NC}"
        echo "$link"
        
        echo "$link" > "$CONFIG_DIR/node-link.txt"
        echo -e "\n${YELLOW}链接已保存到: $CONFIG_DIR/node-link.txt${NC}"
    else
        echo -e "${YELLOW}隧道启动中，请稍后查看状态${NC}"
        echo -e "${YELLOW}使用命令查看日志: tail -f $LOG_DIR/cloudflared.log${NC}"
    fi
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
}

# 查看状态
check_status() {
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    
    # 检查 sing-box
    if [ -f "$PID_DIR/sing-box.pid" ]; then
        local pid=$(cat "$PID_DIR/sing-box.pid")
        if [ -f "/proc/$pid/status" ]; then
            echo -e "sing-box: ${GREEN}运行中 (PID: $pid)${NC}"
        else
            echo -e "sing-box: ${RED}已停止${NC}"
        fi
    else
        echo -e "sing-box: ${YELLOW}未运行${NC}"
    fi
    
    # 检查 cloudflared
    if [ -f "$PID_DIR/cloudflared.pid" ]; then
        local pid=$(cat "$PID_DIR/cloudflared.pid")
        if [ -f "/proc/$pid/status" ]; then
            echo -e "cloudflared: ${GREEN}运行中 (PID: $pid)${NC}"
        else
            echo -e "cloudflared: ${RED}已停止${NC}"
        fi
    else
        echo -e "cloudflared: ${YELLOW}未运行${NC}"
    fi
    
    # 检查端口
    echo -e "\n${CYAN}端口状态:${NC}"
    if netstat -tln 2>/dev/null | grep -q ":10581"; then
        echo -e "10581端口: ${GREEN}监听正常${NC}"
    else
        echo -e "10581端口: ${RED}未监听${NC}"
    fi
    
    # 显示域名
    local domain=""
    if [ -f "$CONFIG_DIR/domain.txt" ]; then
        domain=$(cat "$CONFIG_DIR/domain.txt")
    elif [ -f "$LOG_DIR/cloudflared.log" ]; then
        domain=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -1 | sed 's#https://##')
    fi
    
    if [ -n "$domain" ]; then
        echo -e "\n${CYAN}隧道域名: $domain${NC}"
    fi
}

# 停止服务
stop_services() {
    echo -e "${YELLOW}停止服务...${NC}"
    
    # 停止 sing-box
    if [ -f "$PID_DIR/sing-box.pid" ]; then
        local pid=$(cat "$PID_DIR/sing-box.pid")
        if [ -f "/proc/$pid/status" ]; then
            kill "$pid" 2>/dev/null || true
            echo -e "sing-box: ${GREEN}已停止${NC}"
        fi
        rm -f "$PID_DIR/sing-box.pid"
    fi
    
    # 停止 cloudflared
    if [ -f "$PID_DIR/cloudflared.pid" ]; then
        local pid=$(cat "$PID_DIR/cloudflared.pid")
        if [ -f "/proc/$pid/status" ]; then
            kill "$pid" 2>/dev/null || true
            echo -e "cloudflared: ${GREEN}已停止${NC}"
        fi
        rm -f "$PID_DIR/cloudflared.pid"
    fi
    
    # 额外清理
    pkill -f "sing-box" 2>/dev/null || true
    pkill -f "cloudflared" 2>/dev/null || true
    
    echo -e "${GREEN}所有服务已停止${NC}"
}

# 卸载
uninstall() {
    echo -e "${RED}=== 卸载 Seven Proxy ===${NC}"
    echo -e "${YELLOW}确定要完全卸载吗? (y/n): ${NC}\c"
    read confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        stop_services
        rm -rf "$WORKDIR"
        echo -e "${GREEN}已完全卸载${NC}"
    else
        echo -e "${GREEN}取消卸载${NC}"
    fi
}

# 菜单
show_menu() {
    clear
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}            Seven Proxy (BusyBox兼容版)             ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}1. 安装/重新安装${NC}"
    echo -e "${CYAN}2. 查看状态${NC}"
    echo -e "${CYAN}3. 停止服务${NC}"
    echo -e "${RED}4. 完全卸载${NC}"
    echo -e "${YELLOW}5. 退出${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}请选择 [1-5]: ${NC}\c"
}

# 主函数
main() {
    case "${1:-}" in
        install)
            install_guided
            ;;
        status)
            check_status
            ;;
        stop)
            stop_services
            ;;
        uninstall)
            uninstall
            ;;
        *)
            while true; do
                show_menu
                read choice
                case $choice in
                    1) install_guided ;;
                    2) check_status ;;
                    3) stop_services ;;
                    4) uninstall ;;
                    5) exit 0 ;;
                    *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
                esac
                echo -e "\n按 Enter 继续..."
                read
            done
            ;;
    esac
}

# 运行
main "$@"
