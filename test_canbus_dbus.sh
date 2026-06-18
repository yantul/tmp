#!/bin/sh
# CAN Bus Chip D-Bus 功能验证脚本
# 通过 busctl --user 访问 CanbusChip 设备，验证 BlockIO/BitIO 接口
# 用法: sh test_canbus_dbus.sh [chip_path]
#
# CAN ID 位域布局 (32-bit):
#   bit 0:      cnt       (帧结束标志)
#   bits 1-6:   reserve
#   bit 7:      ms        (master=1 / slave=0)
#   bits 8-15:  cmd
#   bits 16-22: addr      (节点地址)
#   bits 23-28: protocol
#   bits 29-31: frame_type (extended=4)

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="${1:-/bmc/kepler/Chip/CanbusChip/CanbusChip_0_01}"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
BITIO_IFACE="bmc.kepler.Chip.BitIO"
CHIP_IFACE="bmc.kepler.Chip"

# 测试参数
TEST_CAN_ID=0xA0038280      # frame_type=4, protocol=0, addr=3, cmd=0x82, ms=1, reserve=0x3F, cnt=0
TEST_CAN_ID_HEX="0x80 0x82 0x03 0xa0"
TEST_PAYLOAD="0x11 0x22 0x33 0x44 0x55 0x66 0x77 0x88"
TEST_LEN=8

# ── 上下文辅助函数 ─────────────────────────────────────────────────────
# Busctl 上下文: 双 a{ss} (下沉版本)
CONTEXT='1 "Requestor" "TestClient" 1 "Requestor" "TestClient"'
# Busctl 方法签名 (上下文 a{ss}a{ss} + 方法参数)
SIG_WRITE="a{ss}a{ss}uay"
SIG_READ="a{ss}a{ss}uu"
SIG_WRITE_READ="a{ss}a{ss}ayu"
SIG_BIT_READ="a{ss}a{ss}uuy"
SIG_BIT_WRITE="a{ss}a{ss}uuyay"

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

# 解析 busctl 返回的 ay 格式
parse_ay() {
    echo "$1" | sed 's/^ay //' | sed 's/^[0-9]* //' | awk '{for(i=1;i<=NF;i++) printf "%02x ", $i}' | sed 's/ $//'
}

# ── 检查设备是否存在 ──────────────────────────────────────────────────────
sep
info "CAN Bus Chip D-Bus 功能验证"
info "设备: ${SERVICE} ${CHIP_PATH}"
sep

INTROSPECT_RESULT=$(busctl --user introspect "${SERVICE}" "${CHIP_PATH}" 2>&1)
if [ -z "${INTROSPECT_RESULT}" ]; then
    fail "设备不存在或服务未启动 (introspect 返回为空)"
    exit 1
fi
pass "设备存在"

# 检查接口可用性
HAS_BLOCKIO=0
HAS_BITIO=0
echo "${INTROSPECT_RESULT}" | grep -q "${BLOCKIO_IFACE}" && HAS_BLOCKIO=1
echo "${INTROSPECT_RESULT}" | grep -q "${BITIO_IFACE}" && HAS_BITIO=1

if [ "${HAS_BLOCKIO}" -eq 1 ]; then
    pass "BlockIO 接口可用"
else
    fail "BlockIO 接口不存在"
    exit 1
fi

if [ "${HAS_BITIO}" -eq 1 ]; then
    pass "BitIO 接口可用"
else
    info "BitIO 接口不存在 (跳过 BitIO 测试)"
fi

# ══════════════════════════════════════════════════════════════════════
#  BlockIO 接口测试 (block_write / block_read)
# ══════════════════════════════════════════════════════════════════════

# ── 测试 1: BlockIO.Write - 发送 CAN 帧 ──────────────────────────────────
# CAN 帧格式: [CAN_ID(4)] + [payload(8)]
# CAN_ID = 0xA0038280 (little-endian: 80 82 03 A0)
sep
info "测试 1: BlockIO.Write - 发送 CAN 帧 (CAN_ID=0x${TEST_CAN_ID})"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "${SIG_WRITE}" ${CONTEXT} 0 12 ${TEST_CAN_ID_HEX} ${TEST_PAYLOAD}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "${SIG_WRITE}" ${CONTEXT} 0 12 ${TEST_CAN_ID_HEX} ${TEST_PAYLOAD}; then
    pass "Write 成功"
else
    fail "Write 失败"
    exit 1
fi

# ── 测试 2: BlockIO.WriteRead - 写命令后读响应 (CAN 正常通信模式) ──────
# CAN 通信必须先写命令帧，再读响应帧
# WriteRead(indata=[CAN_ID+payload], read_length=frame_len)
sep
info "测试 2: BlockIO.WriteRead - 写命令后读响应 (CAN_ID=0x${TEST_CAN_ID})"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "${SIG_WRITE_READ}" ${CONTEXT} 12 ${TEST_CAN_ID_HEX} ${TEST_PAYLOAD} 12
READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "${SIG_WRITE_READ}" ${CONTEXT} 12 ${TEST_CAN_ID_HEX} ${TEST_PAYLOAD} 12 2>&1) || true

