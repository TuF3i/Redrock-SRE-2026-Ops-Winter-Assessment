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
    logger -l WARNING "execute rollback (reason: $reason)"
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
        echo -e "[main]\nplugins=ifupdown,keyfile\n\n[ifupdown]\nmanaged=true\n\n[device]\nwifi.scan-rand-mac-address=no" | sudo tee /etc/NetworkManager/NetworkManager.conf
        systemctl restart NetworkManager &>/dev/null
    fi
    # 检查NetworkManager是否存在
    if ! systemctl list-unit-files | grep -q "^NetworkManager"; then
        logger -l CRITICAL "Service does not exist!"
        exit 1
    fi
    # 检查NetworkManager是否可用
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
    
    logger -l INFO "Configuring DHCP mode for device: $device"
    
    # 删除现有连接
    if nmcli connection show "$device" &>/dev/null; then
        logger -l INFO "Deleting existing connection: $device"
        nmcli connection delete "$device"
    fi
    if nmcli connection show "$connection_name" &>/dev/null; then
        logger -l INFO "Deleting existing connection: $connection_name"
        nmcli connection delete "$connection_name" 2>/dev/null || true
    fi
    
    # 创建新的DHCP连接
    logger -l INFO "Creating new DHCP connection: $connection_name"
    nmcli connection add \
        type ethernet \
        ifname "$device" \
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
    
    # 激活DHCP连接
    logger -l INFO "Activating DHCP connection: $connection_name"
    nmcli device disconnect "$device" 2>/dev/null || true
    
    if nmcli connection up "$connection_name"; then
        logger -l SUCCESS "DHCP connection activated: $connection_name"
    else
        logger -l CRITICAL "Failed to activate DHCP connection: $connection_name"
        return 1
    fi
    
    # 等待DHCP获取地址
    sleep 3
    
    # 验证配置
    if ! ip addr show "$device" | grep -q "inet "; then
        logger -l WARNING "Waiting for DHCP configuration..."
        sleep 5
        
        if ! ip addr show "$device" | grep -q "inet "; then
            logger -l ERROR "DHCP configuration failed"
            return 1
        fi
    fi

    logger -l SUCCESS "Successfully switched to DHCP mode for device: $device"
    return 0
}

function setStaticMode {
    local device="$1"
    # 开始static配置
    local connection_name="$1-static"
    
    logger -l INFO "Configuring static mode for device: $device"
    
    # 删除现有连接
    if nmcli connection show "$device" &>/dev/null; then
        logger -l INFO "Deleting existing connection: $device"
        nmcli connection delete "$device"
    fi
    if nmcli connection show "$connection_name" &>/dev/null; then
        logger -l INFO "Deleting existing connection: $connection_name"
        nmcli connection delete "$connection_name" 2>/dev/null || true
    fi
    
    # 创建新的静态IP连接
    logger -l INFO "Creating new static connection: $connection_name"
    nmcli connection add \
        type ethernet \
        ifname "$device" \
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
    
    # 激活静态IP连接
    logger -l INFO "Activating static connection: $connection_name"
    nmcli device disconnect "$device" 2>/dev/null || true
    
    if nmcli connection up "$connection_name"; then
        logger -l SUCCESS "Static connection activated: $connection_name"
    else
        logger -l CRITICAL "Failed to activate static connection: $connection_name"
        return 1
    fi
    
    # 等待配置生效
    sleep 3
    
    # 验证配置
    if ! ip addr show "$device" | grep -q "inet 172.22.146.150"; then
        logger -l WARNING "Waiting for static configuration..."
        sleep 5
        
        if ! ip addr show "$device" | grep -q "inet 172.22.146.150"; then
            logger -l ERROR "Static configuration failed"
            return 1
        fi
    fi
    
    # 验证网关配置
    if ! ip route | grep -q "default via 172.22.146.1"; then
        logger -l WARNING "Gateway configuration may not be correct"
    fi
    
    # 验证DNS配置
    if ! grep -q "172.22.146.53" /etc/resolv.conf 2>/dev/null && \
       ! nmcli connection show "$connection_name" | grep -q "172.22.146.53"; then
        logger -l WARNING "DNS configuration may not be correct"
    fi

    logger -l SUCCESS "Successfully switched to static mode for device: $device"
    return 0
}

