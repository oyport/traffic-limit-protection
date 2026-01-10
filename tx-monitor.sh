#!/bin/bash
#================================================================
# 超流量保护系统 - 核心监控脚本
# Traffic Limit Protection System - Monitor Script
# Version: 1.0.0
#================================================================

# 配置文件路径
CONFIG_FILE="/etc/tx-monitor.conf"
LOG_FILE="/var/log/tx-monitor.log"
AUDIT_LOG="/var/log/tx-monitor-audit.log"
ENABLE_FLAG="/run/tx-monitor.enabled"
SOFT_BLOCK_FLAG="/run/tx-monitor.soft-block"
HARD_BLOCK_FLAG="/run/tx-monitor.hard-block"
LAST_ACTION_FILE="/run/tx-monitor.last-action"

# 防火墙链名
IPTABLES_CHAIN="TX_MONITOR_BLOCK"

#================================================================
# 工具函数
#================================================================

log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

audit_log() {
    local action="$1"
    local details="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ACTION=$action | DETAILS=$details | USER=$(whoami)" >> "$AUDIT_LOG"
}

rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(du -m "$LOG_FILE" | cut -f1)
        local max_size=${MAX_LOG_SIZE_MB:-100}
        
        if [ "$log_size" -gt "$max_size" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            touch "$LOG_FILE"
            log_message "INFO" "Log rotated (size: ${log_size}MB)"
        fi
    fi
}

#================================================================
# 启用检查
#================================================================

check_enabled() {
    if [ ! -f "$ENABLE_FLAG" ]; then
        exit 0
    fi
    return 0
}

#================================================================
# vnstat 服务检查
#================================================================

check_vnstat_service() {
    # 检查 vnstat 是否运行
    local vnstat_running=false
    
    # 检查 systemd 服务
    if command -v systemctl &> /dev/null; then
        if systemctl is-active vnstat &>/dev/null; then
            vnstat_running=true
        fi
    fi
    
    # 检查进程
    if ! $vnstat_running; then
        if pgrep vnstatd &>/dev/null; then
            vnstat_running=true
        fi
    fi
    
    # 如果未运行，尝试启动
    if ! $vnstat_running; then
        log_message "WARN" "vnstat service not running, attempting to start..."
        
        if command -v systemctl &> /dev/null; then
            systemctl start vnstat 2>/dev/null || vnstatd -d 2>/dev/null || true
        else
            service vnstat start 2>/dev/null || vnstatd -d 2>/dev/null || true
        fi
        
        sleep 2
        
        # 再次检查
        if systemctl is-active vnstat &>/dev/null || pgrep vnstatd &>/dev/null; then
            log_message "INFO" "vnstat service started successfully"
        else
            log_message "ERROR" "Failed to start vnstat service"
            return 1
        fi
    fi
    
    return 0
}

#================================================================
# 加载配置
#================================================================

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "ERROR" "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # 加载配置文件
    source "$CONFIG_FILE"
    
    # 验证必需的配置项
    if [ -z "$INTERFACE" ] || [ -z "$THRESHOLD_MB" ]; then
        log_message "ERROR" "Invalid configuration: INTERFACE or THRESHOLD_MB not set"
        exit 1
    fi
}

#================================================================
# 检查必需的命令
#================================================================

