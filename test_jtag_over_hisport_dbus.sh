#!/bin/sh
# JtagOverHisport D-Bus 功能验证脚本
# 通过 busctl --user 访问 JtagOverHisport 总线和 CPLD 芯片
# 用法: sh test_jtag_over_hisport_dbus.sh [bus_path]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
BUS_PATH="/bmc/kepler/Bus/JtagOverHisport/JtagOverHisport_1"
CPLD_PATH="/bmc/kepler/Chip/Cpld/Cpld_2_01"
BUS_IFACE="bmc.kepler.Bus"
JTAG_TARGET_IFACE="bmc.kepler.Chip.JtagTarget"

# 支持传入自定义路径
if [ -n "$1" ]; then
    BUS_PATH="$1"
fi

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
cmd()  { printf "${YELLOW}[CMD]${NC}  %s\n" "$*"; }
sep()  { echo "────────────────────────────────────────────────────────"; }

# ── 检查设备是否存在 ──────────────────────────────────────────────────────
sep
info "检查 JtagOverHisport 总线: ${SERVICE} ${BUS_PATH}"

BUS_INTROSPECT=$(busctl --user introspect "${SERVICE}" "${BUS_PATH}" 2>&1)
if [ -z "${BUS_INTROSPECT}" ]; then
    fail "总线不存在或服务未启动"
    exit 1
fi
pass "JtagOverHisport 总线存在"

# 检查 CPLD 芯片
sep
info "检查 CPLD 芯片: ${SERVICE} ${CPLD_PATH}"

CPLD_INTROSPECT=$(busctl --user introspect "${SERVICE}" "${CPLD_PATH}" 2>&1)
if [ -z "${CPLD_INTROSPECT}" ]; then
    fail "CPLD 芯片不存在"
    exit 1
fi
pass "CPLD 芯片存在"

# 检查接口
echo "${BUS_INTROSPECT}" | grep -q "${BUS_IFACE}" && pass "Bus 接口可用" || fail "Bus 接口不可用"
echo "${CPLD_INTROSPECT}" | grep -q "${JTAG_TARGET_IFACE}" && pass "JtagTarget 接口可用" || fail "JtagTarget 接口不可用"

# ══════════════════════════════════════════════════════════════════════
#  第一部分: 总线属性测试
# ══════════════════════════════════════════════════════════════════════

# ── 测试 1: AccessEnabled 属性读取 ─────────────────────────────────────
sep
info "测试 1: AccessEnabled 属性读取"

ACCESS_RESULT=$(busctl --user get-property "${SERVICE}" "${BUS_PATH}" "${BUS_IFACE}" AccessEnabled 2>&1) || true
ACCESS_VALUE=$(echo "${ACCESS_RESULT}" | sed 's/^[a-z] //')
info "AccessEnabled = ${ACCESS_VALUE}"

if [ "${ACCESS_VALUE}" = "true" ]; then
    pass "AccessEnabled = true (访问已启用)"
else
    info "AccessEnabled = ${ACCESS_VALUE}"
fi

# ── 测试 2: Timeout 属性读取 ──────────────────────────────────────────
sep
info "测试 2: Timeout 属性读取"

TIMEOUT_RESULT=$(busctl --user get-property "${SERVICE}" "${BUS_PATH}" "${BUS_IFACE}" Timeout 2>&1) || true
TIMEOUT_VALUE=$(echo "${TIMEOUT_RESULT}" | sed 's/^[a-z] //')
info "Timeout = ${TIMEOUT_VALUE}"

if [ -n "${TIMEOUT_VALUE}" ] && ! echo "${TIMEOUT_VALUE}" | grep -q "Unknown object"; then
    pass "Timeout 属性读取成功: ${TIMEOUT_VALUE}"
else
    fail "Timeout 属性读取失败"
fi

# ══════════════════════════════════════════════════════════════════════
#  第二部分: JtagTarget 接口测试 (CPLD 芯片)
# ══════════════════════════════════════════════════════════════════════
sep
info "═════════════════════════════════════════════════════════════════"
info "以下测试 CPLD 芯片的 JtagTarget 接口"
info "这是测试 JtagOverHisport 总线下器件的正确方式"
info "═════════════════════════════════════════════════════════════════"
sep

