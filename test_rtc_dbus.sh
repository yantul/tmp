#!/bin/sh
# RTC D-Bus 功能验证脚本
# 通过 busctl --user 访问 RTC 设备，验证写入→读取一致性
# 用法: sh test_rtc_dbus.sh [lua]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="/bmc/kepler/Chip/Rtc/Rtc_1_01"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
CHIP_IFACE="bmc.kepler.Chip"
RTC_IFACE="bmc.kepler.Chip.Rtc"

# 上下文模式
if [ "$1" = "lua" ]; then
    CONTEXT_MODE="lua"
else
    CONTEXT_MODE="native"
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

parse_ay() {
    echo "$1" | sed 's/^ay //' | sed 's/^[0-9]* //' | awk '{for(i=1;i<=NF;i++) printf "%02x ", $i}' | sed 's/ $//'
}

# ── 上下文辅助函数 ─────────────────────────────────────────────────────
ctx_lock_call() {
    local req="$1"; shift
    if [ "${CONTEXT_MODE}" = "lua" ]; then
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetLockStatus \
            "a{ss}yu" 1 "Requestor" "${req}" "$@"
    else
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetLockStatus \
            "a{ss}a{ss}yu" 1 "Requestor" "${req}" 1 "Requestor" "${req}" "$@"
    fi
}

ctx_access_call() {
    local req="$1"; shift
    if [ "${CONTEXT_MODE}" = "lua" ]; then
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetAccessibility \
            "a{ss}bq" 1 "Requestor" "${req}" "$@"
    else
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetAccessibility \
            "a{ss}a{ss}bq" 1 "Requestor" "${req}" 1 "Requestor" "${req}" "$@"
    fi
}

# ── 设备检查 ──────────────────────────────────────────────────────────────
sep
info "RTC D-Bus 功能验证"
info "设备: ${SERVICE} ${CHIP_PATH}"
if [ "${CONTEXT_MODE}" = "lua" ]; then
    info "上下文模式: Lua版本 (单a{ss})"
else
    info "上下文模式: 下沉版本 (双a{ss}a{ss})"
fi
sep

INTROSPECT_RESULT=$(busctl --user introspect "${SERVICE}" "${CHIP_PATH}" 2>&1)
if [ -z "${INTROSPECT_RESULT}" ]; then
    fail "设备不存在或服务未启动"
    exit 1
fi
pass "设备存在"

# ══════════════════════════════════════════════════════════════════════
#  BlockIO 读写测试 (验证 RTC 内存打桩)
# ══════════════════════════════════════════════════════════════════════

# ── 测试 1: BlockIO.Write 写入时间 ────────────────────────────────────────
# RTC block_write 输入格式: [year_lo, year_hi, month, day, weekday, hour, minute, second]
# 2026-06-17 Tue 14:30:45 → [234, 7, 6, 17, 2, 14, 30, 45]
# chip_rtc 会做 BCD 编码再存入桩, 读取时 BCD 解码还原
sep
info "测试 1: BlockIO.Write - 写入 2026-06-17 Tue 14:30:45"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45; then
    pass "Write 成功"
else
    fail "Write 失败"
    exit 1
fi

# ── 测试 2: BlockIO.Read 读回 ─────────────────────────────────────────────
sep
info "测试 2: BlockIO.Read - 读回 8 字节"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 0 8
READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 0 8 2>&1) || true

if echo "${READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "Read 成功"
    READ_HEX=$(parse_ay "${READ_RESULT}")
    info "读取到: ${READ_HEX}"
else
    fail "Read 失败: ${READ_RESULT}"
    exit 1
fi

# ── 测试 3: 时间值一致性校验 (BCD 编解码后) ─────────────────────────────
# 输出格式: [year_lo, year_hi, month, day, weekday, hour, minute, second]
# 2026-06-17 Tue 14:30:45 → [0xEA, 0x07, 6, 17, 2, 14, 30, 45]
sep
info "测试 3: 时间值一致性校验"

