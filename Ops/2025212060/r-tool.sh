#!/bin/bash

# 回滚系统变量
BACKUP_DIR="/tmp/network_backup_$(date +%Y%m%d_%H%M%S)"
ROLLBACK_COMMANDS=()

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

}

function main {
    local device="${1:-eth0}"

    # 初始化
    initBackup

    # 执行检查
    checkRoot || return 1
    checkEnv || return 1
    checkEthDevices "$device" || return 1

    # 备份当前配置
    backupCurrentConfig "$device"


}