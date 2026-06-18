--[[
    JTAG over Hisport2 驱动打桩实现 (Lua)
    模拟 JTAG 操作，用于 chip_cpld 的功能测试

    用法: 替换 stream.jtag_over_hisport 模块，使 JTAG 基于内存模拟工作
]]

local class = require 'mc.class'
local stream = require 'stream.base'
local log = require 'mc.logging'

-- ── CPLD 升级模式定义 ──────────────────────────────────────────────────
local CPLD_UPG_BY_GPIO = 0
local CPLD_UPG_BY_CPLD = 1
local CPLD_UPG_BY_JLC  = 2

-- ── 模拟 JTAG 设备存储 ─────────────────────────────────────────────────
-- 存储每个 component_id 的 IDCODE
local device_ids = {}
-- 存储每个 component_id 的 bypass 状态
local bypass_states = {}
-- 存储每个 component_id 的 target num
local target_nums = {}
-- 默认 IDCODE 值
local DEFAULT_IDCODE = 0x12345678

-- ── 辅助函数 ────────────────────────────────────────────────────────────
local function get_device_id(component_id)
    if not device_ids[component_id] then
        device_ids[component_id] = {DEFAULT_IDCODE}
    end
    return device_ids[component_id]
end

local function bytes_to_hex(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(parts, " ")
end

-- ── 桩驱动类定义 ────────────────────────────────────────────────────────

---@class jtag_over_hisport:stream
local jtag_over_hisport = class(stream)

function jtag_over_hisport:ctor(property, bus_name)
    self.id = property.Id
    self.channel_id = property.ChannelId or 0
    self.bus_name = bus_name or ("JtagOverHisport_" .. tostring(property.Id))
    -- component_id = 5 + id * 2 + channel_id
    self.component_id = 5 + self.id * 2 + self.channel_id
    self.reset_gpio = property.TargetResetGpio or -1
    self.validate_time = property.ValidateTime or 1000

    log:info('[JTAG STUB] ctor: bus_name=%s, id=%s, channel_id=%s, component_id=%s',
        self.bus_name, self.id, self.channel_id, self.component_id)
end

-- ── init: 初始化驱动桩 ──────────────────────────────────────────────────
function jtag_over_hisport:init()
    log:info('[JTAG STUB] init: component_id=%s', self.component_id)
    return true
end

-- ── lock / unlock ────────────────────────────────────────────────────────
function jtag_over_hisport:lock()
    log:info('[JTAG STUB] lock: component_id=%s', self.component_id)
end

function jtag_over_hisport:unlock()
    log:info('[JTAG STUB] unlock: component_id=%s', self.component_id)
end

-- ── get_cpld_id: 获取 CPLD IDCODE ────────────────────────────────────────
function jtag_over_hisport:get_cpld_id()
    local ids = get_device_id(self.component_id)
    log:info('[JTAG STUB] get_cpld_id: component_id=%s, ids=%s',
        self.component_id, table.concat(ids, ", "))
    return ids
end

-- ── write: 写入 JTAG 数据 ────────────────────────────────────────────────
function jtag_over_hisport:write(input)
    if not input or not input.in_buffer or #input.in_buffer < 27 then
        log:info('[JTAG STUB] write: buffer too small')
        return
    end

    local buf = input.in_buffer

    -- 解析 buffer
    local mode = string.byte(buf, 1) | (string.byte(buf, 2) << 8) |
                 (string.byte(buf, 3) << 16) | (string.byte(buf, 4) << 24)
    local product_id = string.byte(buf, 5) | (string.byte(buf, 6) << 8) |
                       (string.byte(buf, 7) << 16) | (string.byte(buf, 8) << 24)
    local board_id = string.byte(buf, 9) | (string.byte(buf, 10) << 8) |
                     (string.byte(buf, 11) << 16) | (string.byte(buf, 12) << 24)
    local pcb = string.byte(buf, 13) | (string.byte(buf, 14) << 8) |
                (string.byte(buf, 15) << 16) | (string.byte(buf, 16) << 24)
    local component_id = string.byte(buf, 17) | (string.byte(buf, 18) << 8) |
                         (string.byte(buf, 19) << 16) | (string.byte(buf, 20) << 24)

    local file_type = string.sub(buf, 21, 23)
    local filename_len = string.byte(buf, 24) | (string.byte(buf, 25) << 8) |
                         (string.byte(buf, 26) << 16) | (string.byte(buf, 27) << 24)

    local filename = ""
    if #buf >= 27 + filename_len then
        filename = string.sub(buf, 28, 27 + filename_len)
    end

    log:info('[JTAG STUB] write: mode=%s, product_id=%s, component_id=%s, file_type=%s, filename=%s',
        mode, product_id, component_id, file_type, filename)

    -- 模拟升级操作
    if mode == 1 then
        log:info('[JTAG STUB] write: reset after upgrade, validate_time=%sms', self.validate_time)
    end
end

-- ── check_bypass_channel: 检查 Bypass 通道 ──────────────────────────────
function jtag_over_hisport:check_bypass_channel(chip_id, jtag_channel)
    log:info('[JTAG STUB] check_bypass_channel: chip_id=%s, channel=%s', chip_id, jtag_channel)
    -- 默认返回 true，表示通道正常
    return true
end

-- ── set_num: 设置目标编号 ────────────────────────────────────────────────
function jtag_over_hisport:set_num(num)
    target_nums[self.component_id] = num
    log:info('[JTAG STUB] set_num: component_id=%s, num=%s', self.component_id, num)
end

-- ── set_bypass_mode: 设置 Bypass 模式 ────────────────────────────────────
function jtag_over_hisport:set_bypass_mode(enable)
    bypass_states[self.component_id] = enable
    log:info('[JTAG STUB] set_bypass_mode: component_id=%s, enable=%s', self.component_id, enable)
end

-- ── upgrade: 升级固件 ────────────────────────────────────────────────────
function jtag_over_hisport:upgrade(filename, file_type)
    log:info('[JTAG STUB] upgrade: filename=%s, file_type=%s', filename, file_type)
    -- 模拟升级成功
end

-- ── verify: 验证固件 ─────────────────────────────────────────────────────
function jtag_over_hisport:verify(filename, file_type)
    log:info('[JTAG STUB] verify: filename=%s, file_type=%s', filename, file_type)
    -- 模拟验证成功
end

-- ── collect: 采集数据 ────────────────────────────────────────────────────
function jtag_over_hisport:collect(input_file_path, file_type, output_file_path)
    log:info('[JTAG STUB] collect: input=%s, file_type=%s, output=%s',
        input_file_path, file_type, output_file_path)
    -- 返回模拟的采集数据
    return "collect-output-data"
end

-- ── read: 读取数据 (JTAG 不支持) ─────────────────────────────────────────
function jtag_over_hisport:read(input)
    log:info('[JTAG STUB] read: not supported for JTAG')
    return ""
end

-- ── 方法别名，兼容不同调用方式 ──────────────────────────────────────────
jtag_over_hisport.get_id = jtag_over_hisport.get_cpld_id

return jtag_over_hisport