# 从读取结果提取各字段
R_YEAR_LO=$(echo "${READ_HEX}" | awk '{print $1}')
R_YEAR_HI=$(echo "${READ_HEX}" | awk '{print $2}')
R_MONTH=$(echo "${READ_HEX}" | awk '{print $3}')
R_DAY=$(echo "${READ_HEX}" | awk '{print $4}')
R_WEEK=$(echo "${READ_HEX}" | awk '{print $5}')
R_HOUR=$(echo "${READ_HEX}" | awk '{print $6}')
R_MIN=$(echo "${READ_HEX}" | awk '{print $7}')
R_SEC=$(echo "${READ_HEX}" | awk '{print $8}')

# 验证各字段 (十六进制比较)
PASS_FLAG=1
check_field() {
    local name="$1" expect="$2" actual="$3"
    if [ "${expect}" = "${actual}" ]; then
        pass "${name}: 0x${actual} == 0x${expect}"
    else
        fail "${name}: 0x${actual} != 0x${expect}"
        PASS_FLAG=0
    fi
}

check_field "year_lo"  "ea" "${R_YEAR_LO}"
check_field "year_hi"  "07" "${R_YEAR_HI}"
check_field "month"    "06" "${R_MONTH}"
check_field "day"      "11" "${R_DAY}"
check_field "weekday"  "02" "${R_WEEK}"
check_field "hour"     "0e" "${R_HOUR}"
check_field "minute"   "1e" "${R_MIN}"
check_field "second"   "2d" "${R_SEC}"

if [ "${PASS_FLAG}" -eq 1 ]; then
    pass "时间值全部正确: 2026-06-17 Tue 14:30:45"
else
    fail "时间值校验失败"
fi

# ── 测试 4: 多次不同时间写入→读取验证 ────────────────────────────────────
sep
info "测试 4: 多次不同时间写入→读取验证"

check_time() {
    local label="$1" expect_s="$2" expect_min="$3" expect_h="$4" expect_d="$5" expect_mon="$6"
    local result=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 8 2>&1) || true
    local hex=$(parse_ay "${result}")
    local s=$(echo "${hex}" | awk '{print $8}')
    local min=$(echo "${hex}" | awk '{print $7}')
    local h=$(echo "${hex}" | awk '{print $6}')
    local d=$(echo "${hex}" | awk '{print $4}')
    local mon=$(echo "${hex}" | awk '{print $3}')

    local ok=1
    [ "${s}" != "${expect_s}" ] && ok=0
    [ "${min}" != "${expect_min}" ] && ok=0
    [ "${h}" != "${expect_h}" ] && ok=0
    [ "${d}" != "${expect_d}" ] && ok=0
    [ "${mon}" != "${expect_mon}" ] && ok=0

    if [ "${ok}" -eq 1 ]; then
        pass "${label}: ${hex}"
    else
        fail "${label}: sec=${s}(e${expect_s}) min=${min}(e${expect_min}) hr=${h}(e${expect_h}) day=${d}(e${expect_d}) mon=${mon}(e${expect_mon})"
    fi
}

# 写入 2025-12-31 Wed 23:59:59 → [233,7,12,31,3,23,59,59]
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 233 7 12 31 3 23 59 59 >/dev/null 2>&1
check_time "2025-12-31 23:59:59" "3b" "3b" "17" "1f" "0c"

# 写入 2000-01-01 Sat 00:00:00 → [0,7,1,1,6,0,0,0] (世纪位测试)
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 0 7 1 1 6 0 0 0 >/dev/null 2>&1
check_time "2000-01-01 00:00:00" "00" "00" "00" "01" "01"

# 写入 2026-06-17 Tue 14:30:45 → [234,7,6,17,2,14,30,45]
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45 >/dev/null 2>&1
check_time "2026-06-17 14:30:45" "2d" "1e" "0e" "11" "06"

# ══════════════════════════════════════════════════════════════════════
#  bmc.kepler.Chip 接口测试
# ══════════════════════════════════════════════════════════════════════

# ── 测试 6: HealthStatus 属性 ─────────────────────────────────────────────
sep
info "测试 6: HealthStatus"

HS_RESULT=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" HealthStatus 2>&1) || true
HS_VALUE=$(echo "${HS_RESULT}" | sed 's/^[a-z] //')
info "HealthStatus = ${HS_VALUE}"
if [ "${HS_VALUE}" = "0" ]; then
    pass "HealthStatus 初始值正确 (0=ACCESS_SUCCESS)"
