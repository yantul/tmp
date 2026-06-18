#!/bin/sh
# I2C EEPROM 压力测试脚本
# 测试 BlockIO / BitIO 接口的读写性能和稳定性
# 用法: sh test_i2c_eeprom_stress.sh [chip_path] [循环次数]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="${1:-/bmc/kepler/Chip/Complex/Chip_Eeprom_1_01}"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
BITIO_IFACE="bmc.kepler.Chip.BitIO"
LOOP_COUNT="${2:-2000}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass()    { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail()    { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
info()    { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
perf()    { printf "${CYAN}[PERF]${NC} %s\n" "$1"; }
sep()     { echo "══════════════════════════════════════════════════════════════"; }

PASS_COUNT=0
FAIL_COUNT=0

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); pass "$1"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); fail "$1"; }

parse_ay() {
    echo "$1" | sed 's/^ay //' | sed 's/^[0-9]* //' | awk '{for(i=1;i<=NF;i++) printf "%02x ", $i}' | sed 's/ $//'
}

# 获取时间戳 (毫秒)
now_ms() {
    date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))'
}

# 计算耗时
elapsed_ms() {
    echo $(($(now_ms) - $1))
}

# ── 设备检查 ──────────────────────────────────────────────────────────────
sep
info "I2C EEPROM 压力测试"
info "设备: ${SERVICE} ${CHIP_PATH}"
info "循环次数: ${LOOP_COUNT}"
sep

INTROSPECT_RESULT=$(busctl --user introspect "${SERVICE}" "${CHIP_PATH}" 2>&1)
if [ -z "${INTROSPECT_RESULT}" ]; then
    fail "设备不存在或服务未启动"
    exit 1
fi
pass "设备存在"

HAS_BLOCKIO=0
HAS_BITIO=0
echo "${INTROSPECT_RESULT}" | grep -q "${BLOCKIO_IFACE}" && HAS_BLOCKIO=1
echo "${INTROSPECT_RESULT}" | grep -q "${BITIO_IFACE}" && HAS_BITIO=1

# ══════════════════════════════════════════════════════════════════════
#  功能测试
# ══════════════════════════════════════════════════════════════════════

if [ "${HAS_BLOCKIO}" -eq 1 ]; then
    # ── BlockIO 写入→读取一致性 ──────────────────────────────────────────
    sep
    info "BlockIO.Write → Read 一致性测试"
    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
        "a{ss}uay" 0 0 8 170 85 30 123 202 254 17 34 >/dev/null 2>&1
    READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 8 2>&1) || true
    READ_HEX=$(parse_ay "${READ_RESULT}")
    EXPECT_HEX="aa 55 1e 7b ca fe 11 22"
    if [ "${READ_HEX}" = "${EXPECT_HEX}" ]; then
        record_pass "BlockIO 读写一致: ${READ_HEX}"
    else
        record_fail "BlockIO 读写不一致: 预期 ${EXPECT_HEX}, 实际 ${READ_HEX}"
    fi
fi

if [ "${HAS_BITIO}" -eq 1 ]; then
    # ── BitIO 写入→读取一致性 ──────────────────────────────────────────
    sep
    info "BitIO.Write → Read 一致性测试"
    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
        "a{ss}uyuay" 0 256 1 0xff 1 204 >/dev/null 2>&1
    READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
        "a{ss}uyu" 0 256 1 0xff 2>&1) || true
    READ_HEX=$(parse_ay "${READ_RESULT}")
    EXPECT_HEX="cc"
    if [ "${READ_HEX}" = "${EXPECT_HEX}" ]; then
        record_pass "BitIO 读写一致: ${READ_HEX}"
    else
        record_fail "BitIO 读写不一致: 预期 ${EXPECT_HEX}, 实际 ${READ_HEX}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
#  压力测试
# ══════════════════════════════════════════════════════════════════════

