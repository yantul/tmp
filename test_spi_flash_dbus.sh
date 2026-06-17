#!/bin/sh
# SPI Flash D-Bus 功能验证脚本
# 通过 busctl --user 访问 SPIFlash 设备，验证写入→读取一致性
# 用法: sh test_spi_flash_dbus.sh [chip_path]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="${1:-/bmc/kepler/Chip/SPIFlash/SPIFlash_1_01}"
FLASHIO_IFACE="bmc.kepler.Chip.FlashIO"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"

# 测试参数
TEST_OFFSET=256
TEST_DATA="222 173 190 239 1 2 3 4"
TEST_LEN=8

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

# 检查 FlashIO 和 BlockIO 接口是否可用
if echo "${INTROSPECT_RESULT}" | grep -q "${FLASHIO_IFACE}"; then
    pass "FlashIO 接口可用"
else
    info "FlashIO 接口不存在 (跳过 FlashIO 测试)"
fi

if echo "${INTROSPECT_RESULT}" | grep -q "${BLOCKIO_IFACE}"; then
    pass "BlockIO 接口可用"
else
    info "BlockIO 接口不存在 (跳过 BlockIO 测试)"
fi

# ── 测试 1: FlashIO.Write 写入 ────────────────────────────────────────────
sep
info "测试 1: FlashIO.Write - 写入 ${TEST_LEN} 字节到偏移 ${TEST_OFFSET}"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}; then
    pass "Write 成功"
else
    fail "Write 失败"
    exit 1
fi

# ── 测试 2: FlashIO.Read 读回 ─────────────────────────────────────────────
sep
info "测试 2: FlashIO.Read - 从偏移 ${TEST_OFFSET} 读取 ${TEST_LEN} 字节"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Read \
    "a{ss}uu" 0 "${TEST_OFFSET}" "${TEST_LEN}"
READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Read \
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

# ── 测试 4: RawWrite (发送原始 SPI 命令) ──────────────────────────────────
sep
info "测试 4: RawWrite - 发送 SPI Write Enable (0x06)"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" RawWrite \
    "a{ss}ay" 0 1 6
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" RawWrite \
    "a{ss}ay" 0 1 6; then
    pass "RawWrite (WREN) 成功"
else
    fail "RawWrite (WREN) 失败"
fi

# ── 测试 5: RawRead - 读取 SPI 状态寄存器 ──────────────────────────────────
sep
info "测试 5: RawRead - 发送 0x05 读取状态寄存器"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" RawRead \
    "a{ss}uay" 0 1 1 5
RAW_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" RawRead \
    "a{ss}uay" 0 1 1 5 2>&1) || true

if echo "${RAW_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "RawRead 成功"
    info "状态寄存器: ${RAW_RESULT}"
else
    fail "RawRead 失败: ${RAW_RESULT}"
fi

# ── 测试 6: 不同偏移的连续读写 ─────────────────────────────────────────────
sep
info "测试 6: 多偏移连续读写"

OFFSETS="0 256 512 768"
DATA_VALUES="0xAA 0x55 0x1E 0x7B"
set -- ${DATA_VALUES}
for OFF_HEX in ${OFFSETS}; do
    DATA_DEC=$1; shift
    DATA=$(printf '%d' "${DATA_DEC}")
    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Write \
        "a{ss}uay" 0 "${OFF_HEX}" 1 "${DATA}" >/dev/null 2>&1 || true

    RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Read \
        "a{ss}uu" 0 "${OFF_HEX}" 1 2>&1) || true
    READ_BYTE=$(parse_ay "${RESULT}" | awk '{print $1}')

    EXPECT_HEX=$(printf '%02x' "${DATA}")
    if [ "${READ_BYTE}" = "${EXPECT_HEX}" ]; then
        pass "偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} == 读取 0x${READ_BYTE}"
    else
        fail "偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} != 读取 0x${READ_BYTE}"
    fi
done

# ── 测试 7: 超过 32 字节的读写 (验证分块逻辑) ───────────────────────────────
sep
info "测试 7: 读写超过 32 字节 (验证 SPI 分块传输)"

BULK_DATA=""
for i in $(seq 0 47); do
    BULK_DATA="${BULK_DATA} $((i + 16))"
done

info "写入 48 字节..."
cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Write \
    "a{ss}uay" 0 1024 48 ${BULK_DATA}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Write \
    "a{ss}uay" 0 1024 48 ${BULK_DATA}; then
    pass "48 字节 Write 成功"

    BULK_READ=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${FLASHIO_IFACE}" Read \
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
#  BlockIO 接口测试
# ══════════════════════════════════════════════════════════════════════