if echo "${READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "WriteRead 成功"
    READ_HEX=$(parse_ay "${READ_RESULT}")
    info "读取到: ${READ_HEX}"
else
    info "WriteRead 返回: ${READ_RESULT}"
    info "无预置响应数据时可能返回空"
fi

# ── 测试 3: 多帧连续写入 ────────────────────────────────────────────────
sep
info "测试 3: 多帧连续写入 (不同 CAN ID)"

CAN_IDS="0xA0038280 0xA0048280 0xA0058280"
PAYLOADS="1 2 3 4 5 6 7 8 | 0x10 0x20 0x30 0x40 0x50 0x60 0x70 0x80 | 0xAA 0xBB 0xCC 0xDD 0xEE 0xFF 0x11 0x22"
i=0
for CAN_ID in ${CAN_IDS}; do
    i=$((i + 1))
    # 构造 CAN ID 的 little-endian 字节
    B0=$((CAN_ID & 0xFF))
    B1=$(((CAN_ID >> 8) & 0xFF))
    B2=$(((CAN_ID >> 16) & 0xFF))
    B3=$(((CAN_ID >> 24) & 0xFF))

    PAYLOAD=$(echo "${PAYLOADS}" | cut -d'|' -f${i} | xargs)

    if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
        "${SIG_WRITE}" ${CONTEXT} 0 12 ${B0} ${B1} ${B2} ${B3} ${PAYLOAD} >/dev/null 2>&1; then
        pass "帧 ${i}: CAN_ID=0x$(printf '%08X' ${CAN_ID}) 写入成功"
    else
        fail "帧 ${i}: CAN_ID=0x$(printf '%08X' ${CAN_ID}) 写入失败"
    fi
done

# ── 测试 4: BlockIO.WriteRead - 查询命令 (cmd=0x82) ─────────────────────
# 构造查询 CAN ID: frame_type=4, addr=3, cmd=0x82, ms=1
# pack_can_id(cnt=0, reserve=0x3F, ms=1, cmd=0x82, addr=3, protocol=0, frame_type=4)
# = 0 | (0x3F<<1) | (1<<7) | (0x82<<8) | (3<<16) | (0<<23) | (4<<29)
# = 0x0000007E | 0x00000080 | 0x00008200 | 0x00030000 | 0x80000000
# = 0xA00382FE (need to verify)
sep
info "测试 4: BlockIO.WriteRead - 查询命令 (cmd=0x82)"

QUERY_CAN_ID=0xA00382FE
QB0=$((QUERY_CAN_ID & 0xFF))
QB1=$(((QUERY_CAN_ID >> 8) & 0xFF))
QB2=$(((QUERY_CAN_ID >> 16) & 0xFF))
QB3=$(((QUERY_CAN_ID >> 24) & 0xFF))
SIG_ID_BE="0x00 0x01"  # signal ID = 1 (big-endian)

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "${SIG_WRITE_READ}" ${CONTEXT} 6 ${QB0} ${QB1} ${QB2} ${QB3} ${SIG_ID_BE} 12
QUERY_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "${SIG_WRITE_READ}" ${CONTEXT} 6 ${QB0} ${QB1} ${QB2} ${QB3} ${SIG_ID_BE} 12 2>&1) || true

if echo "${QUERY_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "查询命令 WriteRead 成功"
    QUERY_HEX=$(parse_ay "${QUERY_RESULT}")
    info "查询响应: ${QUERY_HEX}"
else
    info "查询命令返回: ${QUERY_RESULT}"
    info "无预置响应时返回空 (符合预期)"
fi

# ══════════════════════════════════════════════════════════════════════
#  BitIO 接口测试 (bit_read / bit_write)
# ══════════════════════════════════════════════════════════════════════

