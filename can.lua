--[[
    CAN Bus Stream 打桩实现
    参考:
      - stream/can.lua         (stream 接口)
      - bus_can/stub/drivers/canbus.cpp (C++ 打桩逻辑)
      - driver/canbus_chip.lua  (CAN 帧协议)

    内存模拟 CAN 总线，用于 canbus_chip 的 Lua 侧功能测试。
    用法: 替换 stream.can 模块，无需修改 driver 层。

    CAN 帧格式:
      [CAN_ID(4 bytes, little-endian)] + [payload(N bytes)]

    CAN_ID 位域:
      bit 0:      cnt       (帧结束标志)
      bits 1-6:   reserve
      bit 7:      ms        (master=1 / slave=0)
      bits 8-15:  cmd
      bits 16-22: addr      (节点地址)
      bits 23-28: protocol
      bits 29-31: frame_type (extended=4)
]]

local class = require 'mc.class'
local stream = require 'stream.base'
local d_common = require 'drvlib_common'
local log = require 'mc.logging'

local s_unpack = string.unpack
local s_pack = string.pack
local s_sub = string.sub
local s_rep = string.rep

local CAN_ID_SLAVE_MASK<const> = 0xFFFFFF7F
local CAN_FRAME_LEN<const> = 8
local CAN_ID_LEN<const> = 4
local DEFAULT_FRAME_LEN<const> = CAN_ID_LEN + CAN_FRAME_LEN  -- 12

-- ── 内存存储 ─────────────────────────────────────────────────────────
-- can_storage:   key=can_id, value=payload (不含 CAN ID 头)
-- response_map:  key=can_id, value=response payload (用于 extend read)
-- 每次写入同时填充 master 和 slave 两个地址，确保不同调用路径都能找到响应
local can_storage = {}
local response_map = {}
local last_write = ''

-- 测试状态
local state = {
    read_count   = 0,
    write_count  = 0,
    reset_count  = 0,
    lock_count   = 0,
    unlock_count = 0,
    last_speed   = 0,
    last_mask_id = 0,
    last_mask    = 0,
}

-- ── 辅助函数 ────────────────────────────────────────────────────────

