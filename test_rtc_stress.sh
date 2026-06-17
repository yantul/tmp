#!/bin/sh
# RTC 压力测试脚本
# 用法: sh test_rtc_stress.sh [循环次数]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
CHIP_PATH="/bmc/kepler/Chip/Rtc/Rtc_1_01"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
LOOP_COUNT="${1:-5000}"

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

now_ms() {
    date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))'
}

elapsed_ms() {
    echo $(($(now_ms) - $1))
}

# ── 设备检查 ──────────────────────────────────────────────────────────────
sep
info "RTC 压力测试"
info "设备: ${SERVICE} ${CHIP_PATH}"
info "循环次数: ${LOOP_COUNT}"
sep

INTROSPECT_RESULT=$(busctl --user introspect "${SERVICE}" "${CHIP_PATH}" 2>&1)
if [ -z "${INTROSPECT_RESULT}" ]; then
    fail "设备不存在或服务未启动"
    exit 1
fi
pass "设备存在"

# ══════════════════════════════════════════════════════════════════════
#  功能测试
# ══════════════════════════════════════════════════════════════════════

# ── 写入→读取一致性 ──────────────────────────────────────────────────────
sep
info "功能测试: BlockIO 写入→读取一致性"

# 写入 2026-06-17 Tue 14:30:45, 读回验证时间字段
busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45 >/dev/null 2>&1

READ_RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
    "a{ss}uu" 0 0 8 2>&1) || true
READ_HEX=$(parse_ay "${READ_RESULT}")

# 验证秒=0x2d, 分=0x1e, 时=0x0e
R_SEC=$(echo "${READ_HEX}" | awk '{print $8}')
R_MIN=$(echo "${READ_HEX}" | awk '{print $7}')
R_HOUR=$(echo "${READ_HEX}" | awk '{print $6}')
if [ "${R_SEC}" = "2d" ] && [ "${R_MIN}" = "1e" ] && [ "${R_HOUR}" = "0e" ]; then
    record_pass "时间写入→读取一致: sec=${R_SEC} min=${R_MIN} hr=${R_HOUR}"
else
    record_fail "时间不一致! sec=${R_SEC}(e2d) min=${R_MIN}(e1e) hr=${R_HOUR}(e0e)"
fi

# ══════════════════════════════════════════════════════════════════════
#  压力测试
# ══════════════════════════════════════════════════════════════════════

# ── 压测 1: 不同时间写入→读取验证 (BCD 编解码) ─────────────────────────
sep
info "压测 1: 不同时间写入→读取 x${LOOP_COUNT}"
START=$(now_ms)
STRESS_FAIL=0
i=0
while [ "${i}" -lt "${LOOP_COUNT}" ]; do
    SEC=$((i % 60))
    MIN=$((i % 60))
    HOUR=$((i % 24))
    DAY=$((i % 28 + 1))
    MON=$((i % 12 + 1))
    # 使用有效年份 2000-2099
    YEAR=$((2000 + i % 100))
    YEAR_LO=$((YEAR % 256))
    YEAR_HI=$((YEAR / 256))
    WDAY=$((i % 7 + 1))

    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
        "a{ss}uay" 0 0 8 ${YEAR_LO} ${YEAR_HI} ${MON} ${DAY} ${WDAY} ${HOUR} ${MIN} ${SEC} >/dev/null 2>&1

    RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 8 2>&1) || true
    READ_HEX=$(parse_ay "${RESULT}")

    # 验证解码后的秒、分、时、日、月是否正确 (BCD 编解码)
    R_SEC=$(echo "${READ_HEX}" | awk '{print $8}')
    R_MIN=$(echo "${READ_HEX}" | awk '{print $7}')
    R_HOUR=$(echo "${READ_HEX}" | awk '{print $6}')
    R_DAY=$(echo "${READ_HEX}" | awk '{print $4}')
    R_MON=$(echo "${READ_HEX}" | awk '{print $3}')

    EXPECT_SEC=$(printf '%02x' ${SEC})
    EXPECT_MIN=$(printf '%02x' ${MIN})
    EXPECT_HOUR=$(printf '%02x' ${HOUR})
    EXPECT_DAY=$(printf '%02x' ${DAY})
    EXPECT_MON=$(printf '%02x' ${MON})

    if [ "${R_SEC}" != "${EXPECT_SEC}" ] || [ "${R_MIN}" != "${EXPECT_MIN}" ] || \
       [ "${R_HOUR}" != "${EXPECT_HOUR}" ] || [ "${R_DAY}" != "${EXPECT_DAY}" ] || \
       [ "${R_MON}" != "${EXPECT_MON}" ]; then
        STRESS_FAIL=$((STRESS_FAIL + 1))
        [ "${STRESS_FAIL}" -le 3 ] && record_fail "#${i}: sec=${R_SEC}(e${EXPECT_SEC}) min=${R_MIN}(e${EXPECT_MIN}) hr=${R_HOUR}(e${EXPECT_HOUR})"
    fi
    i=$((i + 1))