check_required_commands() {
    local missing_cmds=()
    
    # 检查 iptables
    if ! command -v iptables &> /dev/null; then
        missing_cmds+=("iptables")
    fi
    
    # 检查 vnstat
    if ! command -v vnstat &> /dev/null; then
        missing_cmds+=("vnstat")
    fi
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        missing_cmds+=("jq")
    fi
    
    if [ ${#missing_cmds[@]} -gt 0 ]; then
        log_message "ERROR" "Missing required commands: ${missing_cmds[*]}"
        log_message "ERROR" "Please install: apt-get install ${missing_cmds[*]} or yum install ${missing_cmds[*]}"
        return 1
    fi
    
    return 0
}

#================================================================
# 获取流量数据
#================================================================

get_traffic() {
    # 从 vnstat 获取本月流出流量 (字节)
    local tx_bytes=$(vnstat -i "$INTERFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.month[0].tx' 2>/dev/null)
    
    # 验证数据有效性
    if [ -z "$tx_bytes" ] || ! [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
        log_message "WARN" "Failed to get valid TX data for $INTERFACE (got: '$tx_bytes')"
        echo "0"
        return 1
    fi
    
    # 转换为 MB
    local tx_mb=$(( tx_bytes / 1000000 ))
    echo "$tx_mb"
}

#================================================================
# 计算使用百分比
#================================================================

calculate_usage_percent() {
    local current_mb=$1
    local threshold_mb=$2
    
    if [ "$threshold_mb" -eq 0 ]; then
        echo "0"
        return
    fi
    
    local percent=$(( current_mb * 100 / threshold_mb ))
    echo "$percent"
}

#================================================================
# 通知功能
#================================================================

send_notification() {
    local level="$1"
    local message="$2"
    
    if [ "$ENABLE_NOTIFICATIONS" != "true" ]; then
        return
    fi
    
    # 邮件通知
    if [ -n "$NOTIFICATION_EMAIL" ] && command -v mail &> /dev/null; then
        echo "$message" | mail -s "流量监控告警: $level" "$NOTIFICATION_EMAIL" 2>/dev/null || true
    fi
    
    # Webhook 通知
    if [ -n "$WEBHOOK_URL" ] && command -v curl &> /dev/null; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"level\":\"$level\",\"message\":\"$message\",\"time\":\"$(date)\"}" \
            2>/dev/null || true
    fi
}

#================================================================
# 防火墙规则管理
#================================================================

cleanup_iptables_rules() {
    # 删除自定义链
    if iptables -L "$IPTABLES_CHAIN" -n &>/dev/null; then
        # 从 OUTPUT 链中移除引用
        iptables -D OUTPUT -o "$INTERFACE" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        
        # 清空并删除自定义链
        iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
        iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
        
        log_message "INFO" "Cleaned up iptables rules"
        audit_log "CLEANUP_RULES" "Removed iptables chain: $IPTABLES_CHAIN"
    fi
}

apply_soft_block() {
    log_message "WARN" "Applying SOFT BLOCK - preserving SSH and whitelisted ports"
    audit_log "SOFT_BLOCK" "Interface=$INTERFACE, Whitelist=$WHITELIST_PORTS, Block=$BLOCK_PORTS"
    
    # 清理旧规则
    cleanup_iptables_rules
    
    # 创建自定义链
    iptables -N "$IPTABLES_CHAIN" 2>/dev/null || iptables -F "$IPTABLES_CHAIN"
    
    # 允许白名单端口
    IFS=',' read -ra PORTS <<< "$WHITELIST_PORTS"
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | xargs) # 去除空格
        if [ -n "$port" ]; then
            iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j ACCEPT
            iptables -A "$IPTABLES_CHAIN" -p udp --dport "$port" -j ACCEPT
            log_message "INFO" "Whitelisted port: $port"
        fi
    done
    
    # 允许白名单IP
    if [ -n "$WHITELIST_IPS" ]; then
        IFS=',' read -ra IPS <<< "$WHITELIST_IPS"
        for ip in "${IPS[@]}"; do
            ip=$(echo "$ip" | xargs)
            if [ -n "$ip" ]; then
                iptables -A "$IPTABLES_CHAIN" -d "$ip" -j ACCEPT
                log_message "INFO" "Whitelisted IP: $ip"
            fi
        done
    fi
    
    # 阻断高流量端口
    IFS=',' read -ra PORTS <<< "$BLOCK_PORTS"
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | xargs)
        if [ -n "$port" ]; then
            iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j DROP
            iptables -A "$IPTABLES_CHAIN" -p udp --dport "$port" -j DROP
            log_message "INFO" "Blocked port: $port"
        fi
    done
    
    # 默认丢弃其他流量
    iptables -A "$IPTABLES_CHAIN" -j DROP
    
    # 应用到 OUTPUT 链
    iptables -I OUTPUT -o "$INTERFACE" -j "$IPTABLES_CHAIN"
    
    # 创建标记文件
    touch "$SOFT_BLOCK_FLAG"
    echo "$(date)" > "$LAST_ACTION_FILE"
    
    log_message "WARN" "SOFT BLOCK applied successfully"
    send_notification "SOFT BLOCK" "流量使用达到警戒线，已阻断非必要端口。SSH端口 $WHITELIST_PORTS 保持开放。"
}

apply_hard_block() {
    log_message "CRITICAL" "Applying HARD BLOCK"
    audit_log "HARD_BLOCK" "Interface=$INTERFACE, Action=$ACTION_AT_95"
    
    if [ "$ACTION_AT_95" = "disable_interface" ]; then
        # 禁用网卡
        ip link set "$INTERFACE" down
        log_message "CRITICAL" "Interface $INTERFACE disabled"
        send_notification "HARD BLOCK" "流量严重超限，网卡 $INTERFACE 已禁用。需手动恢复。"
    else
        # 阻断所有流量（保留本地环回）
        iptables -P OUTPUT DROP
        iptables -A OUTPUT -o lo -j ACCEPT
        log_message "CRITICAL" "All traffic blocked except localhost"
        send_notification "HARD BLOCK" "流量严重超限，所有网络流量已阻断。"
    fi
    
    touch "$HARD_BLOCK_FLAG"
    echo "$(date)" > "$LAST_ACTION_FILE"
}

emergency_shutdown() {
    log_message "CRITICAL" "EMERGENCY: Traffic limit exceeded, initiating shutdown"
    audit_log "SHUTDOWN" "Traffic limit reached, system shutting down"
    
    send_notification "EMERGENCY SHUTDOWN" "流量已超过100%限制，系统即将关机。"
    
    # 等待通知发送
    sleep 5
    
    /sbin/shutdown -h now "Monthly traffic limit reached on $INTERFACE"
}

#================================================================
# 冷却期检查
#================================================================

check_cooldown() {
    local action_type=$1
    
    if [ ! -f "$LAST_ACTION_FILE" ]; then
        return 0
    fi
    
    local last_action_time=$(cat "$LAST_ACTION_FILE")
    local current_time=$(date +%s)
    local last_time=$(date -d "$last_action_time" +%s 2>/dev/null || echo 0)
    local cooldown_seconds=$(( ${COOLDOWN_MINUTES:-30} * 60 ))
    
    local elapsed=$(( current_time - last_time ))
    
    if [ "$elapsed" -lt "$cooldown_seconds" ]; then
        log_message "INFO" "Cooldown period active, skipping $action_type action"
        return 1
    fi
    
    return 0
}

#================================================================
# 分级响应处理
#================================================================

handle_level_1() {
    log_message "WARN" "WARNING Level 1: Traffic usage at ${USAGE_PCT}%"
    send_notification "WARNING" "流量使用已达 ${USAGE_PCT}% (${TX_MB}MB / ${THRESHOLD_MB}MB)"
}

handle_level_2() {
    log_message "WARN" "WARNING Level 2: Traffic usage at ${USAGE_PCT}%"
    
    # 检查是否已经执行过软阻断
    if [ -f "$SOFT_BLOCK_FLAG" ]; then
        return
    fi
    
    # 检查冷却期
    if ! check_cooldown "soft_block"; then
        return
    fi
    
    case "$ACTION_AT_90" in
        "block_ports")
            apply_soft_block
            ;;
        "alert")
            send_notification "ALERT" "流量使用已达 ${USAGE_PCT}%，接近阈值！"
            ;;
        *)
            log_message "WARN" "Unknown action: $ACTION_AT_90"
            ;;
    esac
}

