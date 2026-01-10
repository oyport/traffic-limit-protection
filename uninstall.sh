#!/bin/bash
#================================================================
# 超流量保护系统 - 卸载脚本
# Traffic Limit Protection System - Uninstall Script
# Version: 1.0.0
#================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置路径
INSTALL_DIR="/usr/local/bin"
CONFIG_FILE="/etc/tx-monitor.conf"
LOG_FILE="/var/log/tx-monitor.log"
AUDIT_LOG="/var/log/tx-monitor-audit.log"
ENABLE_FLAG="/run/tx-monitor.enabled"
SOFT_BLOCK_FLAG="/run/tx-monitor.soft-block"
HARD_BLOCK_FLAG="/run/tx-monitor.hard-block"
LAST_ACTION_FILE="/run/tx-monitor.last-action"
IPTABLES_CHAIN="TX_MONITOR_BLOCK"

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
# 权限检查
#================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        echo "使用: sudo bash uninstall.sh"
        exit 1
    fi
}

#================================================================
# 确认卸载
#================================================================

confirm_uninstall() {
    print_header "超流量保护系统 - 卸载向导"
    
    print_warning "即将卸载超流量保护系统"
    echo ""
    echo "将执行以下操作:"
    echo "  1. 停止流量监控"
    echo "  2. 清除防火墙规则"
    echo "  3. 删除 Cron 任务"
    echo "  4. 删除系统脚本"
    echo "  5. 删除配置文件 (可选)"
    echo "  6. 删除日志文件 (可选)"
    echo ""
    
    echo -n "确认卸载? (yes/no): "
    read -r confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消卸载"
        exit 0
    fi
}

#================================================================
# 停止监控
#================================================================

stop_monitoring() {
    print_header "停止流量监控"
    
    if [ -f "$ENABLE_FLAG" ]; then
        rm -f "$ENABLE_FLAG"
        print_success "监控已停止"
    else
        print_info "监控未启用"
    fi
    
    # 清除标记文件
    rm -f "$SOFT_BLOCK_FLAG" "$HARD_BLOCK_FLAG" "$LAST_ACTION_FILE"
}

#================================================================
# 清除防火墙规则
#================================================================

cleanup_firewall() {
    print_header "清除防火墙规则"
    
    # 加载配置获取网卡名
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 清除自定义链
    if iptables -L "$IPTABLES_CHAIN" -n &>/dev/null; then
        print_info "清除 iptables 规则..."
        
        # 从 OUTPUT 链中移除
        if [ -n "$INTERFACE" ]; then
            iptables -D OUTPUT -o "$INTERFACE" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        fi
        
        # 清空并删除链
        iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
        iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
        
        print_success "iptables 规则已清除"
    else
        print_info "无需清除 iptables 规则"
    fi
    
    # 重置 OUTPUT 策略
    if iptables -L OUTPUT -n | grep -q "policy DROP"; then
        print_info "重置 OUTPUT 链策略..."
        iptables -P OUTPUT ACCEPT
        print_success "OUTPUT 策略已重置为 ACCEPT"
    fi
    
    # 重新启用网卡
    if [ -n "$INTERFACE" ]; then
        if ! ip link show "$INTERFACE" | grep -q "state UP"; then
            print_info "重新启用网卡 $INTERFACE..."
            ip link set "$INTERFACE" up 2>/dev/null || true
            print_success "网卡已重新启用"
        fi
    fi
}

#================================================================
# 删除 Cron 任务
#================================================================

remove_cron() {
    print_header "删除定时任务"
    
    if crontab -l 2>/dev/null | grep -q "tx-monitor.sh"; then
        print_info "删除 cron 任务..."
        crontab -l 2>/dev/null | grep -v "tx-monitor.sh" | crontab -
        print_success "Cron 任务已删除"
    else
        print_info "无 cron 任务需要删除"
    fi
}

#================================================================
# 删除系统脚本
#================================================================