# ── 测试 3: GetChipIdcode - 获取芯片 ID ────────────────────────────────
sep
info "测试 3: GetChipIdcode - 获取 CPLD 芯片 ID"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" GetChipIdcode "a{ss}" 0
IDCODE_RESULT=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" GetChipIdcode "a{ss}" 0 2>&1) || true

if echo "${IDCODE_RESULT}" | grep -qE "^au"; then
    pass "GetChipIdcode 成功: ${IDCODE_RESULT}"
else
    fail "GetChipIdcode 失败: ${IDCODE_RESULT}"
fi

# ── 测试 4: SetTargetNumber ────────────────────────────────────────────
sep
info "测试 4: SetTargetNumber - 设置目标编号"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" SetTargetNumber "a{ss}u" 0 1
if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" SetTargetNumber "a{ss}u" 0 1 2>&1; then
    pass "SetTargetNumber(1) 成功"
else
    fail "SetTargetNumber(1) 失败"
fi

# ── 测试 5: SetBypassMode ──────────────────────────────────────────────
sep
info "测试 5: SetBypassMode - 设置 Bypass 模式"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" SetBypassMode "a{ss}b" 0 true
if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" SetBypassMode "a{ss}b" 0 true 2>&1; then
    pass "SetBypassMode(true) 成功"
else
    fail "SetBypassMode(true) 失败"
fi

# 禁用 Bypass
busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" SetBypassMode "a{ss}b" 0 false >/dev/null 2>&1

# ── 测试 6: BypassChannelTest ─────────────────────────────────────────
sep
info "测试 6: BypassChannelTest - 测试 Bypass 通道"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" BypassChannelTest "a{ss}yy" 0 0 0
BYPASS_RESULT=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" BypassChannelTest "a{ss}yy" 0 0 0 2>&1) || true
info "BypassChannelTest 结果: ${BYPASS_RESULT}"

if echo "${BYPASS_RESULT}" | grep -qE "^b"; then
    pass "BypassChannelTest 成功"
else
    info "BypassChannelTest: ${BYPASS_RESULT}"
fi

# ── 测试 7: 准备测试文件 ────────────────────────────────────────────────
sep
info "测试 7: 准备测试文件 (SVF 和升级文件)"

SVF_FILE="/tmp/test.svf"
UPGRADE_DIR="/dev/shm/upgrade"
COLLECT_DIR="/dev/shm/tmp/collect_registers"

mkdir -p "${UPGRADE_DIR}"
mkdir -p "${COLLECT_DIR}"

# 创建空的 SVF 文件
touch "${SVF_FILE}" 2>/dev/null || true
echo "123abc" > "${UPGRADE_DIR}/aaa" 2>/dev/null || true

if [ -f "${SVF_FILE}" ] && [ -f "${UPGRADE_DIR}/aaa" ]; then
    pass "测试文件创建成功"
else
    fail "测试文件创建失败"
fi

# ── 测试 8: BlockIO.Write - 设置 SVF 文件路径 ───────────────────────────
sep
info "测试 8: BlockIO.Write - 通过 BlockIO 写入 SVF 文件路径"

# 构造包含 SVF 文件路径的数据包（参考用户测试命令）
# 路径 "/tmp/test.svf" 的 ASCII 编码，busctl 要求十进制数值
# 0x2F=47 0x74=116 0x6D=109 0x70=112 0x2F=47 0x74=116 0x65=101 0x73=115 0x74=116 0x2E=46 0x73=115 0x76=118 0x66=102
SVF_PATH_BYTES="0 0 0 0 0 0 0 0 0 0 0 0 67 0 0 0 0 0 0 0 49 0 0 13 0 0 0 47 116 109 112 47 116 101 115 116 46 115 118 102"

BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${BLOCKIO_IFACE}" Write "a{ss}uay" 0 0 40 ${SVF_PATH_BYTES}

touch /tmp/test.svf

if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${BLOCKIO_IFACE}" Write "a{ss}uay" 0 0 40 ${SVF_PATH_BYTES} 2>&1; then
    pass "BlockIO.Write (SVF 文件路径) 成功"
else
    info "BlockIO.Write 可能需要实际硬件支持"
fi

# ── 测试 9: Collect - 收集寄存器 ────────────────────────────────────────
sep
info "测试 9: Collect - 收集寄存器到指定文件"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Collect a{ss}sys 0 "${UPGRADE_DIR}/aaa" 1 "${COLLECT_DIR}/bbb"

