#!/bin/bash
#================================================================
# 超流量保护系统 - 一键安装脚本
# Traffic Limit Protection System - Installation Script
# Version: 1.0.0
# Date: 2026-01-07
#================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/tx-monitor.conf"
LOG_FILE="/var/log/tx-monitor.log"
AUDIT_LOG="/var/log/tx-monitor-audit.log"

#================================================================
# 工具函数
#================================================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

#================================================================
# 系统检查
#================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        echo "使用: sudo bash install.sh"
        exit 1
    fi
    print_success "Root 权限检查通过"
}

check_system() {
    print_info "检查系统兼容性..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        print_info "检测到系统: $NAME $VERSION"
        
        # 检查是否为支持的系统
        case "$ID" in
            ubuntu|debian|centos|rhel|fedora|rocky|almalinux)
                print_success "系统兼容性检查通过"
                ;;
            *)
                print_warning "未测试的系统: $ID"
                echo -n "是否继续安装? (y/n): "
                read -r continue_install
                if [ "$continue_install" != "y" ]; then
                    exit 0
                fi
                ;;
        esac
    else
        print_warning "无法检测系统版本，继续安装"
    fi
}

check_existing_install() {
    if [ -f "$CONFIG_FILE" ] || [ -f "$INSTALL_DIR/tx-monitor.sh" ]; then
        print_warning "检测到已安装的版本"
        echo -n "是否覆盖安装? (y/n): "
        read -r overwrite
        if [ "$overwrite" != "y" ]; then
            print_info "安装已取消"
            exit 0
        fi
        
        # 备份旧配置
        if [ -f "$CONFIG_FILE" ]; then
            backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$backup_file"
            print_info "旧配置已备份到: $backup_file"
        fi
    fi
}

#================================================================
# 依赖安装
#================================================================

install_epel_if_needed() {
    # 为 CentOS/RHEL 安装 EPEL 仓库
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        
        if [[ "$ID" =~ ^(centos|rhel)$ ]]; then
            if ! rpm -qa | grep -q epel-release; then
                print_info "检测到 $ID，安装 EPEL 仓库..."
                
                if [ "$VERSION_ID" = "7" ]; then
                    yum install -y epel-release || {
                        print_warning "EPEL 安装失败，尝试手动下载..."
                        yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
                    }
                elif [ "$VERSION_ID" = "8" ]; then
                    dnf install -y epel-release
                else
                    print_warning "未知的版本，跳过 EPEL 安装"
                fi
                
                print_success "EPEL 仓库已安装"
            else
                print_success "EPEL 仓库已存在"
            fi
        fi
    fi
}

install_dependencies() {
    print_header "安装依赖包"
    
    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        UPDATE_CMD="apt-get update"
        INSTALL_CMD="apt-get install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        UPDATE_CMD="yum check-update || true"
        INSTALL_CMD="yum install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        UPDATE_CMD="dnf check-update || true"
        INSTALL_CMD="dnf install -y"
    else
        print_error "不支持的包管理器"
        exit 1
    fi
    
    print_info "使用包管理器: $PKG_MANAGER"
    
    # 安装 EPEL (如果需要)
    install_epel_if_needed
    
    # 更新包列表
    print_info "更新软件包列表..."
    eval $UPDATE_CMD
    
    # 安装 vnstat
    if ! command -v vnstat &> /dev/null; then
        print_info "安装 vnstat..."
        eval $INSTALL_CMD vnstat
        print_success "vnstat 安装完成"
    else
        print_success "vnstat 已安装"
    fi
    
    # 安装 jq
    if ! command -v jq &> /dev/null; then
        print_info "安装 jq..."
        eval $INSTALL_CMD jq
        print_success "jq 安装完成"
    else
        print_success "jq 已安装"
    fi
    
    # 检查 iptables
    if ! command -v iptables &> /dev/null; then
        print_info "安装 iptables..."
        eval $INSTALL_CMD iptables
        print_success "iptables 安装完成"
    else
        print_success "iptables 已安装"
    fi
}

#================================================================
# 网卡检测
#================================================================

