#!/bin/sh
# I2C EEPROM D-Bus 功能验证脚本
# 通过 busctl --user 访问 I2cOverHisport 下的 EEPROM 设备，验证写入→读取一致性
# 用法: sh test_i2c_eeprom_dbus.sh [lua] [chip_path]
#   传 "lua" 使用 Lua版本上下文(单a{ss}), 默认下沉版本(双a{ss}a{ss})

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="/bmc/kepler/Chip/Complex/Chip_Eeprom_1_01"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
BITIO_IFACE="bmc.kepler.Chip.BitIO"

# 上下文模式: 传 "lua" 则用 Lua版本, 默认下沉版本
if [ "$1" = "lua" ]; then
    CONTEXT_MODE="lua"
    shift
else
    CONTEXT_MODE="native"
fi

# 支持传入自定义路径
if [ -n "$1" ]; then
    CHIP_PATH="$1"
fi

# 测试参数
TEST_OFFSET=256
TEST_DATA="222 173 190 239 1 2 3 4"
TEST_LEN=8

# ── 上下文辅助函数 ─────────────────────────────────────────────────────
# 根据 CONTEXT_MODE 生成 busctl 上下文参数
# Lua版本:   a{ss}       →  "a{ss}yu"  1 "Requestor" "XXX" ...
# 下沉版本:  a{ss}a{ss}  →  "a{ss}a{ss}yu"  1 "Requestor" "XXX" 1 "Requestor" "XXX" ...
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

# 解析 busctl 返回的 ay 格式 (可能带 "ay " 类型前缀)
# 输入: "ay 8 222 173 ..." 或 "8 222 173 ..."
# 输出: "de ad be ef ..." (十六进制)
parse_ay() {
    echo "$1" | sed 's/^ay //' | sed 's/^[0-9]* //' | awk '{for(i=1;i<=NF;i++) printf "%02x ", $i}' | sed 's/ $//'
}

# ── 检查设备是否存在 ──────────────────────────────────────────────────────
sep
info "检查设备: ${SERVICE} ${CHIP_PATH}"

INTROSPECT_RESULT=$(busctl --user introspect "${SERVICE}" "${CHIP_PATH}" 2>&1)
if [ -z "${INTROSPECT_RESULT}" ]; then
    fail "设备不存在或服务未启动 (introspect 返回为空)"
    exit 1
fi
pass "设备存在"

# 检查 BlockIO 和 BitIO 接口是否可用
if echo "${INTROSPECT_RESULT}" | grep -q "${BLOCKIO_IFACE}"; then
    pass "BlockIO 接口可用"
else
    info "BlockIO 接口不存在 (跳过 BlockIO 测试)"
fi

if echo "${INTROSPECT_RESULT}" | grep -q "${BITIO_IFACE}"; then
    pass "BitIO 接口可用"
else
    info "BitIO 接口不存在 (跳过 BitIO 测试)"
fi

# ══════════════════════════════════════════════════════════════════════
#  BlockIO 接口测试
# ══════════════════════════════════════════════════════════════════════

# ── 测试 1: BlockIO.Write 写入 ────────────────────────────────────────────
sep
info "测试 1: BlockIO.Write - 写入 ${TEST_LEN} 字节到偏移 ${TEST_OFFSET}"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}; then
    pass "Write 成功"
else
    fail "Write 失败"
    exit 1
fi

# ── 测试 2: BlockIO.Read 读回 ─────────────────────────────────────────────
sep
info "测试 2: BlockIO.Read - 从偏移 ${TEST_OFFSET} 读取 ${TEST_LEN} 字节"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 "${TEST_OFFSET}" "${TEST_LEN}"
READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 "${TEST_OFFSET}" "${TEST_LEN}" 2>&1) || true

if echo "${READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "Read 成功"
    info "返回原始数据: ${READ_RESULT}"
    READ_LEN=$(echo "${READ_RESULT}" | sed 's/^ay //' | awk '{print $1}')
    info "读取到 ${READ_LEN} 字节: $(parse_ay "${READ_RESULT}")"
else
    fail "Read 失败: ${READ_RESULT}"
    exit 1
fi

# ── 测试 3: 数据一致性校验 ────────────────────────────────────────────────
sep
info "测试 3: 数据一致性校验"