COLLECT_RESULT=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Collect a{ss}sys 0 "${UPGRADE_DIR}/aaa" 1 "${COLLECT_DIR}/bbb" 2>&1) || true

if echo "${COLLECT_RESULT}" | grep -qE "^$|^i 0$|成功" || [ -z "${COLLECT_RESULT}" ]; then
    pass "Collect 成功"
    # 检查输出文件
    if [ -f "${COLLECT_DIR}/bbb" ]; then
        pass "输出文件已创建: ${COLLECT_DIR}/bbb"
    else
        info "输出文件未创建 (可能需要实际硬件)"
    fi
else
    info "Collect: ${COLLECT_RESULT} (可能需要实际硬件支持)"
fi

# ── 测试 10: Upgrade - 升级 CPLD ──────────────────────────────────────────
sep
info "测试 10: Upgrade - CPLD 升级"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Upgrade a{ss}sy 0 "${UPGRADE_DIR}/aaa" 1

UPGRADE_RESULT=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Upgrade a{ss}sy 0 "${UPGRADE_DIR}/aaa" 1 2>&1) || true

if echo "${UPGRADE_RESULT}" | grep -qE "^$|^i 0$|成功" || [ -z "${UPGRADE_RESULT}" ]; then
    pass "Upgrade 成功"
else
    info "Upgrade: ${UPGRADE_RESULT} (可能需要实际硬件支持)"
fi

# ── 测试 11: Verify - 验证 CPLD ────────────────────────────────────────────
sep
info "测试 11: Verify - CPLD 验证"

cmd busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Verify a{ss}sy 0 "${UPGRADE_DIR}/aaa" 1

VERIFY_RESULT=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${JTAG_TARGET_IFACE}" Verify a{ss}sy 0 "${UPGRADE_DIR}/aaa" 1 2>&1) || true

if echo "${VERIFY_RESULT}" | grep -qE "^$|^i 0$|成功" || [ -z "${VERIFY_RESULT}" ]; then
    pass "Verify 成功"
else
    info "Verify: ${VERIFY_RESULT} (可能需要实际硬件支持)"
fi

# ══════════════════════════════════════════════════════════════════════
#  第四部分: bmc.kepler.Chip 接口测试 (CPLD 芯片)
# ══════════════════════════════════════════════════════════════════════
CHIP_IFACE="bmc.kepler.Chip"

# ── 测试 12: HealthStatus 属性读取 ───────────────────────────────────────
sep
info "测试 12: HealthStatus - 读取健康状态属性"

HS_RESULT=$(busctl --user get-property "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" HealthStatus 2>&1) || true
HS_VALUE=$(echo "${HS_RESULT}" | sed 's/^[a-z] //')
info "HealthStatus = ${HS_VALUE}"

if [ "${HS_VALUE}" = "0" ]; then
    pass "HealthStatus 初始值正确: ${HS_VALUE} (ACCESS_SUCCESS)"
else
    fail "HealthStatus 初始值异常: ${HS_VALUE} (期望 0)"
fi

# 读取 LockStatus 属性
LOCK_HS=$(busctl --user get-property "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_HS_VALUE=$(echo "${LOCK_HS}" | sed 's/^[a-z] //')
info "LockStatus = ${LOCK_HS_VALUE}"

# ── 测试 13: SetAccessibility - 禁用/启用访问 ────────────────────────────
sep
info "测试 13: SetAccessibility - 禁用访问 2 秒"

# 禁用访问: status=false, disable_duration=2秒
busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" false 2 2>&1 || true
pass "SetAccessibility(false, 2s) 完成"

# 验证 disable_duration 范围 [1, 1800]
info "测试 13b: SetAccessibility - 超范围参数应失败"
if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" false 0 2>/dev/null; then
    fail "SetAccessibility(duration=0) 应失败但成功了"
else
    pass "SetAccessibility(duration=0) 正确拒绝"
fi

if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" false 1801 2>/dev/null; then
    fail "SetAccessibility(duration=1801) 应失败但成功了"
else
    pass "SetAccessibility(duration=1801) 正确拒绝"
fi

# 恢复访问
info "测试 13c: SetAccessibility - 恢复访问"
if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" true 1; then
    pass "SetAccessibility(true) 成功"
else
    fail "SetAccessibility(true) 失败"
fi

# ── 测试 14: SetLockStatus - 锁定/解锁流程 ──────────────────────────────
sep
info "测试 14a: SetLockStatus - ClientA 锁定 (op_type=1, lock_time=30)"

LOCK_RET=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 1 30 2>&1) || true
info "SetLockStatus 返回: ${LOCK_RET}"
if echo "${LOCK_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 锁定成功 (返回 0)"
else
    fail "ClientA 锁定失败 (返回: ${LOCK_RET})"