detect_interfaces() {
    print_header "检测网络接口"
    
    # 获取所有非虚拟网卡
    interfaces=()
    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $2}' | sed 's/:$//')
        # 排除 lo、docker、veth 等虚拟接口
        if [[ ! "$iface" =~ ^(lo|docker|veth|br-|virbr) ]]; then
            interfaces+=("$iface")
        fi
    done < <(ip -o link show | grep -v "link/loopback")
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        print_error "未检测到可用的网络接口"
        exit 1
    fi
    
    print_info "检测到以下网络接口:"
    for i in "${!interfaces[@]}"; do
        echo "  $((i+1)). ${interfaces[$i]}"
    done
    
    echo ""
    if [ ${#interfaces[@]} -eq 1 ]; then
        SELECTED_INTERFACE="${interfaces[0]}"
        print_info "自动选择: $SELECTED_INTERFACE"
    else
        echo -n "请选择要监控的网卡 (1-${#interfaces[@]}): "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#interfaces[@]} ]; then
            SELECTED_INTERFACE="${interfaces[$((selection-1))]}"
            print_success "已选择: $SELECTED_INTERFACE"
        else
            print_error "无效的选择"
            exit 1
        fi
    fi
}

#================================================================
# 初始化 vnstat
#================================================================

ensure_vnstat_service() {
    # 确保 vnstat 服务在系统启动时自动运行
    print_info "配置 vnstat 服务..."
    
    # 检测系统使用 systemd 还是 init
    if command -v systemctl &> /dev/null; then
        # systemd 系统
        if systemctl list-unit-files | grep -q vnstat; then
            systemctl enable vnstat 2>/dev/null || true
            systemctl start vnstat 2>/dev/null || true
            
            if systemctl is-active vnstat &>/dev/null; then
                print_success "vnstat 服务已启用并运行"
            else
                print_warning "vnstat 服务启动失败，尝试手动模式"
                vnstatd -d 2>/dev/null || true
            fi
        else
            print_warning "未找到 vnstat systemd 服务，使用守护进程模式"
            vnstatd -d 2>/dev/null || true
        fi
    elif command -v service &> /dev/null; then
        # SysV init 系统
        if [ -f /etc/init.d/vnstat ]; then
            chkconfig vnstat on 2>/dev/null || update-rc.d vnstat defaults 2>/dev/null || true
            service vnstat start 2>/dev/null || true
            print_success "vnstat 服务已配置 (SysV init)"
        else
            print_warning "使用 vnstat 守护进程模式"
            vnstatd -d 2>/dev/null || true
        fi
    else
        # 直接启动守护进程
        print_warning "未检测到服务管理器，使用守护进程模式"
        vnstatd -d 2>/dev/null || true
    fi
}

init_vnstat() {
    print_header "初始化 vnstat"
    
    # 初始化选定的网卡
    print_info "初始化网卡: $SELECTED_INTERFACE"
    vnstat -i "$SELECTED_INTERFACE" --add 2>/dev/null || true
    
    # 确保 vnstat 服务运行
    ensure_vnstat_service
    
    # 等待 vnstat 收集数据
    sleep 3
    
    # 验证 vnstat
    if vnstat -i "$SELECTED_INTERFACE" &> /dev/null; then
        print_success "vnstat 初始化成功"
        
        # 显示当前数据（如果有）
        local tx_bytes=$(vnstat -i "$SELECTED_INTERFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.month[0].tx' 2>/dev/null || echo "0")
        if [ "$tx_bytes" != "0" ] && [ -n "$tx_bytes" ]; then
            local tx_mb=$(( tx_bytes / 1000000 ))
            print_info "当前月度流量: ${tx_mb} MB"
        else
            print_info "vnstat 正在收集数据，请稍后查看统计"
        fi
    else
        print_warning "vnstat 数据尚未准备好，可能需要等待几分钟"
        print_info "您可以稍后使用 'vnstat -i $SELECTED_INTERFACE' 查看统计"
    fi
}

#================================================================
# 交互式配置
#================================================================

interactive_config() {
    print_header "交互式配置"
    
    # 流量阈值
    echo -n "请设置月流量阈值 (MB) [默认: 20000]: "
    read -r threshold
    THRESHOLD_MB=${threshold:-20000}
    
    # 检查间隔
    echo -n "检查间隔 (分钟) [默认: 10]: "
    read -r interval
    CHECK_INTERVAL=${interval:-10}
    
    # 警告级别
    echo ""
    print_info "设置分级预警阈值 (百分比):"
    echo -n "  第一级警告 [默认: 80]: "
    read -r warn1
    WARNING_LEVEL_1=${warn1:-80}
    
    echo -n "  第二级警告(软阻断) [默认: 90]: "
    read -r warn2
    WARNING_LEVEL_2=${warn2:-90}
    
    echo -n "  第三级警告(硬阻断) [默认: 95]: "
    read -r warn3
    WARNING_LEVEL_3=${warn3:-95}
    
    # 响应动作配置
    echo ""
    print_info "配置响应动作:"
    echo "  可选动作: block_ports(阻断端口) / disable_interface(禁用网卡) / alert(仅警告)"
    
    echo -n "  达到 ${WARNING_LEVEL_2}% 时的动作 [默认: block_ports]: "
    read -r action90
    ACTION_AT_90=${action90:-block_ports}
    
    echo -n "  达到 ${WARNING_LEVEL_3}% 时的动作 [默认: disable_interface]: "
    read -r action95
    ACTION_AT_95=${action95:-disable_interface}
    
    echo ""
    echo -n "  达到 100% 时是否关机? (y/n) [默认: n]: "
    read -r shutdown_opt
    if [ "$shutdown_opt" = "y" ]; then
        ACTION_AT_100="shutdown"
    else
        ACTION_AT_100="none"
    fi
    
    # 白名单端口
    echo ""
    echo -n "保留的端口 (逗号分隔，通常保留SSH) [默认: 22]: "
    read -r whitelist
    WHITELIST_PORTS=${whitelist:-22}
    
    # 需要阻断的高流量端口
    echo -n "优先阻断的端口 (逗号分隔) [默认: 80,443,8080]: "
    read -r blocklist
    BLOCK_PORTS=${blocklist:-80,443,8080}
    
    # 通知配置
    echo ""
    echo -n "是否启用邮件通知? (y/n) [默认: n]: "
    read -r enable_notif
    if [ "$enable_notif" = "y" ]; then
        ENABLE_NOTIFICATIONS="true"
        echo -n "通知邮箱地址: "
        read -r email
        NOTIFICATION_EMAIL="$email"
    else
        ENABLE_NOTIFICATIONS="false"
        NOTIFICATION_EMAIL=""
    fi
    
    # 显示配置摘要
    echo ""
    print_header "配置摘要"
    echo "  监控网卡: $SELECTED_INTERFACE"
    echo "  流量阈值: ${THRESHOLD_MB} MB"
    echo "  检查间隔: ${CHECK_INTERVAL} 分钟"
    echo "  预警级别: ${WARNING_LEVEL_1}% / ${WARNING_LEVEL_2}% / ${WARNING_LEVEL_3}%"
    echo "  ${WARNING_LEVEL_2}% 动作: $ACTION_AT_90"
    echo "  ${WARNING_LEVEL_3}% 动作: $ACTION_AT_95"
    echo "  100% 动作: $ACTION_AT_100"
    echo "  保留端口: $WHITELIST_PORTS"
    echo "  阻断端口: $BLOCK_PORTS"
    echo ""
    
    echo -n "确认配置并继续? (y/n): "
    read -r confirm
    if [ "$confirm" != "y" ]; then
        print_info "安装已取消"
        exit 0
    fi
}

#================================================================
# 创建配置文件
#================================================================

create_config() {
    print_header "创建配置文件"
    
    cat > "$CONFIG_FILE" <<EOF
#================================================================
# 超流量保护系统 - 配置文件
# Traffic Limit Protection System - Configuration
# Generated: $(date)
#================================================================

# 基础配置
INTERFACE="$SELECTED_INTERFACE"
THRESHOLD_MB=$THRESHOLD_MB
CHECK_INTERVAL=$CHECK_INTERVAL

# 分级响应配置
WARNING_LEVEL_1=$WARNING_LEVEL_1
WARNING_LEVEL_2=$WARNING_LEVEL_2
WARNING_LEVEL_3=$WARNING_LEVEL_3
CRITICAL_LEVEL=100

# 响应动作配置
# 可选值: block_ports / disable_interface / alert / none
ACTION_AT_90="$ACTION_AT_90"
ACTION_AT_95="$ACTION_AT_95"
ACTION_AT_100="$ACTION_AT_100"

# 端口配置
WHITELIST_PORTS="$WHITELIST_PORTS"
BLOCK_PORTS="$BLOCK_PORTS"

# 通知配置
ENABLE_NOTIFICATIONS=$ENABLE_NOTIFICATIONS
NOTIFICATION_EMAIL="$NOTIFICATION_EMAIL"
WEBHOOK_URL=""

# 安全配置
REQUIRE_MANUAL_ENABLE=true
AUTO_RECOVERY_HOURS=0

# 高级配置
COOLDOWN_MINUTES=30
WHITELIST_IPS=""
MAX_LOG_SIZE_MB=100
EOF

    chmod 644 "$CONFIG_FILE"
    print_success "配置文件已创建: $CONFIG_FILE"
}

#================================================================
# 安装脚本文件
#================================================================

install_scripts() {
    print_header "安装系统脚本"
    
    # 获取当前脚本所在目录
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # 安装监控脚本
    if [ -f "$SCRIPT_DIR/tx-monitor.sh" ]; then
        cp "$SCRIPT_DIR/tx-monitor.sh" "$INSTALL_DIR/tx-monitor.sh"
        chmod +x "$INSTALL_DIR/tx-monitor.sh"
        print_success "已安装: tx-monitor.sh"
    else
        print_error "未找到 tx-monitor.sh"
        exit 1
    fi
    
    # 安装管理工具
    if [ -f "$SCRIPT_DIR/tx-ctl" ]; then
        cp "$SCRIPT_DIR/tx-ctl" "$INSTALL_DIR/tx-ctl"
        chmod +x "$INSTALL_DIR/tx-ctl"
        print_success "已安装: tx-ctl"
    else
        print_error "未找到 tx-ctl"
        exit 1
    fi
    
    # 创建日志文件
    touch "$LOG_FILE"
    touch "$AUDIT_LOG"
    chmod 644 "$LOG_FILE"
    chmod 644 "$AUDIT_LOG"
    print_success "日志文件已创建"
}

#================================================================
# 配置 Cron 任务
#================================================================

setup_cron() {
    print_header "配置定时任务"
    
    # 检查是否已存在 cron 任务
    if crontab -l 2>/dev/null | grep -q "tx-monitor.sh"; then
        print_info "删除旧的 cron 任务..."
        crontab -l 2>/dev/null | grep -v "tx-monitor.sh" | crontab -
    fi
    
    # 添加新的 cron 任务
    (crontab -l 2>/dev/null; echo "*/$CHECK_INTERVAL * * * * $INSTALL_DIR/tx-monitor.sh >/dev/null 2>&1") | crontab -
    
    print_success "Cron 任务已配置 (每 ${CHECK_INTERVAL} 分钟执行)"
}

#================================================================
# 完成安装
#================================================================

finish_install() {
    print_header "安装完成"
    
    print_success "超流量保护系统安装成功!"
    echo ""
    echo "配置文件: $CONFIG_FILE"
    echo "日志文件: $LOG_FILE"
    echo "审计日志: $AUDIT_LOG"
    echo ""
    
    print_info "快速开始:"
    echo "  启用监控:   sudo tx-ctl enable"
    echo "  查看状态:   sudo tx-ctl status"
    echo "  流量统计:   sudo tx-ctl stats"
    echo "  系统诊断:   sudo tx-ctl doctor"
    echo "  查看日志:   sudo tx-ctl logs"
    echo "  禁用监控:   sudo tx-ctl disable"
    echo "  解除阻断:   sudo tx-ctl unblock"
    echo ""
    
    print_warning "重要提示:"
    echo "  1. 系统默认为禁用状态，需手动启用"
    echo "  2. 启用后会开始监控流量"
    echo "  3. 系统重启后会自动禁用，需重新启用 (安全设计)"
    echo "  4. vnstat 服务已配置为开机自启"
    echo "  5. 建议先使用 'tx-ctl test' 测试配置"
    echo "  6. 建议运行 'tx-ctl doctor' 检查系统健康状态"
    echo ""
    
    echo -n "是否现在启用监控? (y/n): "
    read -r enable_now
    if [ "$enable_now" = "y" ]; then
        $INSTALL_DIR/tx-ctl enable
    else
        print_info "稍后可使用 'sudo tx-ctl enable' 启用监控"
    fi
}

#================================================================
# 主函数
#================================================================

main() {
    clear
    print_header "超流量保护系统 - 安装向导"
    echo "Traffic Limit Protection System Installer"
    echo "Version: 1.0.0"
    echo ""
    
    check_root
    check_system
    check_existing_install
    
    install_dependencies
    detect_interfaces
    init_vnstat
    interactive_config
    create_config
    install_scripts
    setup_cron
    finish_install
    
    echo ""
    print_success "安装流程全部完成!"
}

# 运行主函数
main
