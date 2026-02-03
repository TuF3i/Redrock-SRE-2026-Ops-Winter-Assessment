#!/bin/bash

# 回滚系统变量
BACKUP_DIR="/tmp/network_backup_$(date +%Y%m%d_%H%M%S)"
ROLLBACK_COMMANDS=()

# 计时器服务变量
SCRIPT_NAME="network-check"
SERVICE_FILE="/etc/systemd/system/${SCRIPT_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SCRIPT_NAME}.timer"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"


# 设置错误处理
trap 'execute_rollback "脚本被中断"' INT TERM
trap 'if [[ $? -ne 0 && ${#ROLLBACK_COMMANDS[@]} -gt 0 ]]; then execute_rollback "脚本执行失败"; fi' EXIT

# 定义颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color，用于重置

# 样式变量
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
INVERT='\033[7m'

# 日志级别
declare -A LOG_LEVELS=(
    ["DEBUG"]=0
    ["INFO"]=1
    ["SUCCESS"]=2
    ["WARNING"]=3
    ["ERROR"]=4
    ["CRITICAL"]=5
)
# 默认日志级别
LOG_LEVEL=${LOG_LEVEL:-"DEBUG"} 
# 颜色
LOG_COLORED=${LOG_COLORED:-true}
# 时间戳
LOG_TIMESTAMP=${LOG_TIMESTAMP:-true}
# 显示级别
LOG_SHOW_LEVEL=${LOG_SHOW_LEVEL:-true}
# 日志输出
LOG_OUTPUT=${LOG_OUTPUT:-"/dev/stdout"}

function logger {
    local level="INFO"
    local message=""
    local timestamp=""
    local output_stream="/dev/stdout"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--level)
                level="$2"
                shift 2
                ;;
            -f|--file)
                LOG_OUTPUT="$2"
                shift 2
                ;;
            --no-color)
                LOG_COLORED=false
                shift
                ;;
            --no-timestamp)
                LOG_TIMESTAMP=false
                shift
                ;;
            --no-level)
                LOG_SHOW_LEVEL=false
                shift
                ;;
            *)
                message="$1"
                shift
                ;;
        esac
    done

    # 检查日志级别
    if [[ -z "${LOG_LEVELS[$level]}" ]]; then
        level="INFO"
    fi
    
    # 检查是否应该记录该级别
    if [[ ${LOG_LEVELS[$level]} -lt ${LOG_LEVELS[$LOG_LEVEL]} ]]; then
        return 0
    fi
    
    # 生成时间戳
    if [[ "$LOG_TIMESTAMP" == true ]]; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    
    # 确定输出流
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        output_stream="/dev/stderr"
    else
        output_stream="$LOG_OUTPUT"
    fi
    
    # 构建日志消息
    local log_entry=""
    
    # 添加时间戳
    if [[ -n "$timestamp" ]]; then
        log_entry+="[$timestamp] "
    fi
    
    # 添加日志级别
    if [[ "$LOG_SHOW_LEVEL" == true ]]; then
        log_entry+="$level: "
    fi
    
    # 添加消息
    log_entry+="$message"
    
    # 添加颜色（如果启用）
    if [[ "$LOG_COLORED" == true ]]; then
        case $level in
            "DEBUG")
                log_entry="${CYAN}${log_entry}${NC}"
                ;;
            "INFO")
                log_entry="${BLUE}${log_entry}${NC}"
                ;;
            "SUCCESS")
                log_entry="${GREEN}${log_entry}${NC}"
                ;;
            "WARNING")
                log_entry="${YELLOW}${log_entry}${NC}"
                ;;
            "ERROR")
                log_entry="${RED}${log_entry}${NC}"
                ;;
            "CRITICAL")
                log_entry="${RED}${BOLD}${log_entry}${NC}"
                ;;
            *)
                log_entry="${WHITE}${log_entry}${NC}"
                ;;
        esac
    fi
    
    # 输出日志
    echo -e "$log_entry" >> "$output_stream"
}

# 初始化备份目录
initBackup() {
    mkdir -p "$BACKUP_DIR"
    logger -l INFO "init backup dictionary: $BACKUP_DIR"
}