EXPECTED_HEX="de ad be ef 01 02 03 04"
ACTUAL_HEX=$(parse_ay "${READ_RESULT}")

if [ "${EXPECTED_HEX}" = "${ACTUAL_HEX}" ]; then
    pass "数据一致! 写入: de ad be ef 01 02 03 04 == 读取: ${ACTUAL_HEX}"
else
    fail "数据不一致!"
    fail "预期: ${EXPECTED_HEX}"
    fail "实际: ${ACTUAL_HEX}"
    exit 1
fi

# ── 测试 4: 单字节写入读取 ────────────────────────────────────────────────
sep
info "测试 4: 单字节写入读取"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 1 170
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 1 170; then
    pass "单字节 Write 成功 (0xAA)"

    SINGLE_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 1 2>&1) || true
    SINGLE_HEX=$(parse_ay "${SINGLE_RESULT}")

    if [ "${SINGLE_HEX}" = "aa" ]; then
        pass "单字节读回成功: 0x${SINGLE_HEX}"
    else
        fail "单字节读回失败: 预期 aa, 实际 ${SINGLE_HEX}"
    fi
fi

# ── 测试 5: 多偏移连续读写 ────────────────────────────────────────────────
sep
info "测试 5: 多偏移连续读写"

OFFSETS="0 256 512 768"
DATA_VALUES="0xAA 0x55 0x1E 0x7B"
set -- ${DATA_VALUES}
for OFF_HEX in ${OFFSETS}; do
    DATA_DEC=$1; shift
    DATA=$(printf '%d' "${DATA_DEC}")
    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
        "a{ss}uay" 0 "${OFF_HEX}" 1 "${DATA}" >/dev/null 2>&1 || true

    RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 "${OFF_HEX}" 1 2>&1) || true
    READ_BYTE=$(parse_ay "${RESULT}" | awk '{print $1}')

    EXPECT_HEX=$(printf '%02x' "${DATA}")
    if [ "${READ_BYTE}" = "${EXPECT_HEX}" ]; then
        pass "偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} == 读取 0x${READ_BYTE}"
    else
        fail "偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} != 读取 0x${READ_BYTE}"
    fi
done

# ── 测试 6: 超过 32 字节的读写 ─────────────────────────────────────────────
sep
info "测试 6: 读写超过 32 字节"

BULK_DATA=""
for i in $(seq 0 47); do
    BULK_DATA="${BULK_DATA} $((i + 16))"
done

info "写入 48 字节..."
cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 1024 48 ${BULK_DATA}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 1024 48 ${BULK_DATA}; then
    pass "48 字节 Write 成功"

    BULK_READ=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 1024 48 2>&1) || true

    BULK_READ_LEN=$(echo "${BULK_READ}" | sed 's/^ay //' | awk '{print $1}')
    if [ "${BULK_READ_LEN}" = "48" ]; then
        pass "48 字节 Read 成功，长度正确"
    else
        fail "Read 返回长度不正确: ${BULK_READ_LEN} (期望 48)"
    fi
else
    fail "48 字节 Write 失败"
fi

# ══════════════════════════════════════════════════════════════════════
#  BitIO 接口测试 (带 mask 的读写)
# ══════════════════════════════════════════════════════════════════════

# ── 测试 7: BitIO.Write 写入 ──────────────────────────────────────────────
sep
info "测试 7: BitIO.Write - 写入 1 字节到偏移 512"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
    "a{ss}uyuay" 0 512 1 0xff 1 204
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
    "a{ss}uyuay" 0 512 1 0xff 1 204; then
    pass "BitIO.Write 成功 (0xCC)"
else
    fail "BitIO.Write 失败"
fi

# ── 测试 8: BitIO.Read 读回 ────────────────────────────────────────────────
sep
info "测试 8: BitIO.Read - 从偏移 512 读取 1 字节"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 512 1 0xff
BIT_READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 512 1 0xff 2>&1) || true

if echo "${BIT_READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "BitIO.Read 成功"
    BIT_HEX=$(parse_ay "${BIT_READ_RESULT}")
    info "读取到: ${BIT_HEX}"
else
    fail "BitIO.Read 失败: ${BIT_READ_RESULT}"
fi