remove_scripts() {
    print_header "删除系统脚本"
    
    local removed=0
    
    if [ -f "$INSTALL_DIR/tx-monitor.sh" ]; then
        rm -f "$INSTALL_DIR/tx-monitor.sh"
        print_success "已删除: tx-monitor.sh"
        removed=1
    fi
    
    if [ -f "$INSTALL_DIR/tx-ctl" ]; then
        rm -f "$INSTALL_DIR/tx-ctl"
        print_success "已删除: tx-ctl"
        removed=1
    fi
    
    if [ $removed -eq 0 ]; then
        print_info "无系统脚本需要删除"
    fi
}

#================================================================
# 删除配置和日志
#================================================================

remove_config_and_logs() {
    print_header "删除配置和日志"
    
    # 备份选项
    echo -n "是否备份配置文件? (y/n) [默认: y]: "
    read -r backup_config
    backup_config=${backup_config:-y}
    
    if [ -f "$CONFIG_FILE" ]; then
        if [ "$backup_config" = "y" ]; then
            backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$CONFIG_FILE" "$backup_file"
            print_info "配置已备份到: $backup_file"
        fi
        rm -f "$CONFIG_FILE"
        print_success "配置文件已删除"
    fi
    
    # 日志文件
    echo -n "是否删除日志文件? (y/n) [默认: n]: "
    read -r remove_logs
    remove_logs=${remove_logs:-n}
    
    if [ "$remove_logs" = "y" ]; then
        if [ -f "$LOG_FILE" ]; then
            rm -f "$LOG_FILE"
            print_success "日志文件已删除"
        fi
        if [ -f "$AUDIT_LOG" ]; then
            rm -f "$AUDIT_LOG"
            print_success "审计日志已删除"
        fi
        
        # 删除旧日志
        rm -f "${LOG_FILE}.old" 2>/dev/null || true
    else
        print_info "保留日志文件"
    fi
}

#================================================================
# 卸载依赖 (可选)
#================================================================

remove_dependencies() {
    print_header "卸载依赖包"
    
    echo -n "是否卸载 vnstat 和 jq? (y/n) [默认: n]: "
    read -r remove_deps
    remove_deps=${remove_deps:-n}
    
    if [ "$remove_deps" != "y" ]; then
        print_info "保留依赖包"
        return
    fi
    
    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        REMOVE_CMD="apt-get remove -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        REMOVE_CMD="yum remove -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        REMOVE_CMD="dnf remove -y"
    else
        print_warning "未找到包管理器，跳过依赖卸载"
        return
    fi
    
    print_warning "注意: 这些包可能被其他程序使用"
    echo -n "确认卸载 vnstat 和 jq? (yes/no): "
    read -r confirm_deps
    
    if [ "$confirm_deps" = "yes" ]; then
        print_info "卸载 vnstat..."
        eval $REMOVE_CMD vnstat 2>/dev/null || true
        
        print_info "卸载 jq..."
        eval $REMOVE_CMD jq 2>/dev/null || true
        
        print_success "依赖包已卸载"
    fi
}

#================================================================
# 完成卸载
#================================================================

finish_uninstall() {
    print_header "卸载完成"
    
    print_success "超流量保护系统已完全卸载"
    
    echo ""
    print_info "已删除的组件:"
    echo "  ✓ 流量监控服务"
    echo "  ✓ 防火墙规则"
    echo "  ✓ 定时任务"
    echo "  ✓ 系统脚本"
    
    if [ -f "$CONFIG_FILE.backup."* ] 2>/dev/null; then
        echo ""
        print_info "配置文件已备份，如需重新安装可使用备份配置"
    fi
    
    echo ""
    print_info "感谢使用超流量保护系统!"
}

#================================================================
# 主函数
#================================================================

main() {
    clear
    check_root
    confirm_uninstall
    
    stop_monitoring
    cleanup_firewall
    remove_cron
    remove_scripts
    remove_config_and_logs
    remove_dependencies
    
    finish_uninstall
    
    echo ""
}

# 运行主函数
main