else
    fail "HealthStatus 异常: ${HS_VALUE} (期望 0)"
fi

# ── 测试 7: LockStatus 属性 ──────────────────────────────────────────────
sep
info "测试 7: LockStatus"

LOCK_HS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_HS}" | sed 's/^[a-z] //')
info "LockStatus = ${LOCK_VALUE}"

# ── 测试 8: SetAccessibility ─────────────────────────────────────────────
sep
info "测试 8a: SetAccessibility - 禁用访问 2 秒"

if ctx_access_call "TestClient" false 2; then
    pass "SetAccessibility(false, 2s) 成功"
else
    fail "SetAccessibility(false, 2s) 失败"
fi

info "测试 8b: SetAccessibility - 参数校验"
if ctx_access_call "TestClient" false 0 2>/dev/null; then
    fail "duration=0 应失败"
else
    pass "duration=0 正确拒绝"
fi

if ctx_access_call "TestClient" false 1801 2>/dev/null; then
    fail "duration=1801 应失败"
else
    pass "duration=1801 正确拒绝"
fi

info "测试 8c: SetAccessibility - 恢复访问"
if ctx_access_call "TestClient" true 1; then
    pass "SetAccessibility(true) 成功"
else
    fail "SetAccessibility(true) 失败"
fi

# ── 测试 9: SetLockStatus 完整流程 ───────────────────────────────────────
sep
info "测试 9a: ClientA 锁定"

LOCK_RET=$(ctx_lock_call "ClientA" 1 30 2>&1) || true
info "返回: ${LOCK_RET}"
if echo "${LOCK_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 锁定成功"
else
    fail "ClientA 锁定失败: ${LOCK_RET}"
fi

LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
if [ "${LOCK_VALUE}" = "1" ]; then
    pass "LockStatus=1 已锁定"
else
    fail "LockStatus=${LOCK_VALUE} (期望 1)"
fi

info "测试 9b: ClientA 续锁"
EXTEND_RET=$(ctx_lock_call "ClientA" 1 60 2>&1) || true
if echo "${EXTEND_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "续锁成功"
else
    fail "续锁失败: ${EXTEND_RET}"
fi

info "测试 9c: ClientB 解锁 (应被拒)"
UNLOCK_WRONG=$(ctx_lock_call "ClientB" 0 0 2>&1) || true
if echo "${UNLOCK_WRONG}" | grep -qE " 3$|^3$"; then
    pass "ClientB 解锁被拒 (RequestorMismatched=3)"
else
    fail "ClientB 解锁返回异常: ${UNLOCK_WRONG} (期望 3)"
fi

info "测试 9d: ClientA 解锁"
UNLOCK_OK=$(ctx_lock_call "ClientA" 0 0 2>&1) || true
if echo "${UNLOCK_OK}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 解锁成功"
else
    fail "ClientA 解锁失败: ${UNLOCK_OK}"
fi

LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
if [ "${LOCK_VALUE}" = "0" ]; then
    pass "LockStatus=0 已解锁"
else
    fail "LockStatus=${LOCK_VALUE} (期望 0)"
fi

info "测试 9e: 重复解锁 (应被拒)"
UNLOCK_TWICE=$(ctx_lock_call "ClientA" 0 0 2>&1) || true
if echo "${UNLOCK_TWICE}" | grep -qE " 2$|^2$"; then
    pass "重复解锁被拒 (AlreadyUnlocked=2)"
else
    fail "重复解锁返回异常: ${UNLOCK_TWICE} (期望 2)"
fi

info "测试 9f: 超时锁定 (lock_time=1801)"
LOCK_BAD=$(ctx_lock_call "ClientA" 1 1801 2>&1) || true
if echo "${LOCK_BAD}" | grep -qE " 1$|^1$"; then
    pass "超时锁定被拒 (InvalidParameter=1)"
else
    fail "超时锁定返回异常: ${LOCK_BAD} (期望 1)"
fi

# ══════════════════════════════════════════════════════════════════════
#  汇总
# ══════════════════════════════════════════════════════════════════════
sep
info "测试完成"
info "设备: ${SERVICE} ${CHIP_PATH}"
sep