function setStaticUfw {
    logger -l INFO "Configuring firewall for static mode..."
    
    # 重置UFW到默认状态
    logger -l INFO "Resetting UFW to default state..."
    ufw --force reset
    
    # 设置默认策略：拒绝所有出站连接
    logger -l INFO "Setting default policies: deny outgoing..."
    ufw default deny outgoing
    ufw default allow incoming
    # 允许本地回环
    logger -l INFO "Allowing loopback interface..."
    ufw allow out on lo
    ufw allow in on lo
    
    # 允许同一内网网段 172.22.146.0/24
    logger -l INFO "Allowing subnet: 172.22.146.0/24..."
    ufw allow out to 172.22.146.0/24
    ufw allow in from 172.22.146.0/24
    
    # 允许内部网络 172.16.0.0/12
    logger -l INFO "Allowing internal network: 172.16.0.0/12..."
    ufw allow out to 172.16.0.0/12
    ufw allow in from 172.16.0.0/12
    
    # 允许已建立的连接
    logger -l INFO "Allowing established connections..."
    ufw allow out established
    
    # 添加回滚命令：恢复到DHCP防火墙设置
    addRollback "setDHCPUfw &>/dev/null || true"
    
    # 启用UFW
    logger -l INFO "Enabling UFW..."
    if ufw --force enable; then
        logger -l SUCCESS "Firewall configured successfully for static mode"
    else
        logger -l CRITICAL "Failed to enable UFW"
        return 1
    fi
}