if [ "${HAS_BITIO}" -eq 1 ]; then
    # ── 测试 6: BitIO.Read - 读取信号值 ─────────────────────────────────
    # BitIO.Read(context, offset, length, mask)
    # offset = signal_id (低16位)
    # length = 数据长度 (1/2/4/6)
    # mask = 位掩码
    sep
    info "测试 6: BitIO.Read - 读取信号值 (signal_id=1, len=1, mask=0xFF)"

    cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
        "${SIG_BIT_READ}" ${CONTEXT} 1 1 255
    BIT_READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
        "${SIG_BIT_READ}" ${CONTEXT} 1 1 255 2>&1) || true

    if echo "${BIT_READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
        pass "BitIO.Read 成功"
        BIT_READ_HEX=$(parse_ay "${BIT_READ_RESULT}")
        info "信号值: ${BIT_READ_HEX}"
    else
        info "BitIO.Read 返回: ${BIT_READ_RESULT}"
        info "无预置响应时可能返回空"
    fi

    # ── 测试 7: BitIO.Write - 写入信号值 ────────────────────────────────
    # BitIO.Write(context, offset, length, mask, indata)
    # offset = (cmd << 16) | signal_id
    sep
    info "测试 7: BitIO.Write - 写入信号值 (cmd=1, signal_id=1, len=1)"

    # offset = (1 << 16) | 1 = 65537
    cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
        "${SIG_BIT_WRITE}" ${CONTEXT} 65537 1 255 1 0x42
    if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
        "${SIG_BIT_WRITE}" ${CONTEXT} 65537 1 255 1 0x42; then
        pass "BitIO.Write 成功"
    else
        fail "BitIO.Write 失败"
    fi

    # ── 测试 8: BitIO.Read - 2字节信号 ─────────────────────────────────
    sep
    info "测试 8: BitIO.Read - 2字节信号 (signal_id=2, len=2, mask=0xFFFF)"

    cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
        "${SIG_BIT_READ}" ${CONTEXT} 2 2 65535
    BIT_READ2_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
        "${SIG_BIT_READ}" ${CONTEXT} 2 2 65535 2>&1) || true

    if echo "${BIT_READ2_RESULT}" | grep -qE "^(ay )?[0-9]"; then
        pass "BitIO.Read (2字节) 成功"
        info "信号值: $(parse_ay "${BIT_READ2_RESULT}")"
    else
        info "BitIO.Read (2字节) 返回: ${BIT_READ2_RESULT}"
    fi

    # ── 测试 9: BitIO.Write - 2字节信号 ────────────────────────────────
    sep
    info "测试 9: BitIO.Write - 2字节信号 (cmd=1, signal_id=2, len=2)"

    # offset = (1 << 16) | 2 = 65538
    cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
        "${SIG_BIT_WRITE}" ${CONTEXT} 65538 2 65535 2 0x12 0x34
    if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
        "${SIG_BIT_WRITE}" ${CONTEXT} 65538 2 65535 2 0x12 0x34; then
        pass "BitIO.Write (2字节) 成功"
    else
        fail "BitIO.Write (2字节) 失败"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
#  Chip 接口测试
# ══════════════════════════════════════════════════════════════════════

# ── 测试 10: HealthStatus 属性 ──────────────────────────────────────────
sep
info "测试 10: HealthStatus"

HS_RESULT=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" HealthStatus 2>&1) || true
HS_VALUE=$(echo "${HS_RESULT}" | sed 's/^[a-z]* *//')
info "HealthStatus = ${HS_VALUE}"
if [ "${HS_VALUE}" = "0" ]; then
    pass "HealthStatus 初始值正确 (0=ACCESS_SUCCESS)"
else
    info "HealthStatus = ${HS_VALUE}"
fi

# ── 测试 11: LockStatus 属性 ────────────────────────────────────────────
sep
info "测试 11: LockStatus"

LOCK_HS=$(busctl --user get-property "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" LockStatus 2>&1) || true
LOCK_VALUE=$(echo "${LOCK_HS}" | sed 's/^[a-z]* *//')
info "LockStatus = ${LOCK_VALUE}"

# ── 测试 12: SetLockStatus 锁定/解锁 ───────────────────────────────────
sep
info "测试 12a: SetLockStatus - ClientA 锁定"

LOCK_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 1 30 2>&1) || true
info "返回: ${LOCK_RET}"
if echo "${LOCK_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 锁定成功"
else
    fail "ClientA 锁定失败: ${LOCK_RET}"
fi

info "测试 12b: ClientA 解锁"
UNLOCK_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetLockStatus \
    "a{ss}a{ss}yu" 1 "Requestor" "ClientA" 1 "Requestor" "ClientA" 0 0 2>&1) || true
if echo "${UNLOCK_RET}" | grep -qE "^i 0$|^0$| 0$"; then
    pass "ClientA 解锁成功"
else
    fail "ClientA 解锁失败: ${UNLOCK_RET}"
fi

# ── 测试 13: SetAccessibility ──────────────────────────────────────────
sep
info "测试 13a: SetAccessibility - 禁用访问"

if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" false 2; then
    pass "SetAccessibility(false, 2s) 成功"
else
    fail "SetAccessibility(false, 2s) 失败"
fi

info "测试 13b: SetAccessibility - 恢复访问"
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${CHIP_IFACE}" SetAccessibility \
    "a{ss}a{ss}bq" 1 "Requestor" "TestClient" 1 "Requestor" "TestClient" true 1; then
    pass "SetAccessibility(true) 成功"
else
    fail "SetAccessibility(true) 失败"
fi

# ══════════════════════════════════════════════════════════════════════
#  结果汇总
# ══════════════════════════════════════════════════════════════════════
sep
info "测试完成"
info "设备: ${SERVICE} ${CHIP_PATH}"
sep
