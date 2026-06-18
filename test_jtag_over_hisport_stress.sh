#!/bin/sh
# JtagOverHisport 压力测试脚本
# 测试 BlockIO.Write 接口的性能和稳定性
# 注意: CPLD 不支持 BlockIO.Read 和 BitIO 接口
#       BlockIO.Write 单次写入数据必须大于32字节
#       BlockIO.Write 需要写入 SVF 文件路径，该文件必须存在
# 用法: sh test_jtag_over_hisport_stress.sh [cpld_path] [循环次数]

# ── 配置 ──────────────────────────────────────────────────────────────────
SERVICE="bmc.kepler.hwproxy"
BUS_PATH="/bmc/kepler/Bus/JtagOverHisport/JtagOverHisport_1"
CPLD_PATH="${1:-/bmc/kepler/Chip/Cpld/Cpld_2_01}"
BLOCKIO_IFACE="bmc.kepler.Chip.BlockIO"
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
info "JtagOverHisport BlockIO.Write 压力测试"
info "总线路径: ${SERVICE} ${BUS_PATH}"
info "CPLD路径: ${SERVICE} ${CPLD_PATH}"
info "循环次数: ${LOOP_COUNT}"
sep

# 检查 CPLD 芯片
CPLD_INTROSPECT=$(busctl --user introspect "${SERVICE}" "${CPLD_PATH}" 2>&1)
if [ -z "${CPLD_INTROSPECT}" ]; then
    fail "CPLD 芯片不存在或服务未启动"
    exit 1
fi
pass "CPLD 芯片存在"

HAS_BLOCKIO=0
echo "${CPLD_INTROSPECT}" | grep -q "${BLOCKIO_IFACE}" && HAS_BLOCKIO=1

if [ "${HAS_BLOCKIO}" -eq 0 ]; then
    fail "BlockIO 接口不可用"
    exit 1
fi
pass "BlockIO 接口可用"

# ── 准备测试文件 ──────────────────────────────────────────────────────
# BlockIO.Write 需要写入 SVF 文件路径，该文件必须存在
SVF_FILE="/tmp/test.svf"
touch "${SVF_FILE}" 2>/dev/null
if [ -f "${SVF_FILE}" ]; then
    pass "测试文件创建成功: ${SVF_FILE}"
else
    fail "测试文件创建失败: ${SVF_FILE}"
    exit 1
fi

# SVF 文件路径数据包: "/tmp/test.svf" 的 ASCII 编码 (十进制)
# 47='/' 116='t' 109='m' 112='p' 47='/' 116='t' 101='e' 115='s' 116='t' 46='.' 115='s' 118='v' 102='f'
SVF_PATH_BYTES="0 0 0 0 0 0 0 0 0 0 0 0 67 0 0 0 0 0 0 0 49 0 0 13 0 0 0 47 116 109 112 47 116 101 115 116 46 115 118 102"

# ══════════════════════════════════════════════════════════════════════
#  功能验证
# ══════════════════════════════════════════════════════════════════════

sep
info "BlockIO.Write 功能验证"

if busctl --user call "${SERVICE}" "${CPLD_PATH}" "${BLOCKIO_IFACE}" Write \
    "a{ss}uay" 0 0 40 ${SVF_PATH_BYTES} 2>/dev/null; then
    record_pass "BlockIO.Write (40字节) 成功"
else
    record_fail "BlockIO.Write (40字节) 失败"
fi

# ══════════════════════════════════════════════════════════════════════
#  压力测试
# ══════════════════════════════════════════════════════════════════════

# ── 压测 1: BlockIO 40字节写入 ────────────────────────────────────────
sep
info "压测 1: BlockIO 40字节写入 x${LOOP_COUNT}"

START=$(now_ms)
STRESS_FAIL=0
i=0
while [ "${i}" -lt "${LOOP_COUNT}" ]; do
    if ! busctl --user call "${SERVICE}" "${CPLD_PATH}" "${BLOCKIO_IFACE}" Write \
        "a{ss}uay" 0 0 40 ${SVF_PATH_BYTES} >/dev/null 2>&1; then
        STRESS_FAIL=$((STRESS_FAIL + 1))
        [ "${STRESS_FAIL}" -le 3 ] && record_fail "BlockIO 40B 写入失败"
    fi
    i=$((i + 1))
done
ELAPSED=$(elapsed_ms $START)
if [ "${STRESS_FAIL}" -eq 0 ]; then
    record_pass "BlockIO 40字节写入 x${LOOP_COUNT} 全部通过"
else
    record_fail "BlockIO 40字节写入失败 ${STRESS_FAIL}/${LOOP_COUNT} 次"
fi
perf "BlockIO 40字节写入 x${LOOP_COUNT}: ${ELAPSED}ms (平均 $((ELAPSED / LOOP_COUNT))ms/次)"


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
info "总线路径: ${SERVICE} ${BUS_PATH}"
info "CPLD路径: ${SERVICE} ${CPLD_PATH}"
sep

# ── 清理测试文件 ──────────────────────────────────────────────────────
rm -f "${SVF_FILE}" 2>/dev/null
info "测试文件已清理"