handle_level_3() {
    log_message "CRITICAL" "CRITICAL Level 3: Traffic usage at ${USAGE_PCT}%"
    
    # 检查是否已经执行过硬阻断
    if [ -f "$HARD_BLOCK_FLAG" ]; then
        return
    fi
    
    # 检查冷却期
    if ! check_cooldown "hard_block"; then
        return
    fi
    
    case "$ACTION_AT_95" in
        "disable_interface"|"block_all")
            apply_hard_block
            ;;
        "alert")
            send_notification "CRITICAL ALERT" "流量使用已达 ${USAGE_PCT}%，严重超限！"
            ;;
        *)
            log_message "WARN" "Unknown action: $ACTION_AT_95"
            ;;
    esac
}

handle_critical() {
    log_message "CRITICAL" "CRITICAL: Traffic usage at ${USAGE_PCT}% - LIMIT EXCEEDED"
    
    if [ "$ACTION_AT_100" = "shutdown" ]; then
        emergency_shutdown
    else
        # 确保硬阻断已执行
        if [ ! -f "$HARD_BLOCK_FLAG" ]; then
            handle_level_3
        fi
        send_notification "LIMIT EXCEEDED" "流量已超过100%限制 (${TX_MB}MB / ${THRESHOLD_MB}MB)"
    fi
}

#================================================================
# 主函数
#================================================================

main() {
    # 检查是否启用
    check_enabled
    
    # 加载配置
    load_config
    
    # 检查必需的命令
    check_required_commands || {
        log_message "ERROR" "Required commands check failed, skipping monitoring"
        exit 1
    }
    
    # 检查 vnstat 服务
    check_vnstat_service || {
        log_message "ERROR" "vnstat service check failed, skipping monitoring"
        exit 1
    }
    
    # 日志轮转
    rotate_log_if_needed
    
    # 获取当前流量
    TX_MB=$(get_traffic)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # 计算使用百分比
    USAGE_PCT=$(calculate_usage_percent "$TX_MB" "$THRESHOLD_MB")
    
    # 记录当前状态
    log_message "INFO" "Current usage: ${TX_MB}MB / ${THRESHOLD_MB}MB (${USAGE_PCT}%)"
    
    # 分级响应
    if [ "$USAGE_PCT" -ge "${CRITICAL_LEVEL:-100}" ]; then
        handle_critical
    elif [ "$USAGE_PCT" -ge "${WARNING_LEVEL_3:-95}" ]; then
        handle_level_3
    elif [ "$USAGE_PCT" -ge "${WARNING_LEVEL_2:-90}" ]; then
        handle_level_2
    elif [ "$USAGE_PCT" -ge "${WARNING_LEVEL_1:-80}" ]; then
        handle_level_1
    fi
}

# 执行主函数
main "$@"
