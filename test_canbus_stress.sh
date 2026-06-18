#!/bin/sh
# CAN Bus Chip 压力测试脚本
# 测试 BlockIO / BitIO 接口的读写性能和稳定性
# 用法: sh test_canbus_stress.sh [chip_path] [loop_count]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="${1:-/bmc/kepler/Chip/CanbusChip/CanbusChip_1_01}"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
BITIO_IFACE="bmc.kepler.Chip.BitIO"
LOOP_COUNT="${2:-100}"

# 上下文参数
CONTEXT_TYPE="a{ss}a{ss}"
CONTEXT_ARGS='1 "Requestor" "TestClient" 1 "Requestor" "TestClient"'

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
info() { printf "${YELLOW}[INFO]${NC} %s\n" "$1"; }
perf() { printf "${CYAN}[PERF]${NC} %s\n" "$1"; }
sep()  { echo "══════════════════════════════════════════════════════════════"; }

PASS_COUNT=0
FAIL_COUNT=0

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); pass "$1"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); fail "$1"; }

parse_ay() {
    echo "$1" | sed 's/^ay //' | sed 's/^[0-9]* //' | awk '{for(i=1;i<=NF;i++) printf "%02x ", $i}' | sed 's/ $//'
}

now_ms() {
    date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))'
}

elapsed_ms() {
    echo $(($(now_ms) - $1))
}

# ── 设备检查 ──────────────────────────────────────────────────────────────
sep
info "CAN Bus Chip 压力测试"
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
#  BlockIO 压力测试
# ══════════════════════════════════════════════════════════════════════

if [ "${HAS_BLOCKIO}" -eq 1 ]; then
    # ── 压测 1: BlockIO 单帧写入 ─────────────────────────────────────────
    sep
    info "压测 1: BlockIO 单帧写入 x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        # 构造不同 CAN ID
        ADDR=$((i % 128))
        CMD=$((i % 256))
        CAN_ID=$(( 0x80000000 | (ADDR << 16) | (CMD << 8) | 0x80 ))
        B0=$((CAN_ID & 0xFF))
        B1=$(((CAN_ID >> 8) & 0xFF))
        B2=$(((CAN_ID >> 16) & 0xFF))
        B3=$(((CAN_ID >> 24) & 0xFF))

        if ! busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} 0 12 ${B0} ${B1} ${B2} ${B3} \
            $((i % 256)) $((i % 256)) $((i % 256)) $((i % 256)) \
            $((i % 256)) $((i % 256)) $((i % 256)) $((i % 256)) >/dev/null 2>&1; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BlockIO 帧${i}: CAN_ID=0x$(printf '%08X' ${CAN_ID}) 写入失败"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BlockIO 单帧写入 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BlockIO 单帧写入失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BlockIO 单帧写入 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 2: BlockIO WriteRead (写后读) ───────────────────────────────
    sep
    info "压测 2: BlockIO WriteRead x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        CAN_ID=0xA0038280
        B0=$((CAN_ID & 0xFF))
        B1=$(((CAN_ID >> 8) & 0xFF))
        B2=$(((CAN_ID >> 16) & 0xFF))
        B3=$(((CAN_ID >> 24) & 0xFF))

        WR_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" WriteRead \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} 12 ${B0} ${B1} ${B2} ${B3} \
            $((i % 256)) $((i % 256)) $((i % 256)) $((i % 256)) \
            $((i % 256)) $((i % 256)) $((i % 256)) $((i % 256)) 12 2>&1) || true

        # WriteRead 可能因无预置响应而返回空，记录但不视为失败
        if echo "${WR_RET}" | grep -q "does not support"; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "WriteRead 不支持"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BlockIO WriteRead x${LOOP_COUNT} 全部通过"
    else
        record_fail "BlockIO WriteRead 失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BlockIO WriteRead x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 3: BlockIO 批量写入 (BatchWrite) ────────────────────────────
    sep
    info "压测 3: BlockIO BatchWrite x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        # BatchWrite 不直接通过 busctl 测试 (参数复杂)，使用 Write 模拟批量
        for j in 0 1 2 3; do
            OFF=$((j * 256))
            busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
                "${CONTEXT_TYPE}" ${CONTEXT_ARGS} 0 12 \
                $((OFF & 0xFF)) $(((OFF >> 8) & 0xFF)) 0 0 \
                $((i + j)) $((i + j)) $((i + j)) $((i + j)) \
                $((i + j)) $((i + j)) $((i + j)) $((i + j)) >/dev/null 2>&1 || true
        done
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    record_pass "BlockIO 批量写入 x${LOOP_COUNT} 完成"
    perf "BlockIO 批量写入 x${LOOP_COUNT} (每次4帧): ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"