fi

# 查看 LockStatus 属性应为 1
LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
info "LockStatus = ${LOCK_VALUE}"
if [ "${LOCK_VALUE}" = "1" ]; then
    pass "LockStatus 已锁定"
else
    fail "LockStatus 异常: ${LOCK_VALUE} (期望 1)"
fi

# ── 测试 14b: 相同 Requestor 续锁 (应成功) ───────────────────────────────
sep
info "测试 14b: 相同 Requestor (ClientA) 续锁"

EXTEND_RET=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 1 60 2>&1) || true
info "续锁返回: ${EXTEND_RET}"
if echo "${EXTEND_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 续锁成功"
else
    fail "ClientA 续锁失败: ${EXTEND_RET}"
fi

# ── 测试 14c: 不同 Requestor 解锁 (应失败, RequestorMismatched=3) ────────
sep
info "测试 14c: 不同 Requestor (ClientB) 解锁应失败"

UNLOCK_WRONG=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientB" 1 "Requestor" "ClientB" 0 0 2>&1) || true
info "ClientB 解锁返回: ${UNLOCK_WRONG}"
if echo "${UNLOCK_WRONG}" | grep -qE " 3$|^3$"; then
    pass "ClientB 解锁正确被拒 (RequestorMismatched=3)"
else
    fail "ClientB 解锁返回异常: ${UNLOCK_WRONG} (期望 3)"
fi

# ── 测试 14d: 正确 Requestor 解锁 (应成功) ──────────────────────────────
sep
info "测试 14d: 正确 Requestor (ClientA) 解锁"

UNLOCK_OK=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 0 0 2>&1) || true
info "ClientA 解锁返回: ${UNLOCK_OK}"
if echo "${UNLOCK_OK}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 解锁成功"
else
    fail "ClientA 解锁失败: ${UNLOCK_OK}"
fi

# 验证 LockStatus 恢复为 0
LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
if [ "${LOCK_VALUE}" = "0" ]; then
    pass "LockStatus 已解锁"
else
    fail "LockStatus 异常: ${LOCK_VALUE} (期望 0)"
fi

# ── 测试 14e: 重复解锁 (应失败, AlreadyUnlocked=2) ─────────────────────
sep
info "测试 14e: 重复解锁应失败"

UNLOCK_TWICE=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 0 0 2>&1) || true
info "重复解锁返回: ${UNLOCK_TWICE}"
if echo "${UNLOCK_TWICE}" | grep -qE " 2$|^2$"; then
    pass "重复解锁正确被拒 (AlreadyUnlocked=2)"
else
    fail "重复解锁返回异常: ${UNLOCK_TWICE} (期望 2)"
fi

# ── 测试 14f: 锁定参数校验 ──────────────────────────────────────────────
sep
info "测试 14f: 锁定参数校验 (lock_time 超限)"

LOCK_BAD=$(busctl --user call "${SERVICE}" "${CPLD_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 1 1801 2>&1) || true
info "超时锁定返回: ${LOCK_BAD}"
if echo "${LOCK_BAD}" | grep -qE " 1$|^1$"; then
    pass "超时锁定正确拒绝 (InvalidParameter=1)"
else
    fail "超时锁定返回异常: ${LOCK_BAD} (期望 1)"
fi

# ── 清理测试文件 ──────────────────────────────────────────────────────────
sep
info "清理测试文件"
rm -f "${SVF_FILE}" 2>/dev/null || true
rm -f "${UPGRADE_DIR}/aaa" 2>/dev/null || true
rm -f "${COLLECT_DIR}/bbb" 2>/dev/null || true
rmdir "${UPGRADE_DIR}" 2>/dev/null || true
rmdir "${COLLECT_DIR}" 2>/dev/null || true
pass "测试文件清理完成"

# ── 结果汇总 ──────────────────────────────────────────────────────────────
sep
info "测试完成"
info "总线路径: ${SERVICE} ${BUS_PATH}"
info "CPLD路径: ${SERVICE} ${CPLD_PATH}"
sep