done
ELAPSED=$(elapsed_ms $START)
if [ "${STRESS_FAIL}" -eq 0 ]; then
    record_pass "不同时间写入→读取 x${LOOP_COUNT} 全部通过"
else
    record_fail "不同时间写入→读取失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
fi
perf "不同时间写入→读取 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

# ── 压测 2: 相同时间反复读写 ────────────────────────────────────────────
sep
info "压测 2: 相同时间反复读写 x${LOOP_COUNT}"
START=$(now_ms)
STRESS_FAIL=0
i=0
while [ "${i}" -lt "${LOOP_COUNT}" ]; do
    # 写入 2026-06-17 Tue 14:30:45
    busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
        "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45 >/dev/null 2>&1

    RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 8 2>&1) || true
    READ_HEX=$(parse_ay "${RESULT}")

    # 验证秒=0x2d, 分=0x1e, 时=0x0e
    R_SEC=$(echo "${READ_HEX}" | awk '{print $8}')
    R_MIN=$(echo "${READ_HEX}" | awk '{print $7}')
    R_HOUR=$(echo "${READ_HEX}" | awk '{print $6}')

    if [ "${R_SEC}" != "2d" ] || [ "${R_MIN}" != "1e" ] || [ "${R_HOUR}" != "0e" ]; then
        STRESS_FAIL=$((STRESS_FAIL + 1))
        [ "${STRESS_FAIL}" -le 3 ] && record_fail "#${i}: sec=${R_SEC} min=${R_MIN} hr=${R_HOUR}"
    fi
    i=$((i + 1))
done
ELAPSED=$(elapsed_ms $START)
if [ "${STRESS_FAIL}" -eq 0 ]; then
    record_pass "相同时间反复读写 x${LOOP_COUNT} 全部通过"
else
    record_fail "相同时间反复读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
fi
perf "相同时间反复读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

# ── 压测 3: 交替时间读写 ───────────────────────────────────────────────
sep
info "压测 3: 交替时间读写 x${LOOP_COUNT}"
START=$(now_ms)
STRESS_FAIL=0
i=0
while [ "${i}" -lt "${LOOP_COUNT}" ]; do
    if [ $((i % 2)) -eq 0 ]; then
        # 写入 2000-01-01 00:00:00
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "a{ss}uay" 0 0 8 0 7 1 1 6 0 0 0 >/dev/null 2>&1
        EXPECT_SEC="00"; EXPECT_MIN="00"; EXPECT_HOUR="00"
    else
        # 写入 2026-06-17 14:30:45
        busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Write \
            "a{ss}uay" 0 0 8 234 7 6 17 2 14 30 45 >/dev/null 2>&1
        EXPECT_SEC="2d"; EXPECT_MIN="1e"; EXPECT_HOUR="0e"
    fi

    RESULT=$(busctl --user call "${SERVICE}" "${CHIP_PATH}" "${BLOCKIO_IFACE}" Read \
        "a{ss}uu" 0 0 8 2>&1) || true
    READ_HEX=$(parse_ay "${RESULT}")
    R_SEC=$(echo "${READ_HEX}" | awk '{print $8}')
    R_MIN=$(echo "${READ_HEX}" | awk '{print $7}')
    R_HOUR=$(echo "${READ_HEX}" | awk '{print $6}')

    if [ "${R_SEC}" != "${EXPECT_SEC}" ] || [ "${R_MIN}" != "${EXPECT_MIN}" ] || [ "${R_HOUR}" != "${EXPECT_HOUR}" ]; then
        STRESS_FAIL=$((STRESS_FAIL + 1))
        [ "${STRESS_FAIL}" -le 3 ] && record_fail "#${i}: sec=${R_SEC}(e${EXPECT_SEC}) min=${R_MIN}(e${EXPECT_MIN}) hr=${R_HOUR}(e${EXPECT_HOUR})"
    fi
    i=$((i + 1))
done
ELAPSED=$(elapsed_ms $START)
if [ "${STRESS_FAIL}" -eq 0 ]; then
    record_pass "交替时间读写 x${LOOP_COUNT} 全部通过"
else
    record_fail "交替时间读写失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
fi
perf "交替时间读写 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"

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