# ── 测试 9: BitIO 带 mask 读取 ────────────────────────────────────────────
sep
info "测试 9: BitIO 带 mask 读取 (mask=0x0F)"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 512 1 0x0f
MASK_READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 512 1 0x0f 2>&1) || true

if echo "${MASK_READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "BitIO.Read (mask=0x0F) 成功"
    MASK_HEX=$(parse_ay "${MASK_READ_RESULT}")
    info "读取到 (仅低4位): ${MASK_HEX}"
fi

# ── 测试 10: 验证不同 mask 的读取结果 ─────────────────────────────────────
sep
info "测试 10: 验证不同 mask 的读取结果"

# 先写入一个已知值
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
    "a{ss}uyuay" 0 1024 1 0xff 1 85 >/dev/null 2>&1 || true  # 0x55 = 01010101b

# 用不同 mask 读取
MASK_0F_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 1024 1 0x0f 2>&1) || true
MASK_F0_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
    "a{ss}uyu" 0 1024 1 0xf0 2>&1) || true

info "原始值: 0x55 (01010101b)"
info "mask=0x0F (低4位): $(parse_ay "${MASK_0F_RESULT}")"
info "mask=0xF0 (高4位): $(parse_ay "${MASK_F0_RESULT}")"

# ══════════════════════════════════════════════════════════════════════
#  bmc.kepler.Chip 接口测试
# ══════════════════════════════════════════════════════════════════════
CHIP_IFACE="bmc.kepler.Chip"

# ── 测试 11: HealthStatus 属性读取 ───────────────────────────────────────
sep
info "测试 11: HealthStatus - 读取健康状态属性"

HS_RESULT=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" HealthStatus 2>&1) || true
# 去掉类型前缀 (如 "y 0" → "0")
HS_VALUE=$(echo "${HS_RESULT}" | sed 's/^[a-z] //')
info "HealthStatus = ${HS_VALUE}"

# 初始应为 0 (ACCESS_SUCCESS)
if [ "${HS_VALUE}" = "0" ]; then
    pass "HealthStatus 初始值正确: ${HS_VALUE} (ACCESS_SUCCESS)"
else
    fail "HealthStatus 初始值异常: ${HS_VALUE} (期望 0)"
fi

# 读取 LockStatus 属性
LOCK_HS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_HS_VALUE=$(echo "${LOCK_HS}" | sed 's/^[a-z] //')
info "LockStatus = ${LOCK_HS_VALUE}"

# ── 测试 12: SetAccessibility - 禁用/启用访问 ────────────────────────────
sep
info "测试 12: SetAccessibility - 禁用访问 2 秒"

# 禁用访问: status=false, disable_duration=2秒
if ctx_access_call "TestClient" false 2; then
    pass "SetAccessibility(false, 2s) 成功"
else
    fail "SetAccessibility(false, 2s) 失败"
fi

# 验证 disable_duration 范围 [1, 1800]
info "测试 12b: SetAccessibility - 超范围参数应失败"
if ctx_access_call "TestClient" false 0 2>/dev/null; then
    fail "SetAccessibility(duration=0) 应失败但成功了"
else
    pass "SetAccessibility(duration=0) 正确拒绝"
fi

if ctx_access_call "TestClient" false 1801 2>/dev/null; then
    fail "SetAccessibility(duration=1801) 应失败但成功了"
else
    pass "SetAccessibility(duration=1801) 正确拒绝"
fi

# 恢复访问
info "测试 12c: SetAccessibility - 恢复访问"
if ctx_access_call "TestClient" true 1; then
    pass "SetAccessibility(true) 成功"
else
    fail "SetAccessibility(true) 失败"
fi

# ── 测试 13: SetLockStatus - 锁定/解锁流程 ──────────────────────────────
sep
info "测试 13a: SetLockStatus - ClientA 锁定 (op_type=1, lock_time=30)"

LOCK_RET=$(ctx_lock_call "ClientA" 1 30 2>&1) || true
info "SetLockStatus 返回: ${LOCK_RET}"
if echo "${LOCK_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 锁定成功 (返回 0)"
else
    fail "ClientA 锁定失败 (返回: ${LOCK_RET})"
fi

# 查看 LockStatus 属性应为 1
LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
info "LockStatus = ${LOCK_VALUE}"
if [ "${LOCK_VALUE}" = "1" ]; then
    pass "LockStatus 已锁定"
