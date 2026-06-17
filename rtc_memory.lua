--[[
    RTC 内存打桩模块
    参考 chip_base::data_access 中的 RTC 桩实现
    用法: require('driver.stub.rtc_memory').patch(drv)
    不修改原始 driver/base.lua 和 driver/rtc_chip.lua
]]

local log = require 'mc.logging'

local M = {}

-- 静态内存存储 (类似 C++ 的 static map<object_name, map<offset, byte>>)
-- key = "object_name:offset", value = byte value
local memory = {}

-- 生成内存 key
local function mem_key(object_name, offset)
    return object_name .. ':' .. offset
end

-- 判断是否为 RTC 驱动
local function is_rtc(drv)
    local name = drv.object_name or ''
    return name:find('[Rr]tc') ~= nil or name:find('RTC') ~= nil
end

-- ── 核心打桩函数 (所有修改集中在此) ─────────────────────────────────────
-- 传入 driver 实例, 仅对 RTC 驱动设置 _stub_read/_stub_write 标记
-- rtc_chip:read/write 会检查这些标记决定是否走桩
function M.patch(drv)
    if not is_rtc(drv) then
        return
    end

    local object_name = drv.object_name or drv.address or 'rtc'

    -- 写入桩: 存储到内存
    drv._stub_write = function(self, input)
        local offset = input.offset or 0
        local buffer = input.buffer or ''
        local len = #buffer

        log:info('[RTC STUB] WRITE name=%s offset=%s len=%s', object_name, offset, len)

        for i = 1, len do
            memory[mem_key(object_name, offset + i - 1)] = string.byte(buffer, i)
        end

        log:info('[RTC STUB] WRITE data: %s', M.hex_dump(buffer))
        return true
    end

    -- 读取桩: 从内存返回
    drv._stub_read = function(self, input)
        local offset = input.offset or 0
        local len = input.len or input.length or 1

        local parts = {}
        for i = 0, len - 1 do
            local val = memory[mem_key(object_name, offset + i)] or 0x00
            parts[#parts + 1] = string.char(val)
        end
        local result = table.concat(parts)

        log:info('[RTC STUB] READ  name=%s offset=%s len=%s data: %s',
            object_name, offset, len, M.hex_dump(result))
        return result
    end

    log:info('[RTC STUB] patched driver: %s', object_name)
end

-- ── 恢复函数 ─────────────────────────────────────────────────────────
-- 移除桩标记, 恢复原始行为
function M.restore(drv)
    drv._stub_read = nil
    drv._stub_write = nil
    log:info('[RTC STUB] restored driver')
end

-- ── 清空内存 ─────────────────────────────────────────────────────────
function M.clear()
    memory = {}
    log:info('[RTC STUB] memory cleared')
end

-- ── 辅助函数: 十六进制转储 ───────────────────────────────────────────
function M.hex_dump(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format('%02X', string.byte(data, i))
    end
    return table.concat(parts, ' ')
end

return M
