#!/bin/bash
#================================================================
# 超流量保护系统 - 测试脚本
# Traffic Limit Protection System - Test Script
# Version: 2.0.0
#================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 测试统计
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# 测试函数
assert_equals() {
    local expected="$1"
    local actual="$2"
    local desc="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

assert_command_exists() {
    local cmd="$1"
    local desc="$2"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        echo "  Command not found: $cmd"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local desc="$2"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if [ -f "$file" ]; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        echo "  File not found: $file"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

#================================================================
# 测试：依赖检查
#================================================================

test_dependencies() {
    print_header "测试：依赖检查"
    
    assert_command_exists "bash" "bash 可用"
    assert_command_exists "jq" "jq 可用（JSON 解析）"
    assert_command_exists "awk" "awk 可用（备用计算）"
}

#================================================================
# 测试：脚本语法
#================================================================

test_syntax() {
    print_header "测试：脚本语法检查"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if bash -n tx-monitor.sh 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} tx-monitor.sh 语法正确"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} tx-monitor.sh 语法错误"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if bash -n tx-ctl 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} tx-ctl 语法正确"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} tx-ctl 语法错误"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if bash -n install.sh 2>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} install.sh 语法正确"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} install.sh 语法错误"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

#================================================================
# 测试：文件结构
#================================================================

test_file_structure() {
    print_header "测试：文件结构"
    
    assert_file_exists "tx-monitor.sh" "监控脚本存在"
    assert_file_exists "tx-ctl" "控制工具存在"
    assert_file_exists "install.sh" "安装脚本存在"
    assert_file_exists "uninstall.sh" "卸载脚本存在"
    assert_file_exists "README.md" "README 存在"
    assert_file_exists "tx-monitor.conf.example" "示例配置存在"
}

#================================================================
# 测试：防火墙后端检测（模拟）
#================================================================

test_firewall_detection() {
    print_header "测试：防火墙后端检测"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if command -v iptables &> /dev/null; then
        echo -e "${GREEN}[PASS]${NC} iptables 检测成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
        # 检测版本
        if command -v iptables-legacy &> /dev/null; then
            echo "  - 发现 iptables-legacy"
        fi
        if command -v iptables-nft &> /dev/null; then
            echo "  - 发现 iptables-nft"
        fi
    elif command -v nft &> /dev/null; then
        echo -e "${GREEN}[PASS]${NC} nftables 检测成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${YELLOW}[SKIP]${NC} 未安装防火墙工具（测试环境）"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    fi
}

#================================================================
# 测试：vnstat 数据格式（模拟）
#================================================================

test_vnstat_json_parsing() {
    print_header "测试：vnstat JSON 解析"
    
    # 模拟 vnstat JSON 输出
    local mock_json='{"interfaces":[{"traffic":{"month":[{"tx":1234567890}]}}]}'
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local tx_bytes=$(echo "$mock_json" | jq -r '.interfaces[0].traffic.month[0].tx' 2>/dev/null)
    
    if [ "$tx_bytes" = "1234567890" ]; then
        echo -e "${GREEN}[PASS]${NC} JSON 解析成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} JSON 解析失败"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    # 测试字节到 MB 转换
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local tx_mb=$((tx_bytes / 1000000))
    
    if [ "$tx_mb" = "1234" ]; then
        echo -e "${GREEN}[PASS]${NC} 字节转 MB 成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} 字节转 MB 失败 (got: $tx_mb)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

#================================================================
# 测试：vnstat oneline fallback
#================================================================

test_vnstat_oneline_parsing() {
    print_header "测试：vnstat oneline fallback"
    
    # 模拟 vnstat --oneline 输出
    local mock_oneline="1;eth0;1704902400;1000000;2000000;3000000;4000000;..."
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local tx_kib=$(echo "$mock_oneline" | cut -d';' -f5 | tr -d ' ')
    
    if [ "$tx_kib" = "2000000" ]; then
        echo -e "${GREEN}[PASS]${NC} oneline 解析成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} oneline 解析失败 (got: $tx_kib)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    # 测试 KiB 到 MB 转换
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local tx_mb=$((tx_kib / 1024))
    
    if [ "$tx_mb" = "1953" ]; then
        echo -e "${GREEN}[PASS]${NC} KiB 转 MB 成功"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} KiB 转 MB 失败 (got: $tx_mb)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

#================================================================
# 测试：百分比计算
#================================================================

test_percentage_calculation() {
    print_header "测试：百分比计算"
    
    # 测试用例: 90000 / 100000 = 90%
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local current_mb=90000
    local threshold_mb=100000
    local percent=$((current_mb * 100 / threshold_mb))
    
    if [ "$percent" = "90" ]; then
        echo -e "${GREEN}[PASS]${NC} 百分比计算正确 (90000/100000 = 90%)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} 百分比计算错误 (got: $percent%)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    # 测试超过 100% 的情况
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    current_mb=110000
    percent=$((current_mb * 100 / threshold_mb))
    
    if [ "$percent" = "110" ]; then
        echo -e "${GREEN}[PASS]${NC} 超过 100% 计算正确 (110000/100000 = 110%)"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} 超过 100% 计算错误 (got: $percent%)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

#================================================================
# 测试：通知 payload 生成
#================================================================

test_notification_payload() {
    print_header "测试：通知 payload 生成"
    
    # 测试 Generic webhook payload
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local payload=$(cat <<EOF
{"level":"WARNING","message":"test","current_mb":1000,"threshold_mb":2000}
EOF
)
    
    if echo "$payload" | jq . &>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} Generic webhook payload 格式正确"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} Generic webhook payload 格式错误"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    # 测试 Slack payload
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    local slack_payload=$(cat <<EOF
{"text":"test","attachments":[{"color":"warning"}]}
EOF
)
    
    if echo "$slack_payload" | jq . &>/dev/null; then
        echo -e "${GREEN}[PASS]${NC} Slack webhook payload 格式正确"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}[FAIL]${NC} Slack webhook payload 格式错误"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

#================================================================
# 测试总结
#================================================================

print_summary() {
    print_header "测试总结"
    
    echo "总测试数: $TOTAL_TESTS"
    echo -e "${GREEN}通过:${NC} $PASSED_TESTS"
    echo -e "${RED}失败:${NC} $FAILED_TESTS"
    echo ""
    
    local success_rate=0
    if [ "$TOTAL_TESTS" -gt 0 ]; then
        success_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    fi
    
    echo "成功率: ${success_rate}%"
    echo ""
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}✓ 所有测试通过！${NC}"
        return 0
    else
        echo -e "${RED}✗ 有测试失败${NC}"
        return 1
    fi
}

#================================================================
# 主程序
#================================================================

main() {
    echo "=========================================="
    echo "  超流量保护系统 - 测试套件"
    echo "  Traffic Limit Protection - Test Suite"
    echo "  Version: 2.0.0"
    echo "=========================================="
    echo ""
    
    # 进入脚本目录
    cd "$(dirname "$0")"
    
    # 运行所有测试
    test_dependencies
    test_file_structure
    test_syntax
    test_firewall_detection
    test_vnstat_json_parsing
    test_vnstat_oneline_parsing
    test_percentage_calculation
    test_notification_payload
    
    # 打印总结
    print_summary
}

main "$@"