else
    fail "LockStatus 异常: ${LOCK_VALUE} (期望 1)"
fi

# ── 测试 13b: 相同 Requestor 读取 (应成功) ───────────────────────────────
sep
info "测试 13b: 相同 Requestor (ClientA) 读取应成功"

READ_AFTER_LOCK=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 0 4 2>&1) || true
if echo "${READ_AFTER_LOCK}" | grep -qE "^(ay )?[0-9]"; then
    pass "ClientA 锁定后读取成功: $(parse_ay "${READ_AFTER_LOCK}")"
else
    fail "ClientA 锁定后读取失败: ${READ_AFTER_LOCK}"
fi

# ── 测试 13c: 相同 Requestor 续锁 (应成功) ───────────────────────────────
sep
info "测试 13c: 相同 Requestor (ClientA) 续锁"

EXTEND_RET=$(ctx_lock_call "ClientA" 1 60 2>&1) || true
info "续锁返回: ${EXTEND_RET}"
if echo "${EXTEND_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 续锁成功"
else
    fail "ClientA 续锁失败: ${EXTEND_RET}"
fi

# ── 测试 13d: 不同 Requestor 解锁 (应失败, RequestorMismatched=3) ────────
sep
info "测试 13d: 不同 Requestor (ClientB) 解锁应失败"

UNLOCK_WRONG=$(ctx_lock_call "ClientB" 0 0 2>&1) || true
info "ClientB 解锁返回: ${UNLOCK_WRONG}"
if echo "${UNLOCK_WRONG}" | grep -qE " 3$|^3$"; then
    pass "ClientB 解锁正确被拒 (RequestorMismatched=3)"
else
    fail "ClientB 解锁返回异常: ${UNLOCK_WRONG} (期望 3)"
fi

# ── 测试 13e: 正确 Requestor 解锁 (应成功) ──────────────────────────────
sep
info "测试 13e: 正确 Requestor (ClientA) 解锁"

UNLOCK_OK=$(ctx_lock_call "ClientA" 0 0 2>&1) || true
info "ClientA 解锁返回: ${UNLOCK_OK}"
if echo "${UNLOCK_OK}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 解锁成功"
else
    fail "ClientA 解锁失败: ${UNLOCK_OK}"
fi

# 验证 LockStatus 恢复为 0
LOCK_STATUS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_STATUS}" | sed 's/^[a-z] //')
if [ "${LOCK_VALUE}" = "0" ]; then
    pass "LockStatus 已解锁"
else
    fail "LockStatus 异常: ${LOCK_VALUE} (期望 0)"
fi

# ── 测试 13f: 重复解锁 (应失败, AlreadyUnlocked=2) ─────────────────────
sep
info "测试 13f: 重复解锁应失败"

UNLOCK_TWICE=$(ctx_lock_call "ClientA" 0 0 2>&1) || true
info "重复解锁返回: ${UNLOCK_TWICE}"
if echo "${UNLOCK_TWICE}" | grep -qE " 2$|^2$"; then
    pass "重复解锁正确被拒 (AlreadyUnlocked=2)"
else
    fail "重复解锁返回异常: ${UNLOCK_TWICE} (期望 2)"
fi

# ── 测试 13g: 锁定参数校验 ──────────────────────────────────────────────
sep
info "测试 13g: 锁定参数校验 (lock_time 超限)"

LOCK_BAD=$(ctx_lock_call "ClientA" 1 1801 2>&1) || true
info "超时锁定返回: ${LOCK_BAD}"
if echo "${LOCK_BAD}" | grep -qE " 1$|^1$"; then
    pass "超时锁定正确拒绝 (InvalidParameter=1)"
else
    fail "超时锁定返回异常: ${LOCK_BAD} (期望 1)"
fi

# ── 结果汇总 ──────────────────────────────────────────────────────────────
sep
info "测试完成"
info "设备路径: ${SERVICE} ${CHIP_PATH}"
if [ "${CONTEXT_MODE}" = "lua" ]; then
    info "上下文模式: Lua版本 (单a{ss})"
else
    info "上下文模式: 下沉版本 (双a{ss}a{ss})"
fi
info "Stub 日志请检查 hwproxy 的 stderr 输出 ([I2C WRITE] / [I2C READ])"
sep