function setDHCPUfw {
    logger -l INFO "Resetting firewall to DHCP mode state..."
    
    ufw --force reset
    ufw default allow outgoing
    ufw default allow incoming
    ufw --force disable
    
    logger -l SUCCESS "Firewall configured for DHCP mode"
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

#===============================================================================
# 函数名称: showHelp
# 功能描述: 显示脚本帮助信息
# 参数说明: 无
# 返回值:  无
#===============================================================================
function showHelp {
    local script_name=$(basename "$0")
    local script_version="1.0.0"
    local last_update="2026-02-03"
    
    cat << EOF
================================================================================
                              网络配置管理工具
================================================================================

  脚本名称: ${script_name}
  版本信息: v${script_version}
  最后更新: ${last_update}
  脚本作者: Redrock-SRE-2026-Ops-Winter-Assessment

--------------------------------------------------------------------------------
  功能描述:
--------------------------------------------------------------------------------
  本脚本是一个功能强大的网络配置管理工具，主要用于：
  - 网络接口的DHCP和静态IP模式切换
  - 网络连接状态的自动检测与自愈
  - 系统防火墙(UFW)策略配置
  - systemd计时器服务管理，实现周期性网络健康检查
  - 操作失败时自动回滚机制，确保系统稳定性

--------------------------------------------------------------------------------
  使用方法:
--------------------------------------------------------------------------------
  ${script_name} [OPTIONS]

--------------------------------------------------------------------------------
  参数说明:
--------------------------------------------------------------------------------
  -d, --device <名称>        指定网络设备名称 (默认: eth0)
                              示例: ${script_name} --device ens33 --dhcp-mode

  -m, --dhcp-mode            将指定网络设备切换为DHCP自动获取模式
                              设备将从DHCP服务器获取IP地址和DNS配置

  -s, --static-mode          将指定网络设备切换为静态IP模式
                              默认配置: 172.22.146.150/24, 网关: 172.22.146.1
                              DNS服务器: 172.22.146.53, 172.22.146.54

  -c, --self-check           执行网络连通性检查
                              连接到114.114.114.114测试外网连接
                              如果连接失败，自动切换到DHCP模式

  -on, --on-self-check       启用自动网络自检计时器
                              创建systemd timer服务，每分钟执行一次网络检查
                              系统启动1分钟后开始执行

  -off, --off-self-check     禁用自动网络自检计时器
                              停止并删除相关的systemd服务

  -i, --net-info             显示指定网络设备的详细信息
                              包括IP地址、子网掩码、网关、DNS等信息

  -st, --status              显示系统当前状态
                              包括网络设备状态、计时器状态、防火墙状态

  -h, --help                 显示本帮助信息

--------------------------------------------------------------------------------
  使用示例:
--------------------------------------------------------------------------------
  1. 查看帮助信息:
     ${script_name} --help
     ${script_name} -h

  2. 查看网络设备信息:
     ${script_name} --device eth0 --net-info
     ${script_name} -d eth0 -i

  3. 切换到DHCP模式:
     ${script_name} --device eth0 --dhcp-mode
     ${script_name} -d eth0 -m

  4. 切换到静态IP模式:
     ${script_name} --device eth0 --static-mode
     ${script_name} -d eth0 -s

  5. 执行网络连通性检查:
     ${script_name} --device eth0 --self-check
     ${script_name} -d eth0 -c

  6. 启用自动网络自检:
     ${script_name} --device eth0 --on-self-check
     ${script_name} -d eth0 --on

  7. 禁用自动网络自检:
     ${script_name} --device eth0 --off-self-check
     ${script_name} -d eth0 --off

  8. 显示系统当前状态:
     ${script_name} --status
     ${script_name} -st

--------------------------------------------------------------------------------
  注意事项:
--------------------------------------------------------------------------------
  1. 本脚本必须以root权限运行
     使用方式: sudo ${script_name} [OPTIONS]

  2. 运行前会自动检查以下依赖:
     - ifconfig命令 (net-tools包)
     - nmcli命令 (network-manager包)
     - ufw防火墙工具
     - systemd服务管理系统

  3. 所有网络配置变更前会自动备份当前配置
     备份目录: /tmp/network_backup_YYYYMMDD_HHMMSS/
     脚本执行失败时会自动回滚到初始状态

  4. 静态IP模式使用以下默认配置:
     IP地址: 172.22.146.150/24
     网关: 172.22.146.1
     DNS: 172.22.146.53, 172.22.146.54
     如需修改请编辑源码中的setStaticMode函数

  5. 自动网络自检功能:
     默认每分钟检查一次网络连通性
     检测到无法访问外网时自动切换到DHCP模式
     可通过systemctl命令手动管理计时器:
     - 查看状态: systemctl status ${SCRIPT_NAME}.timer
     - 查看日志: journalctl -u ${SCRIPT_NAME}.service -f

--------------------------------------------------------------------------------
  防火墙策略说明 (静态模式):
--------------------------------------------------------------------------------
  - 默认拒绝所有出站连接
  - 允许所有入站连接
  - 允许本地回环接口通信
  - 允许172.22.146.0/24网段通信
  - 允许172.16.0.0/12内部网络通信
  - 允许已建立的连接

================================================================================
EOF
}

#===============================================================================
# 函数名称: showStatus
# 功能描述: 显示系统当前状态
# 参数说明: 无
# 返回值:  无
#===============================================================================
function showStatus {
    logger -l INFO "=========================================="
    logger -l INFO "           系统当前状态"
    logger -l INFO "=========================================="
    echo ""
    
    # 显示网络设备状态
    logger -l INFO "【网络设备状态】"
    echo "----------------------------------------"
    nmcli device status 2>/dev/null || echo "无法获取网络设备状态"
    echo ""
    
    # 显示计时器服务状态
    logger -l INFO "【计时器服务状态】"
    echo "----------------------------------------"
    if systemctl list-unit-files | grep -q "${SCRIPT_NAME}.timer"; then
        echo "计时器服务: ${SCRIPT_NAME}.timer"
        echo ""
        echo "服务状态:"
        systemctl status "${SCRIPT_NAME}.timer" --no-pager -l 2>/dev/null | head -n 15 || echo "无法获取计时器状态"
        echo ""
        echo "定时任务:"
        systemctl list-timers --no-pager 2>/dev/null | grep "${SCRIPT_NAME}" || echo "无定时任务"
    else
        echo "计时器服务未安装"
    fi
    echo ""
    
    # 显示防火墙状态
    logger -l INFO "【防火墙状态】"
    echo "----------------------------------------"
    if which ufw &>/dev/null; then
        ufw status numbered 2>/dev/null || echo "UFW防火墙未激活"
    else
        echo "UFW防火墙未安装"
    fi
    echo ""
    
    # 显示备份目录信息
    logger -l INFO "【备份信息】"
    echo "----------------------------------------"
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "备份目录: $BACKUP_DIR"
        echo "备份文件:"
        ls -lh "$BACKUP_DIR" 2>/dev/null || echo "无备份文件"
    else
        echo "暂无备份信息"
    fi
    echo ""
    
    logger -l SUCCESS "状态显示完成"
}

#===============================================================================
# 函数名称: getNetworkInfo
# 功能描述: 获取并显示指定网络设备的详细信息
# 参数说明: $1 - 网络设备名称（可选，默认获取默认设备）
# 返回值:  0 - 成功, 1 - 失败
#===============================================================================
function getNetworkInfo() {
   local device="${1:-}"
   local connection_name=""
   
   # 如果没有指定设备，获取默认设备
   if [[ -z "$device" ]]; then
       device=$(ip route | grep default | awk '{print $5}' | head -n1)
       if [[ -z "$device" ]]; then
           logger -l ERROR "Could not determine default network device"
           return 1
       fi
   fi
   
   # 获取连接名称
   connection_name=$(nmcli -t -f GENERAL.CONNECTION device show "$device" 2>/dev/null | cut -d: -f2)
   if [[ -z "$connection_name" ]]; then
       logger -l ERROR "Device $device not managed by NetworkManager"
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

   logger -l INFO "Network details for device: $device"
   
   # 打印网络信息表格
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

   # 显示防火墙状态
   logger -l INFO "Firewall status:"
   ufw status verbose
}

function selfCheck {
    local device="$1"
    local test_addr="114.114.114.114"
    
    logger -l INFO "Performing network connectivity check..."
    
    if ping -c 3 -W 2 "$test_addr" &>/dev/null; then
        logger -l SUCCESS "Network connectivity is normal"
        return 0
    else
        logger -l WARNING "Network connectivity test failed, switching to DHCP mode..."
        setDHCPMode "$device"
        setDHCPUfw
    fi
    return 0
}

# 计时器服务
function createSystemdTimer {
    local device="$1"
    
    # 记录原始服务文件状态，用于回滚
    local service_existed=false
    local timer_existed=false
    
    # 检查服务单元文件是否存在，备份原始状态
    if [[ -f "$SERVICE_FILE" ]]; then
        service_existed=true
        backupFile "$SERVICE_FILE"
        logger -l INFO "Backing up existing service file: $SERVICE_FILE"
    fi
    
    # 检查计时器单元文件是否存在，备份原始状态
    if [[ -f "$TIMER_FILE" ]]; then
        timer_existed=true
        backupFile "$TIMER_FILE"
        logger -l INFO "Backing up existing timer file: $TIMER_FILE"
    fi
    
    # service单元内容
    local SERVICE_CONTENT="[Unit]
Description=Network Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --device $device --self-check
StandardOutput=journal
StandardError=journal"

    # timer单元内容
    local TIMER_CONTENT="[Unit]
Description=Run Network Check Every Minute
Requires=${SCRIPT_NAME}.service

[Timer]
OnCalendar=*:*:00
OnBootSec=1min
Persistent=true

[Install]
WantedBy=timers.target"
    
    # 创建服务单元文件
    if [[ "$service_existed" == "false" ]]; then
        logger -l INFO "Creating service unit: $SERVICE_FILE"
        if ! echo "$SERVICE_CONTENT" > "$SERVICE_FILE"; then
            logger -l ERROR "Failed to create service file: $SERVICE_FILE"
            return 1
        fi
        # 添加回滚命令：删除创建的服务文件
        addRollback "rm -f '$SERVICE_FILE' 2>/dev/null || true"
    else
        logger -l INFO "Service file already exists, updating: $SERVICE_FILE"
        if ! echo "$SERVICE_CONTENT" > "$SERVICE_FILE"; then
            logger -l ERROR "Failed to update service file: $SERVICE_FILE"
            return 1
        fi
    fi
    
    # 创建计时器单元文件
    if [[ "$timer_existed" == "false" ]]; then
        logger -l INFO "Creating timer unit: $TIMER_FILE"
        if ! echo "$TIMER_CONTENT" > "$TIMER_FILE"; then
            logger -l ERROR "Failed to create timer file: $TIMER_FILE"
            # 回滚：删除已创建的服务文件
            rm -f "$SERVICE_FILE" 2>/dev/null || true
            return 1
        fi
        # 添加回滚命令：删除创建的计时器文件
        addRollback "rm -f '$TIMER_FILE' 2>/dev/null || true"
    else
        logger -l INFO "Timer file already exists, updating: $TIMER_FILE"
        if ! echo "$TIMER_CONTENT" > "$TIMER_FILE"; then
            logger -l ERROR "Failed to update timer file: $TIMER_FILE"
            return 1
        fi
    fi
    
    # 重新加载systemd守护进程
    logger -l INFO "Reloading systemd daemon..."
    if ! systemctl daemon-reload; then
        logger -l ERROR "Failed to reload systemd daemon"
        return 1
    fi
    
    logger -l SUCCESS "Systemd timer created successfully: $SERVICE_FILE, $TIMER_FILE"
    return 0
}

function startTimer {
    local device="$1"
    
    # 创建计时器服务
    if ! createSystemdTimer "$device"; then
        logger -l ERROR "Failed to create systemd timer"
        return 1
    fi
    
    # 启用并启动计时器
    logger -l INFO "Enabling and starting timer: ${SCRIPT_NAME}.timer"
    
    # 记录当前状态，用于回滚
    local timer_was_enabled=false
    local timer_was_active=false
    
    if systemctl is-enabled "${SCRIPT_NAME}.timer" &>/dev/null; then
        timer_was_enabled=true
    fi
    if systemctl is-active "${SCRIPT_NAME}.timer" &>/dev/null; then
        timer_was_active=true
    fi
    
    # 启用计时器
    if ! systemctl enable "${SCRIPT_NAME}.timer"; then
        logger -l ERROR "Failed to enable timer"
        return 1
    fi
    addRollback "systemctl disable '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    
    # 启动计时器
    if ! systemctl start "${SCRIPT_NAME}.timer"; then
        logger -l ERROR "Failed to start timer"
        # 回滚：禁用计时器
        systemctl disable "${SCRIPT_NAME}.timer" 2>/dev/null || true
        return 1
    fi
    addRollback "systemctl stop '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    
    # 如果计时器原本处于活动或启用状态，添加回滚命令来恢复
    if [[ "$timer_was_active" == "true" ]]; then
        addRollback "systemctl start '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    fi
    if [[ "$timer_was_enabled" == "true" ]]; then
        addRollback "systemctl enable '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    fi
    
    logger -l SUCCESS "Timer started successfully: ${SCRIPT_NAME}.timer"
    
    # 显示当前计时器状态
    logger -l INFO "Timer status:"
    systemctl status "${SCRIPT_NAME}.timer" --no-pager -l 2>/dev/null | head -n 10 || true
    
    return 0
}    

function stopTimer {
    local device="$1"
    logger -l INFO "Stopping timer: ${SCRIPT_NAME}.timer"
    
    # 记录当前计时器状态，用于回滚
    local timer_was_enabled=false
    local timer_was_active=false
    
    # 检查计时器是否处于启用状态
    if systemctl is-enabled "${SCRIPT_NAME}.timer" &>/dev/null; then
        timer_was_enabled=true
        logger -l INFO "Timer was enabled, will restore on rollback"
    fi
    
    # 检查计时器是否处于活动状态
    if systemctl is-active "${SCRIPT_NAME}.timer" &>/dev/null; then
        timer_was_active=true
        logger -l INFO "Timer was active, will restore on rollback"
    fi
    
    # 终止计时器服务
    logger -l INFO "Disabling timer: ${SCRIPT_NAME}.timer"
    systemctl disable "${SCRIPT_NAME}.timer" 2>/dev/null || true
    
    # 停止计时器
    logger -l INFO "Stopping timer: ${SCRIPT_NAME}.timer"
    systemctl stop "${SCRIPT_NAME}.timer" 2>/dev/null || true
    
    # 删除服务单元文件
    if [[ -f "$SERVICE_FILE" ]]; then
        logger -l INFO "Removing service file: $SERVICE_FILE"
        rm -f "$SERVICE_FILE"
        addRollback "rm -f '$SERVICE_FILE' 2>/dev/null || true"
    fi
    
    # 删除计时器单元文件
    if [[ -f "$TIMER_FILE" ]]; then
        logger -l INFO "Removing timer file: $TIMER_FILE"
        rm -f "$TIMER_FILE"
        addRollback "rm -f '$TIMER_FILE' 2>/dev/null || true"
    fi
    
    # 重新加载systemd守护进程
    systemctl daemon-reload 2>/dev/null || true
    
    # 如果计时器原本是启用或活动状态，添加回滚命令来恢复
    if [[ "$timer_was_enabled" == "true" ]]; then
        addRollback "systemctl enable '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    fi
    if [[ "$timer_was_active" == "true" ]]; then
        addRollback "systemctl start '${SCRIPT_NAME}.timer' 2>/dev/null || true"
    fi
    
    logger -l SUCCESS "Timer stopped successfully: ${SCRIPT_NAME}.timer"
    return 0
}

#===============================================================================
# 函数名称: main
# 功能描述: 脚本主函数，处理命令行参数并执行相应操作
# 参数说明: $@ - 命令行参数列表
# 返回值:  0 - 成功, 非0 - 失败
#===============================================================================
function main {
    local device="eth0"
    local action=""
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # 指定网络设备
            -d|--device)
                if [[ -z "$2" || "$2" == -* ]]; then
                    logger -l ERROR "选项 --device 需要一个参数: <设备名称>"
                    showHelp
                    return 1
                fi
                device="$2"
                shift 2
                ;;
            
            # DHCP模式
            -m|--dhcp-mode)
                action="dhcp-mode"
                shift
                ;;
            
            # 静态IP模式
            -s|--static-mode)
                action="static-mode"
                shift
                ;;
            
            # 网络自检
            -c|--self-check)
                action="self-check"
                shift
                ;;
            
            # 启用自动自检计时器
            -on|--on-self-check)
                action="on-self-check"
                shift
                ;;
            
            # 禁用自动自检计时器
            -off|--off-self-check)
                action="off-self-check"
                shift
                ;;
            
            # 显示网络信息
            -i|--net-info)
                action="net-info"
                shift
                ;;
            
            # 显示系统状态
            -st|--status)
                action="status"
                shift
                ;;
            
            # 显示帮助信息
            -h|--help)
                showHelp
                return 0
                ;;
            
            # 未知参数
            *)
                logger -l ERROR "未知的选项: $1"
                showHelp
                return 1
                ;;
        esac
    done
    
    # 初始化备份目录
    initBackup
    
    # 执行环境检查
    checkRoot || return 1
    checkEnv || return 1
    
    # 备份当前配置
    backupCurrentConfig "$device"
    
    # 执行指定操作
    case "$action" in
        "dhcp-mode")
            logger -l INFO "正在切换到DHCP模式..."
            checkEthDevices "$device" || return 1
            setDHCPMode "$device"
            setDHCPUfw
            getNetworkInfo "$device"
            ;;
        
        "static-mode")
            logger -l INFO "正在切换到静态IP模式..."
            checkEthDevices "$device" || return 1
            setStaticMode "$device"
            setStaticUfw
            getNetworkInfo "$device"
            ;;
        
        "self-check")
            logger -l INFO "正在执行网络连通性检查..."
            checkEthDevices "$device" || return 1
            selfCheck "$device"
            ;;
        
        "on-self-check")
            logger -l INFO "正在启用自动网络自检计时器..."
            checkEthDevices "$device" || return 1
            startTimer "$device"
            ;;
        
        "off-self-check")
            logger -l INFO "正在禁用自动网络自检计时器..."
            checkEthDevices "$device" || return 1
            stopTimer "$device"
            ;;
        
        "net-info")
            logger -l INFO "正在获取网络信息..."
            getNetworkInfo "$device"
            ;;
        
        "status")
            logger -l INFO "正在显示系统状态..."
            showStatus
            ;;
        
        "")
            logger -l INFO "未指定操作选项，显示帮助信息..."
            showHelp
            ;;
    esac
    
    logger -l SUCCESS "脚本执行完成"
    return 0
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