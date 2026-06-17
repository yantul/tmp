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
-- 传入 driver 实例, 仅对 RTC 驱动替换 read/write 为内存读写
-- 返回原始 read/write 引用, 方便恢复
function M.patch(drv)
    if not is_rtc(drv) then
        return nil, nil
    end

    local object_name = drv.object_name or drv.address or 'rtc'
    local orig_read = drv.read
    local orig_write = drv.write

    -- 写入: 存储到内存
    drv.write = function(self, input)
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

    -- 读取: 从内存返回
    drv.read = function(self, input)
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

    -- 返回原始函数引用, 方便恢复
    return orig_read, orig_write
end

-- ── 恢复函数 ─────────────────────────────────────────────────────────
-- 传入 driver 实例和原始 read/write 引用, 恢复原始行为
function M.restore(drv, orig_read, orig_write)
    if orig_read then drv.read = orig_read end
    if orig_write then drv.write = orig_write end
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