# ── 测试 8: BlockIO.Write 写入 ────────────────────────────────────────────
sep
info "测试 8: BlockIO.Write - 写入 ${TEST_LEN} 字节到偏移 ${TEST_OFFSET}"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}
if busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 "${TEST_OFFSET}" ${TEST_LEN} ${TEST_DATA}; then
    pass "BlockIO.Write 成功"
else
    fail "BlockIO.Write 失败"
fi

# ── 测试 9: BlockIO.Read 读回 ─────────────────────────────────────────────
sep
info "测试 9: BlockIO.Read - 从偏移 ${TEST_OFFSET} 读取 ${TEST_LEN} 字节"

cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 "${TEST_OFFSET}" "${TEST_LEN}"
BLOCK_READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 "${TEST_OFFSET}" "${TEST_LEN}" 2>&1) || true

if echo "${BLOCK_READ_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "BlockIO.Read 成功"
    BLOCK_ACTUAL_HEX=$(parse_ay "${BLOCK_READ_RESULT}")
    info "读取到: ${BLOCK_ACTUAL_HEX}"
else
    fail "BlockIO.Read 失败: ${BLOCK_READ_RESULT}"
fi

# ── 测试 10: BlockIO 数据一致性校验 ───────────────────────────────────────
sep
info "测试 10: BlockIO 数据一致性校验"

BLOCK_EXPECTED_HEX="de ad be ef 01 02 03 04"
if [ "${BLOCK_EXPECTED_HEX}" = "${BLOCK_ACTUAL_HEX}" ]; then
    pass "BlockIO 数据一致! 写入: ${BLOCK_EXPECTED_HEX} == 读取: ${BLOCK_ACTUAL_HEX}"
else
    fail "BlockIO 数据不一致!"
    fail "预期: ${BLOCK_EXPECTED_HEX}"
    fail "实际: ${BLOCK_ACTUAL_HEX}"
fi

# ── 测试 11: BlockIO.WriteRead (写后读) ───────────────────────────────────
sep
info "测试 11: BlockIO.WriteRead - 写入命令后读取数据"

# 先写入数据到偏移 2048，再通过 WriteRead 读回
BLOCKIO_WR_OFFSET=2048
BLOCKIO_WR_DATA="10 20 30 40"
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 "${BLOCKIO_WR_OFFSET}" 4 ${BLOCKIO_WR_DATA} >/dev/null 2>&1

# WriteRead: 先发送读命令头 (0x03 + 3字节地址)，再读取 4 字节
# 构造 SPI 读命令: cmd=0x03, addr=${BLOCKIO_WR_OFFSET}
SPI_CMD="3 $((BLOCKIO_WR_OFFSET >> 16)) $((BLOCKIO_WR_OFFSET >> 8 & 0xFF)) $((BLOCKIO_WR_OFFSET & 0xFF))"
cmd busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "a{ss}ayu" 0 4 ${SPI_CMD} 4
WR_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
    "a{ss}ayu" 0 4 ${SPI_CMD} 4 2>&1) || true

if echo "${WR_RESULT}" | grep -qE "^(ay )?[0-9]"; then
    pass "BlockIO.WriteRead 成功"
    WR_ACTUAL=$(parse_ay "${WR_RESULT}")
    info "WriteRead 返回: ${WR_ACTUAL}"
    WR_EXPECTED="0a 14 1e 28"
    if [ "${WR_EXPECTED}" = "${WR_ACTUAL}" ]; then
        pass "WriteRead 数据一致! 预期: ${WR_EXPECTED} == 实际: ${WR_ACTUAL}"
    else
        fail "WriteRead 数据不一致! 预期: ${WR_EXPECTED}, 实际: ${WR_ACTUAL}"
    fi
else
    fail "BlockIO.WriteRead 失败: ${WR_RESULT}"
fi

# ── 测试 12: BlockIO 多偏移连续读写 ──────────────────────────────────────
sep
info "测试 12: BlockIO 多偏移连续读写"

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
        pass "BlockIO 偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} == 读取 0x${READ_BYTE}"
    else
        fail "BlockIO 偏移 ${OFF_HEX}: 写入 0x${EXPECT_HEX} != 读取 0x${READ_BYTE}"
    fi
done

# ── 结果汇总 ──────────────────────────────────────────────────────────────
sep
info "测试完成"
info "设备路径: ${SERVICE} ${CHIP_PATH}"
info "Stub 日志请检查 hwproxy 的 stderr 输出 ([SPI WRITE] / [SPI READ])"
sep