# 备份文件
backupFile() {
    local src="$1"
    local dst="$BACKUP_DIR/$(basename "$src")"
    
    if [[ -f "$src" ]]; then
        cp "$src" "$dst"
        logger -l INFO "backing up: $src -> $dst"
        ROLLBACK_COMMANDS+=("cp '$dst' '$src'")
    elif [[ -d "$src" ]]; then
        cp -r "$src" "$dst"
        logger -l INFO "backup dictionary: $src -> $dst"
        ROLLBACK_COMMANDS+=("rm -rf '$src' && cp -r '$dst' '$src'")
    fi
}

# 添加回滚命令
addRollback() {
    ROLLBACK_COMMANDS+=("$1")
}

# 执行回滚
executeRollback() {
    local reason="$1"
    
    echo ""
    logger -l WARNING "execute (reason: $reason)"
    echo "="*60
    
    # 反向执行回滚命令
    for ((i=${#ROLLBACK_COMMANDS[@]}-1; i>=0; i--)); do
        local cmd="${ROLLBACK_COMMANDS[i]}"
        logger -l INFO "Rolling back: $cmd"
        eval "$cmd" 2>/dev/null || true
    done
    
    logger -l SUCCESS "rolling back successfully"
    echo "="*60
}

function backupCurrentConfig {
    local device="$1"
    
    logger -l INFO "backingup current config..."
    
    # 备份网络连接
    if nmcli connection show "$device" &>/dev/null; then
        nmcli connection show "$device" > "$BACKUP_DIR/${device}_original.nmconnection"
        addRollback "nmcli connection delete '$device-dhcp' 2>/dev/null || true"
        addRollback "nmcli connection import type ethernet file '$BACKUP_DIR/${device}_original.nmconnection' 2>/dev/null || true"
        addRollback "nmcli connection up '$device' 2>/dev/null || true"
    fi
    
    # 备份所有连接
    nmcli connection show > "$BACKUP_DIR/all_connections.txt" 2>&1
    
    logger -l SUCCESS "successfully backed up current config"
}

function checkEnv {
    # 检查ifconfig是否存在
    if which ifconfig &>/dev/null; then
        logger -l INFO "check ifconfig success"
    else
        logger -l WARNING "no ifconfig command detect in the system, installing..."
        apt-get install net-tools -y &>/dev/null
        addRollback "apt-get remove --purge -y net-tools &>/dev/null || true"
    fi

    # 检查nmcli是否存在
    if which nmcli &>/dev/null; then
        logger -l INFO "check nmcli success"
    else
        logger -l WARNING "no nmcli command detect in the system, installing..."
        apt-get install network-manager -y &>/dev/null
        addRollback "apt-get remove --purge -y network-manager &>/dev/null || true"
        echo -e "[main]\nplugins=ifupdown,keyfile\n\n[ifupdown]\nmanaged=true  # 让 NetworkManager 管理 /etc/network/interfaces\n\n[device]\nwifi.scan-rand-mac-address=no" | sudo tee /etc/NetworkManager/NetworkManager.conf
        systemctl restart NetworkManager &>/dev/null
    fi
    # 检查NetworkManager是存在
    if ! systemctl list-unit-files | grep -q "^NetworkManager"; then
        logger -l CRITICAL "Service does not exist!"
        exit 1
    fi
    # 检查NetworkManager是可用
    if systemctl is-active --quiet NetworkManager; then
        logger -l INFO "check NetworkManager success"
    else
        logger -l ERROR "NetworkManager Service do not up, starting..."
        if systemctl start NetworkManager; then
            sleep 1
            if ! systemctl is-active --quiet NetworkManager; then
                logger -l CRITICAL "Failed to Start NetworkManager, Please run journalctl -u NetworkManager to cheack the logs"
                exit 1
            fi
        fi
    fi

    # 检查UFW是否存在
    if which ufw &>/dev/null; then
        logger -l INFO "check ufw success"
    else
        logger -l WARNING "no ufw command detect in the system, installing..."
        apt-get install ufw -y &>/dev/null
        addRollback "apt-get remove --purge -y ufw &>/dev/null || true"
    fi

    logger -l SUCCESS "enveriment check pass!"
    return 0
}

function checkRoot {
    if [ "$EUID" -ne 0 ]; then 
        logger -l ERROR "Please run this script as root!"
        exit 1
    fi
    return 0
}

function checkEthDevices {
    if [[ $# -gt 0 ]]; then
        logger -l INFO "Scaning device $1..."
        if ! nmcli device status | grep -q "$1.*connected\|$1.*disconnected"; then
            logger -l ERROR "unable to detect device $1"
            logger -l INFO "available devices:"
            nmcli device status
            exit 1
        else
            logger -l SUCCESS "device $1 online"
            return 0
        fi
    else
        logger -l CRITICAL "function checkEthDevices interal error"
        exit 1
    fi
}

function setDHCPMode {
    local device="$1"
    # 开始配置DHCP
    local connection_name="$1-dhcp"
    # 删除现有 eth0 连接（如果存在）
    if nmcli connection show $device &>/dev/null; then
        logger -l INFO "Trying to delete current device: $device"
        nmcli connection delete $device
    fi
    if nmcli connection show "$connection_name" &>/dev/null; then
        logger -l INFO "Trying to delete current connection: $connection_name"
        nmcli connection delete "$connection_name" 2>/dev/null || true
    fi
    # 创建新的 DHCP 连接
    logger -l INFO "Creating new connection DHCP for $device"
    nmcli connection add \
        type ethernet \
        ifname $device \
        con-name "$connection_name" \
        connection.autoconnect yes \
        connection.autoconnect-priority 0 \
        ipv4.method auto \
        ipv4.dhcp-client-id "" \
        ipv4.dhcp-timeout 30 \
        ipv4.dhcp-send-hostname yes \
        ipv4.dhcp-hostname "$(hostname)" \
        ipv4.ignore-auto-dns no \
        ipv4.ignore-auto-routes no \
        ipv4.may-fail yes \
        ipv6.method auto \
        ipv6.dhcp-timeout 30 \
        ipv6.ip6-privacy 0
    # 激活新的 DHCP 连接
    logger -l INFO "activing new connection DHCP for $device"
    # 先断开设备
    nmcli device disconnect $device 2>/dev/null
    # 启用新连接
    if nmcli connection up "$connection_name"; then
        logger -l SUCCESS "successfully actived new connection DHCP for $device"
    else
        logger -l CRITICAL "failed to active new connection DHCP for $device, rolling back..."
    fi
    # 等待DHCP获取地址
    sleep 3
    # 验证配置
    if ! ip addr show "$device" | grep -q "inet "; then
        logger -l WARNING "waiting for dhcp configuration..."
        sleep 5
        
        if ! ip addr show "$device" | grep -q "inet "; then
            logger -l WARNING "dhcp configuration fail"
            return 1
        fi
    fi

    logger -l SUCCESS "successfully switched to DHCP Mode for $device"
    return 0
}

function setStaticMode {
    local device="$1"
    # 开始static配置
    local connection_name="$1-static"
    # 删除现有 eth0 连接（如果存在）
    if nmcli connection show $device &>/dev/null; then
        logger -l INFO "Trying to delete current device: $device"
        nmcli connection delete $device
    fi
    if nmcli connection show "$connection_name" &>/dev/null; then
        logger -l INFO "Trying to delete current connection: $connection_name"
        nmcli connection delete "$connection_name" 2>/dev/null || true
    fi
    # 创建新的 STATIC 连接
    logger -l INFO "Creating new connection STATIC for $device"
    nmcli connection add \
        type ethernet \
        ifname $device \
        con-name "$connection_name" \
        connection.autoconnect yes \
        connection.autoconnect-priority 0 \
        ipv4.method manual \
        ipv4.addresses 172.22.146.150/24 \
        ipv4.gateway 172.22.146.1 \
        ipv4.dns "172.22.146.53,172.22.146.54" \
        ipv4.ignore-auto-dns yes \
        ipv4.ignore-auto-routes no \
        ipv4.may-fail yes \
        ipv6.method auto \
        ipv6.dhcp-timeout 30 \
        ipv6.ip6-privacy 0
    # 激活新的静态连接
    logger -l INFO "activing new connection STATIC for $device"
    # 先断开设备
    nmcli device disconnect $device 2>/dev/null
    # 启用新连接
    if nmcli connection up "$connection_name"; then
        logger -l SUCCESS "successfully actived new connection STATIC for $device"
    else
        logger -l CRITICAL "failed to active new connection STATIC for $device, rolling back..."
        return 1
    fi
    
    # 等待配置生效
    sleep 3
    
    # 验证配置
    if ! ip addr show "$device" | grep -q "inet 172.22.146.150"; then
        logger -l WARNING "waiting for static configuration..."
        sleep 5
        
        if ! ip addr show "$device" | grep -q "inet 172.22.146.150"; then
            logger -l WARNING "static configuration fail"
            return 1
        fi
    fi
    
    # 验证网关配置
    if ! ip route | grep -q "default via 172.22.146.1"; then
        logger -l WARNING "gateway configuration may not be correct"
    fi
    
    # 验证DNS配置
    if ! grep -q "172.22.146.53" /etc/resolv.conf 2>/dev/null && \
       ! nmcli connection show "$connection_name" | grep -q "172.22.146.53"; then
        logger -l WARNING "DNS configuration may not be correct"
    fi

    logger -l SUCCESS "successfully switched to STATIC Mode for $device"
    return 0
}

function setStaticUfw {
    logger -l INFO "Starting static network firewall configuration..."
    # 重置 UFW
    logger -l INFO "Resetting UFW to default state..."
    ufw --force reset
    # 设置默认策略：拒绝所有出站连接
    logger -l INFO "Setting default policies: deny all outgoing..."
    ufw default deny outgoing
     # 保持入站允许
    ufw default allow incoming
    # 允许本地回环
    logger -l INFO "Allowing loopback interface..."
    ufw allow out on lo
    ufw allow in on lo
    # 允许同一内网网段 172.22.146.0/24
    logger -l INFO "Allowing same subnet: 172.22.146.0/24..."
    ufw allow out to 172.22.146.0/24
    ufw allow in from 172.22.146.0/24
    # 允许内部网络 172.16.0.0/12
    logger -l INFO "Allowing internal network: 172.16.0.0/12..."
    ufw allow out to 172.16.0.0/12
    ufw allow in from 172.16.0.0/12
    # 允许已建立的连接
    logger -l INFO "Allowing established connections..."
    ufw allow out established
    logger -l INFO "Enabling UFW..."
    # 建立回滚
    addRollback "setDHCPUfw &>/dev/null || true"
    # 启用UFW
    if ufw --force enable; then
        logger -l SUCCESS "static firewall enabled successfully"
    else
        logger -l CRITICAL "Failed to enable UFW"
        return 1
    fi
}

function setDHCPUfw {
    logger -l INFO "Resetting firewall to default (dhcp) state..."
    
    ufw --force reset
    ufw default allow outgoing
    ufw default allow incoming
    ufw --force disable
    
    logger -l SUCCESS "dhcp firewall enabled successfully"
}

function cidr2netmask() {
   local cidr=$1
   local mask=""
   local full_octets=$((cidr / 8))
   local partial_octet=$((cidr % 8))
   
   for ((i=0; i<4; i++)); do
       if [[ $i -lt $full_octets ]]; then
           mask+="255"
       elif [[ $i -eq $full_octets ]]; then
           mask+=$((256 - 2**(8-partial_octet)))
       else
           mask+="0"
       fi
       [[ $i -lt 3 ]] && mask+="."
   done
   
   echo "$mask"
}

function getNetworkInfo() {
   local device="${1:-}"
   local connection_name=""
   
   # 如果没有指定设备，获取默认设备
   if [[ -z "$device" ]]; then
       device=$(ip route | grep default | awk '{print $5}' | head -n1)
       if [[ -z "$device" ]]; then
           logger -l ERROR "Error: Could not determine default network device"
           return 1
       fi
   fi
   
   # 获取连接名称
   connection_name=$(nmcli -t -f GENERAL.CONNECTION device show "$device" 2>/dev/null | cut -d: -f2)
   if [[ -z "$connection_name" ]]; then
       logger -l ERROR "Error: Device $device not managed by NetworkManager"
       return 1
   fi
   
   # 获取IP地址和CIDR
   local ip_cidr=$(nmcli -t -f IP4.ADDRESS device show "$device" 2>/dev/null | head -n1 | cut -d: -f2)
   local ip_address=""
   local subnet_mask=""
   local cidr=""
   
   if [[ -n "$ip_cidr" ]]; then
       ip_address=$(echo "$ip_cidr" | cut -d/ -f1)
       cidr=$(echo "$ip_cidr" | cut -d/ -f2)
       subnet_mask=$(cidr2netmask "$cidr")
   fi
   
   # 获取网关
   local gateway=$(nmcli -t -f IP4.GATEWAY device show "$device" 2>/dev/null | cut -d: -f2)
   
   # 获取DNS
   local dns_servers=$(nmcli -t -f IP4.DNS device show "$device" 2>/dev/null | cut -d: -f2 | tr '\n' ',' | sed 's/,$//')
   
   # 获取配置模式
   local ip_method=$(nmcli -t -f IPV4.METHOD connection show "$connection_name" 2>/dev/null | cut -d: -f2)
   local mode="Unknown"
   case "$ip_method" in
       auto) mode="DHCP" ;;
       manual) mode="Static" ;;
       disabled) mode="Disabled" ;;
       *) mode="$ip_method" ;;
   esac

   logger -l INFO "Network Detail as follow: "
   # 打印表格
   local w1=15 w2=30
   printf "+%s+%s+\n" "$(printf '%*s' $((w1+w2+1)) '' | tr ' ' '-')"
   printf "| %-*s | %-*s |\n" "$w1" "Property" "$w2" "Value"
   printf "+%s+%s+\n" "$(printf '%*s' $((w1+w2+1)) '' | tr ' ' '-')"
   printf "| %-*s | %-*s |\n" "$w1" "Device" "$w2" "$device"
   printf "| %-*s | %-*s |\n" "$w1" "Connection" "$w2" "$connection_name"
   printf "| %-*s | %-*s |\n" "$w1" "IP Address" "$w2" "${ip_address:-N/A}"
   printf "| %-*s | %-*s |\n" "$w1" "Subnet Mask" "$w2" "${subnet_mask:-N/A}"
   printf "| %-*s | %-*s |\n" "$w1" "CIDR" "$w2" "/${cidr:-N/A}"
   printf "| %-*s | %-*s |\n" "$w1" "Gateway" "$w2" "${gateway:-N/A}"
   printf "| %-*s | %-*s |\n" "$w1" "DNS Servers" "$w2" "${dns_servers:-N/A}"
   printf "| %-*s | %-*s |\n" "$w1" "Config Mode" "$w2" "$mode"
   printf "+%s+%s+\n" "$(printf '%*s' $((w1+w2+1)) '' | tr ' ' '-')"

   # 打印ufw信息
   logger -l INFO "Firewall Detail as follow: "
   ufw status verbose
}

function selfCheck {
    local device="$1"
    local outterAddr="114.114.114.114"

    if ! ping -c 3 -W 2 $outterAddr &>/dev/null; then
        logger -l SUCCESS "normally stayed at static mode"
        return 0
    else
        logger -l WARNING "self-check detectded unaccessed network access, reset to dhcp mod..."
        setDHCPMode "$device"
        setDHCPUfw
    fi
    return 0
}

# 计时器服务
function createSystemdTimer {
local device=$1
# service单元
SERVICE_CONTENT="[Unit]
Description=Network Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --device $device --mode self-check
StandardOutput=journal
StandardError=journal"

# timer 单元
TIMER_CONTENT="[Unit]
Description=Run Network Check Every Minute
Requires=${SCRIPT_NAME}.service

[Timer]
OnCalendar=*:*:00
OnBootSec=1min
Persistent=true

[Install]
WantedBy=timers.target"

# 没有服务单元文件就创建
if [[ -f "$SERVICE_FILE" ]]; then
    logger -l WARNING "Service already exists: $SERVICE_FILE"
    return 0
else
    logger -l INFO "Creating Service: $SERVICE_FILE"
    echo "$SERVICE_CONTENT" > "$SERVICE_FILE"
fi

# 没有计时器单元文件就创建
if [[ -f "$TIMER_FILE" ]]; then
    logger -l WARNING "Timer aleady: $TIMER_FILE"
else
    logger -l INFO "Creating Timer: $TIMER_FILE"
    echo "$TIMER_CONTENT" > "$TIMER_FILE"
fi

systemctl daemon-reload

}

function startTimer {
    local device=$1

    # 创建计时器服务
    createSystemdTimer "$device"
    # 启动计时器服务
    systemctl enable "$SCRIPT_NAME.timer" --now
    # 检查状态
    if [[ $? -eq 0 ]]; then
        logger -l INFO "Timer started successfully"
        status
    else
        logger -l ERROR "Failed to start timer"
        return 1
    fi

    return 0
}    

function stopTimer {
    local device=$1
    logger -l INFO "Stopping timer"
    # 终止计时器服务
    systemctl stop "$SCRIPT_NAME.timer" 2>/dev/null
    systemctl disable "$SCRIPT_NAME.timer" 2>/dev/null
    # 删除服务单元
    rm $SERVICE_FILE
    rm $TIMER_FILE
    # 检查状态
    if [[ $? -eq 0 ]]; then
        logger -l INFO "Timer stopped successfully"
        status
    else
        log_error "Failed to stop timer"
        return 1
    fi
}

function main {
    local device="eth0"
    local cornOn=0
    local mode="dhcp"

    # 初始化
    initBackup

    # 执行检查
    checkRoot || return 1
    checkEnv || return 1

    # 备份当前配置
    backupCurrentConfig "$device"

    # 主逻辑
    while [[ $# -gt 0 ]]; do 
        case $1 in 
            --device)
                device="$2"
                shift 2
                ;;
            --on-self-check)
                checkEthDevices "$device" || return 1
                startTimer "$device"
                shift 2
                ;;
            --off-self-check)
                checkEthDevices "$device" || return 1
                stopTimer "$device"
                shift 2
                ;;
            --dhcp-mode)
                checkEthDevices "$device" || return 1
                setDHCPMode "$device"
                setDHCPUfw
                getNetworkInfo "$device"
                shift 2
                ;;
            --static-mode)
                checkEthDevices "$device" || return 1
                setStaticMode "$device"
                setStaticUfw
                getNetworkInfo "$device"
                shift 2
                ;;
            --self-check)
                checkEthDevices "$device" || return 1
                selfCheck "$device"
                shift 2
                ;;
            --net-info)
                getNetworkInfo "$device"
                shift 2
                ;;
            --help|-h)
                # 显示help
                exit 0
                ;;
            *)
                # 显示help
                exit 0
                ;;
        esac
    done
}

# 入口

cat << "EOF"
 ________   _______    ________   ________   ________   ________   ___  __       
|\   __  \ |\  ___ \  |\   ___ \ |\   __  \ |\   __  \ |\   ____\ |\  \|\  \     
\ \  \|\  \\ \   __/| \ \  \_|\ \\ \  \|\  \\ \  \|\  \\ \  \___| \ \  \/  /|_   
 \ \   _  _\\ \  \_|/__\ \  \ \\ \\ \   _  _\\ \  \\\  \\ \  \     \ \   ___  \  
  \ \  \\  \|\ \  \_|\ \\ \  \_\\ \\ \  \\  \|\ \  \\\  \\ \  \____ \ \  \\ \  \ 
   \ \__\\ _\ \ \_______\\ \_______\\ \__\\ _\ \ \_______\\ \_______\\ \__\\ \__\
    \|__|\|__| \|_______| \|_______| \|__|\|__| \|_______| \|_______| \|__| \|__|
EOF
echo "Redrock-SRE-2026-Ops-Winter-Assessment/Ops";
main 