if [ "${HAS_BLOCKIO}" -eq 1 ]; then
    # ── 压测 1: BlockIO 单字节读写 ───────────────────────────────────────
    sep
    info "压测 1: BlockIO 单字节读写 x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        OFF=$((i % 4096))
        VAL=$((i % 256))
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "a{ss}uay" 0 "${OFF}" 1 "${VAL}" >/dev/null 2>&1

        RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
            "a{ss}uu" 0 "${OFF}" 1 2>&1) || true
        READ_BYTE=$(parse_ay "${RESULT}" | awk '{print $1}')
        EXPECT=$(printf '%02x' "${VAL}")

        if [ "${READ_BYTE}" != "${EXPECT}" ]; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BlockIO 偏移${OFF}: 写0x${EXPECT} 读0x${READ_BYTE}"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BlockIO 单字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BlockIO 单字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BlockIO 单字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 2: BlockIO 多字节读写 (32字节) ──────────────────────────────
    sep
    info "压测 2: BlockIO 32字节读写 x${LOOP_COUNT}"
    BULK32_DATA=""
    for j in $(seq 0 31); do
        BULK32_DATA="${BULK32_DATA} $((j + 1))"
    done
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        OFF=$((i * 32 % 4096))
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "a{ss}uay" 0 "${OFF}" 32 ${BULK32_DATA} >/dev/null 2>&1

        RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
            "a{ss}uu" 0 "${OFF}" 32 2>&1) || true
        READ_LEN=$(echo "${RESULT}" | sed 's/^ay //' | awk '{print $1}')
        if [ "${READ_LEN}" != "32" ]; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BlockIO 32B 偏移${OFF}: 长度${READ_LEN}!=32"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BlockIO 32字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BlockIO 32字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BlockIO 32字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 3: BlockIO 多字节读写 (64字节) ──────────────────────────────
    sep
    info "压测 3: BlockIO 64字节读写 x${LOOP_COUNT}"
    BULK64_DATA=""
    for j in $(seq 0 63); do
        BULK64_DATA="${BULK64_DATA} $((j % 256))"
    done
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        OFF=$((i * 64 % 2048))
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "a{ss}uay" 0 "${OFF}" 64 ${BULK64_DATA} >/dev/null 2>&1

        RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
            "a{ss}uu" 0 "${OFF}" 64 2>&1) || true
        READ_LEN=$(echo "${RESULT}" | sed 's/^ay //' | awk '{print $1}')
        if [ "${READ_LEN}" != "64" ]; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BlockIO 64B 偏移${OFF}: 长度${READ_LEN}!=64"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BlockIO 64字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BlockIO 64字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BlockIO 64字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"
fi

if [ "${HAS_BITIO}" -eq 1 ]; then
    # ── 压测 4: BitIO 单字节读写 (带 mask) ─────────────────────────────────
    sep
    info "压测 4: BitIO 单字节读写 (mask=0xFF) x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        OFF=$((i % 1024))
        VAL=$((i % 256))
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
            "a{ss}uyuay" 0 "${OFF}" 1 0xff 1 "${VAL}" >/dev/null 2>&1

        RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
            "a{ss}uyu" 0 "${OFF}" 1 0xff 2>&1) || true
        READ_BYTE=$(parse_ay "${RESULT}" | awk '{print $1}')
        EXPECT=$(printf '%02x' "${VAL}")

        if [ "${READ_BYTE}" != "${EXPECT}" ]; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BitIO 偏移${OFF}: 写0x${EXPECT} 读0x${READ_BYTE}"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BitIO 单字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BitIO 单字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BitIO 单字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 5: BitIO 低4位读写 (mask=0x0F) ─────────────────────────────────
    sep
    info "压测 5: BitIO 低4位读写 (mask=0x0F) x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        OFF=$((i % 1024))
        VAL=$((i % 16))  # 只有低4位
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
            "a{ss}uyuay" 0 "${OFF}" 1 0x0f 1 "${VAL}" >/dev/null 2>&1

        RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
            "a{ss}uyu" 0 "${OFF}" 1 0x0f 2>&1) || true
        READ_BYTE=$(parse_ay "${RESULT}" | awk '{print $1}')
        EXPECT=$(printf '%02x' "${VAL}")

        if [ "${READ_BYTE}" != "${EXPECT}" ]; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BitIO(mask=0x0F) 偏移${OFF}: 写0x${EXPECT} 读0x${READ_BYTE}"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BitIO 低4位读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BitIO 低4位读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BitIO 低4位读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"
fi

# ══════════════════════════════════════════════════════════════════════
#  汇总
# ══════════════════════════════════════════════════════════════════════
sep
info "测试汇总"
info "通过: ${PASS_COUNT}  失败: ${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -eq 0 ]; then
    pass "全部测试通过!"
else
    fail "有 ${FAIL_COUNT} 项测试失败"
fi
info "设备: ${SERVICE} ${CHIP_PATH}"
sep