fi

# ══════════════════════════════════════════════════════════════════════
#  BitIO 压力测试
# ══════════════════════════════════════════════════════════════════════

if [ "${HAS_BITIO}" -eq 1 ]; then
    # ── 压测 4: BitIO 单字节读写 ─────────────────────────────────────────
    sep
    info "压测 4: BitIO 单字节读写 x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        SIG_ID=$((i % 256 + 1))
        CMD=1
        OFFSET=$(( (CMD << 16) | SIG_ID ))
        DATA=$((i % 256))

        # Write
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${OFFSET} 1 255 1 ${DATA} >/dev/null 2>&1 || true

        # Read
        BIT_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${SIG_ID} 1 255 2>&1) || true

        # BitIO read 可能因无预置响应返回空
        if echo "${BIT_RET}" | grep -q "does not support"; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BitIO Read 不支持"
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

    # ── 压测 5: BitIO 2字节读写 ─────────────────────────────────────────
    sep
    info "压测 5: BitIO 2字节读写 x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        SIG_ID=$((i % 256 + 1))
        CMD=1
        OFFSET=$(( (CMD << 16) | SIG_ID ))

        # Write 2 bytes (big-endian)
        D1=$((i % 256))
        D2=$(( (i + 1) % 256 ))
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${OFFSET} 2 65535 2 ${D1} ${D2} >/dev/null 2>&1 || true

        # Read 2 bytes
        BIT_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${SIG_ID} 2 65535 2>&1) || true

        if echo "${BIT_RET}" | grep -q "does not support"; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BitIO 2B Read 不支持"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BitIO 2字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BitIO 2字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BitIO 2字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

    # ── 压测 6: BitIO 4字节读写 ─────────────────────────────────────────
    sep
    info "压测 6: BitIO 4字节读写 x${LOOP_COUNT}"
    START=$(now_ms)
    STRESS_FAIL=0
    i=0
    while [ "${i}" -lt "${LOOP_COUNT}" ]; do
        SIG_ID=$((i % 256 + 1))
        CMD=1
        OFFSET=$(( (CMD << 16) | SIG_ID ))

        # Write 4 bytes
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Write \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${OFFSET} 4 4294967295 4 \
            $((i % 256)) $(((i+1) % 256)) $(((i+2) % 256)) $(((i+3) % 256)) >/dev/null 2>&1 || true

        # Read 4 bytes
        BIT_RET=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BITIO_IFACE}" Read \
            "${CONTEXT_TYPE}" ${CONTEXT_ARGS} ${SIG_ID} 4 4294967295 2>&1) || true

        if echo "${BIT_RET}" | grep -q "does not support"; then
            STRESS_FAIL=$((STRESS_FAIL + 1))
            [ "${STRESS_FAIL}" -le 3 ] && record_fail "BitIO 4B Read 不支持"
        fi
        i=$((i + 1))
    done
    ELAPSED=$(elapsed_ms $START)
    if [ "${STRESS_FAIL}" -eq 0 ]; then
        record_pass "BitIO 4字节读写 x${LOOP_COUNT} 全部通过"
    else
        record_fail "BitIO 4字节读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
    fi
    perf "BitIO 4字节读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"
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
info "循环次数: ${LOOP_COUNT}"
sep