local function bytes_to_hex(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format('%02X', string.byte(data, i))
    end
    return table.concat(parts, ' ')
end

-- 将 payload 补齐到指定长度 (模拟完整 CAN 帧)
local function pad_frame(can_id, payload, frame_len)
    local frame = s_pack('<I4', can_id) .. payload
    if #frame < frame_len then
        frame = frame .. s_rep('\0', frame_len - #frame)
    end
    return frame
end

-- ── Stream 类 ────────────────────────────────────────────────────────

---@class can:stream
local can = class(stream)

function can:ctor()
    self._multiio = 255
end

function can:init()
    log:error('[CAN STUB] init: id=%s', self.id)
end

function can:close()
    log:error('[CAN STUB] close: id=%s', self.id)
end

-- ── extend_read: 写命令帧 + 读响应帧 ────────────────────────────────
-- 对齐 stream/can.lua:extend_read 接口
-- input.buffer = [CAN_ID(4)] + [payload(N)]
-- input.len    = 期望帧长 (通常为 12)
function can:extend_read(input)
    local can_id = s_unpack('<I4', s_sub(input.buffer, 1, 4))
    local payload = s_sub(input.buffer, 5)
    local slave_can_id = can_id & CAN_ID_SLAVE_MASK
    local frame_len = input.len or DEFAULT_FRAME_LEN

    -- write: 存储到 can_storage，同时填充 response_map (master + slave)
    state.write_count = state.write_count + 1
    can_storage[can_id] = payload
    last_write = input.buffer
    response_map[can_id] = payload
    response_map[slave_can_id] = payload
    log:error('[CAN STUB] write: master=0x%08X slave=0x%08X payload=%d bytes',
        can_id, slave_can_id, #payload)

    -- read: 优先查 response_map，再查 can_storage
    -- 补齐到 frame_len，确保 payload 在协议规定的偏移位置
    state.read_count = state.read_count + 1
    local resp = response_map[can_id]
    if resp then
        local frame = pad_frame(can_id, resp, frame_len)
        log:error('[CAN STUB] read: extend %d bytes for can_id=0x%08X', #frame, can_id)
        return frame
    end
    local data = can_storage[can_id]
    if data then
        local frame = pad_frame(can_id, data, frame_len)
        log:error('[CAN STUB] read: normal %d bytes for can_id=0x%08X', #frame, can_id)
        return frame
    end

    log:error('[CAN STUB] read: no data for can_id=0x%08X, returning zero frame', can_id)
    return s_pack('<I4', can_id) .. s_rep('\0', frame_len - CAN_ID_LEN)
end

-- ── read: 普通读取 / extend 读取分发 ────────────────────────────────
-- 对齐 stream/can.lua:read 接口
function can:read(input)
    log:error('[CAN STUB] read called: offset=%s len=%s buffer=%s',
        tostring(input.offset), tostring(input.len),
        input.buffer and string.format('%d bytes', #input.buffer) or 'nil')
    if input.offset == d_common.HAS_EXTEND_CHIP_READ_MODE then
        return self:extend_read(input)
    end

    -- 普通读取: offset 即为 CAN ID
    state.read_count = state.read_count + 1
    local can_id = input.offset
    local frame_len = input.len or DEFAULT_FRAME_LEN
    local resp = response_map[can_id]
    if resp then
        return pad_frame(can_id, resp, frame_len)
    end
    local data = can_storage[can_id]
    if data then
        return pad_frame(can_id, data, frame_len)
    end
    log:error('[CAN STUB] read: no data for can_id=0x%08X, returning zero frame', can_id)
    return s_pack('<I4', can_id) .. s_rep('\0', frame_len - CAN_ID_LEN)
end

-- ── write: 写入 CAN 帧 ──────────────────────────────────────────────
-- 对齐 stream/can.lua:write 接口
-- input.buffer = [CAN_ID(4)] + [payload(N)]
function can:write(input)
    if not input.buffer then
        error("request error, input buffer is nil")
    end

    state.write_count = state.write_count + 1
    local can_id = s_unpack('<I4', s_sub(input.buffer, 1, 4))
    local payload = s_sub(input.buffer, 5)
    local slave_can_id = can_id & CAN_ID_SLAVE_MASK

    can_storage[can_id] = payload
    last_write = input.buffer
    response_map[can_id] = payload
    response_map[slave_can_id] = payload

    log:error('[CAN STUB] write: master=0x%08X slave=0x%08X payload=%d bytes',
        can_id, slave_can_id, #payload)
end

-- ── reset / set_speed / set_id_mask ──────────────────────────────────

function can:reset()
    state.reset_count = state.reset_count + 1
    log:error('[CAN STUB] reset: count=%s', state.reset_count)
end

function can:set_speed(speed)
    state.last_speed = speed
    log:error('[CAN STUB] set_speed: %s', speed)
end

function can:set_id_mask(id, mask)
    state.last_mask_id = id
    state.last_mask = mask
    log:error('[CAN STUB] set_id_mask: id=0x%08X mask=0x%08X', id, mask)
end

function can:lock()
    state.lock_count = state.lock_count + 1
    log:error('[CAN STUB] lock: count=%s', state.lock_count)
end

function can:unlock()
    state.unlock_count = state.unlock_count + 1
    log:error('[CAN STUB] unlock: count=%s', state.unlock_count)
end

-- ── 测试辅助 (静态方法) ──────────────────────────────────────────────

-- 预置 can_storage 数据 (普通读取测试)
function can.set_can_data(can_id, data)
    can_storage[can_id] = data
    log:error('[CAN STUB] set_can_data: can_id=0x%08X data=%d bytes', can_id, #data)
end

-- 预置 response_map 数据 (extend read 测试)
function can.set_response(can_id, data)
    response_map[can_id] = data
    log:error('[CAN STUB] set_response: can_id=0x%08X data=%d bytes', can_id, #data)
end

-- 获取最后一次写入的完整帧
function can.get_last_write()
    return last_write
end

-- 获取指定 can_id 的存储数据
function can.get_can_data(can_id)
    return can_storage[can_id] or ''
end

-- 获取测试状态快照
function can.get_state()
    return state
end

-- 清空所有存储和状态
function can.clear_storage()
    can_storage = {}
    response_map = {}
    last_write = ''
    state.read_count = 0
    state.write_count = 0
    state.reset_count = 0
    state.lock_count = 0
    state.unlock_count = 0
    log:error('[CAN STUB] clear_storage: all data cleared')
end

-- hex 转储辅助
function can.hex_dump(data)
    return bytes_to_hex(data)
end

return can
