--[[
    Hisport2 驱动打桩实现 (Lua)
    参考 drivers/internal/bus/bus_hisport2/stub/drivers/hisport2.cpp
    模拟 SPI Flash 存储，用于 chip_spi_flash 的功能测试

    用法: 替换 stream.hisport2 模块，使 spi_over_hisport 基于内存 Flash 工作
]]

local class = require 'mc.class'
local stream = require 'stream.base'
local utils = require 'mc.utils'
local log = require 'mc.logging'

-- ── SPI Flash 命令定义 ──────────────────────────────────────────────
local SPI_CMD_WRITE_ENABLE       = 0x06
local SPI_CMD_READ_STATUS        = 0x05
local SPI_CMD_READ_DATA          = 0x03
local SPI_CMD_READ_DATA_4BYTE    = 0x13
local SPI_CMD_PAGE_PROGRAM       = 0x02
local SPI_CMD_PAGE_PROGRAM_4BYTE = 0x12
local SPI_CMD_SECTOR_ERASE       = 0x20
local SPI_CMD_SECTOR_ERASE_4BYTE = 0x21
local SPI_CMD_BLOCK_32K_ERASE    = 0x52
local SPI_CMD_BLOCK_64K_ERASE    = 0xD8
local SPI_CMD_CHIP_ERASE         = 0x60
local SPI_CMD_ENABLE_4BYTE       = 0xB7
local SPI_CMD_DISABLE_4BYTE      = 0xE9

-- 擦除大小
local SECTOR_ERSE_SIZE   = 4 * 1024      -- 4KB
local BLOCK_32K_ERSE_SIZE = 32 * 1024    -- 32KB
local BLOCK_64K_ERSE_SIZE = 64 * 1024    -- 64KB

-- 默认模拟 Flash 大小 (256KB)
local SIMULATED_FLASH_SIZE = 256 * 1024

-- 默认模拟 I2C 设备存储大小 (64KB)
local SIMULATED_I2C_SIZE = 64 * 1024

-- ── 模拟 Flash 存储 ─────────────────────────────────────────────────
-- key = (channel << 8) | cs
local flash_storage = {}
local write_enable_latch = false
local four_byte_mode = false

-- ── 模拟 I2C 存储 ─────────────────────────────────────────────────
-- key = (channel << 8) | addr
local i2c_storage = {}

local function get_flash_storage(key)
    if not flash_storage[key] then
        local data = {}
        for i = 0, SIMULATED_FLASH_SIZE - 1 do
            data[i] = 0xFF
        end
        flash_storage[key] = data
    end
    return flash_storage[key]
end

local function get_i2c_storage(key)
    if not i2c_storage[key] then
        local data = {}
        for i = 0, SIMULATED_I2C_SIZE - 1 do
            data[i] = 0xFF
        end
        i2c_storage[key] = data
    end
    return i2c_storage[key]
end

-- ── 辅助函数 ────────────────────────────────────────────────────────
local function get_cmd_name(cmd)
    local names = {
        [SPI_CMD_WRITE_ENABLE]       = "WRITE_ENABLE(0x06)",
        [SPI_CMD_READ_STATUS]        = "READ_STATUS(0x05)",
        [SPI_CMD_READ_DATA]          = "READ_DATA(0x03)",
        [SPI_CMD_READ_DATA_4BYTE]    = "READ_DATA_4BYTE(0x13)",
        [SPI_CMD_PAGE_PROGRAM]       = "PAGE_PROGRAM(0x02)",
        [SPI_CMD_PAGE_PROGRAM_4BYTE] = "PAGE_PROGRAM_4BYTE(0x12)",
        [SPI_CMD_SECTOR_ERASE]       = "SECTOR_ERASE(0x20)",
        [SPI_CMD_SECTOR_ERASE_4BYTE] = "SECTOR_ERASE_4BYTE(0x21)",
        [SPI_CMD_BLOCK_32K_ERASE]    = "BLOCK_32K_ERASE(0x52)",
        [SPI_CMD_BLOCK_64K_ERASE]    = "BLOCK_64K_ERASE(0xD8)",
        [SPI_CMD_CHIP_ERASE]         = "CHIP_ERASE(0x60)",
        [SPI_CMD_ENABLE_4BYTE]       = "ENABLE_4BYTE_ADDR(0xB7)",
        [SPI_CMD_DISABLE_4BYTE]      = "DISABLE_4BYTE_ADDR(0xE9)",
    }
    return names[cmd] or "UNKNOWN"
end

-- 擦除 Flash 区域 (填充 0xFF)
local function erase_flash(flash, addr, size)
    local aligned_addr = addr - (addr % size)
    for i = 0, size - 1 do
        local idx = aligned_addr + i
        if idx < SIMULATED_FLASH_SIZE then
            flash[idx] = 0xFF
        end
    end
end

local function bytes_to_hex(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", string.byte(data, i))
    end
    return table.concat(parts, " ")
end

-- ── 桩驱动类定义 ─────────────────────────────────────────────────────

---@class hisport2:stream
local hisport2 = class(stream)

-- HISPORT_INFO_S 结构体桩
local HISPORT_INFO_S = {}
HISPORT_INFO_S.__index = HISPORT_INFO_S

function HISPORT_INFO_S.new()
    return setmetatable({
        en_mode = 0,
        nego_max_speed = 0,
    }, HISPORT_INFO_S)
end

-- HISPORT_SPI_INFO 结构体桩
local HISPORT_SPI_INFO = {}
HISPORT_SPI_INFO.__index = HISPORT_SPI_INFO

function HISPORT_SPI_INFO.new()
    return setmetatable({
        channel = 0,
        cs = 0,
        w_buf = nil,
        w_len = 0,
        r_buf = nil,
        r_len = 0,
        timeout = 100,
    }, HISPORT_SPI_INFO)
end

-- HISPORT_I2C_INFO 结构体桩
local HISPORT_I2C_INFO = {}
HISPORT_I2C_INFO.__index = HISPORT_I2C_INFO

function HISPORT_I2C_INFO.new()
    return setmetatable({
        channel = 0,
        offset_width = 0,
        retry_cnt = 1,
        addr = 0,
        offset = 0,
        w_buf = nil,
        w_len = 0,
        r_buf = nil,
        r_len = 0,
        timeout = 100,
    }, HISPORT_I2C_INFO)
end

-- 导出结构体供 spi_over_hisport 使用
hisport2.HISPORT_INFO_S = HISPORT_INFO_S
hisport2.HISPORT_SPI_INFO = HISPORT_SPI_INFO
hisport2.HISPORT_I2C_INFO = HISPORT_I2C_INFO

function hisport2:ctor(property, bus_name)
    self.id = property.Id
    self.channel_id = property.channelId
    self.bus_name = bus_name or ("Hisport2_" .. tostring(property.Id))
    -- spi_over_hisport 通过 self.drv 访问驱动接口 (HISPORT_SPI_INFO, spi_read, spi_write)
    -- 桩模式下将自身作为驱动对象
    self.drv = self
    log:info('[SPI STUB] init: bus_name=%s, id=%s', self.bus_name, self.id)
end

-- ── init: 初始化驱动桩 ──────────────────────────────────────────────
function hisport2:init(init_info)
    if not init_info then
        log:info('[SPI STUB] init: init_info is nil, skip')
        return
    end
    log:info('[SPI STUB] init: en_mode=0x%02x, nego_max_speed=%s',
        init_info.en_mode or 0, init_info.nego_max_speed or 0)
end

-- ── lock / unlock ───────────────────────────────────────────────────
function hisport2:lock()
    -- 桩实现，无需实际加锁
end

function hisport2:unlock()
    -- 桩实现，无需实际解锁
end

-- ── spi_read: SPI 读取桩 ────────────────────────────────────────────
function hisport2:spi_read(info, in_data)
    if not info then
        log:info('[SPI STUB] spi_read: info is nil')
        return ''
    end
    local channel = info.channel or 0
    local cs = info.cs or 0
    local r_len = info.r_len or 0
    local key = (channel << 8) + cs
    local flash = get_flash_storage(key)

    log:info('[SPI READ]  ch=%s cs=%s r_len=%s', channel, cs, r_len)

    -- 解析 in_data 中的命令头
    local cmd = 0
    if in_data and #in_data > 0 then
        cmd = string.byte(in_data, 1)
        log:info('[SPI READ]  cmd=%s', get_cmd_name(cmd))
    end

    local result = ""

    if cmd == SPI_CMD_READ_STATUS then
        -- 返回状态寄存器: bit0=WIP=0 (空闲), bit1=WEL=1 (写使能已锁存)
        local status = write_enable_latch and 0x02 or 0x00
        result = string.char(status)
        log:info('[SPI READ]  STATUS=0x%02x (WEL=%s)', status, write_enable_latch)

    elseif cmd == SPI_CMD_READ_DATA or cmd == SPI_CMD_READ_DATA_4BYTE then
        -- 解析地址
        local addr = 0
        if cmd == SPI_CMD_READ_DATA and #in_data >= 4 then
            addr = (string.byte(in_data, 2) << 16)
                 + (string.byte(in_data, 3) << 8)
                 + string.byte(in_data, 4)
        elseif cmd == SPI_CMD_READ_DATA_4BYTE and #in_data >= 5 then
            addr = (string.byte(in_data, 2) << 24)
                 + (string.byte(in_data, 3) << 16)
                 + (string.byte(in_data, 4) << 8)
                 + string.byte(in_data, 5)
        end

        log:info('[SPI READ]  addr=0x%06x, read_len=%s', addr, r_len)

        -- 从模拟 Flash 读取
        local parts = {}
        for i = 0, r_len - 1 do
            local idx = addr + i
            if idx < SIMULATED_FLASH_SIZE then
                parts[#parts + 1] = string.char(flash[idx])
            else
                parts[#parts + 1] = string.char(0xFF)
            end
        end
        result = table.concat(parts)
        log:info('[SPI READ]  DATA[%d]: %s', #result, bytes_to_hex(result))

    else
        -- 未知命令，返回全 0xFF
        local parts = {}
        for i = 1, r_len do
            parts[#parts + 1] = string.char(0xFF)
        end
        result = table.concat(parts)
        log:info('[SPI READ]  unknown cmd 0x%02x, returning 0xFF x %s', cmd, r_len)
    end

    return result
end

-- ── spi_write: SPI 写入桩 ───────────────────────────────────────────
function hisport2:spi_write(info, data)
    if not info then
        log:info('[SPI STUB] spi_write: info is nil')
        return
    end
    local channel = info.channel or 0
    local cs = info.cs or 0
    local key = (channel << 8) + cs
    local flash = get_flash_storage(key)

    log:info('[SPI WRITE] ch=%s cs=%s w_len=%s', channel, cs, #data)

    if not data or #data == 0 then
        return
    end

    local cmd = string.byte(data, 1)
    log:info('[SPI WRITE] cmd=%s', get_cmd_name(cmd))
    log:info('[SPI WRITE] DATA: %s', bytes_to_hex(data))

    if cmd == SPI_CMD_WRITE_ENABLE then
        write_enable_latch = true
        log:info('[SPI WRITE] WEL set to 1')

    elseif cmd == SPI_CMD_ENABLE_4BYTE then
        four_byte_mode = true
        log:info('[SPI WRITE] 4-byte address mode ENABLED')

    elseif cmd == SPI_CMD_DISABLE_4BYTE then
        four_byte_mode = false
        log:info('[SPI WRITE] 4-byte address mode DISABLED')

    elseif cmd == SPI_CMD_PAGE_PROGRAM or cmd == SPI_CMD_PAGE_PROGRAM_4BYTE then
        local addr = 0
        local payload_offset = 0

        if cmd == SPI_CMD_PAGE_PROGRAM and #data >= 4 then
            addr = (string.byte(data, 2) << 16)
                 + (string.byte(data, 3) << 8)
                 + string.byte(data, 4)
            payload_offset = 4
        elseif cmd == SPI_CMD_PAGE_PROGRAM_4BYTE and #data >= 5 then
            addr = (string.byte(data, 2) << 24)
                 + (string.byte(data, 3) << 16)
                 + (string.byte(data, 4) << 8)
                 + string.byte(data, 5)
            payload_offset = 5
        end

        local payload_len = #data - payload_offset
        log:info('[SPI WRITE] PAGE_PROGRAM addr=0x%06x, len=%s', addr, payload_len)

        if write_enable_latch and addr + payload_len <= SIMULATED_FLASH_SIZE then
            for i = 0, payload_len - 1 do
                flash[addr + i] = string.byte(data, payload_offset + 1 + i)
            end
            log:info('[SPI WRITE] programmed %d bytes to flash[0x%06x]', payload_len, addr)
        elseif not write_enable_latch then
            log:info('[SPI WRITE] WARNING: WEL not set, write ignored')
        end

        write_enable_latch = false

    elseif cmd == SPI_CMD_SECTOR_ERASE or cmd == SPI_CMD_SECTOR_ERASE_4BYTE
        or cmd == SPI_CMD_BLOCK_32K_ERASE or cmd == SPI_CMD_BLOCK_64K_ERASE then
        -- 擦除命令: 需要 WEL，解析地址，按大小擦除
        local addr = 0
        if cmd == SPI_CMD_SECTOR_ERASE and #data >= 4 then
            addr = (string.byte(data, 2) << 16)
                 + (string.byte(data, 3) << 8)
                 + string.byte(data, 4)
            if write_enable_latch then
                erase_flash(flash, addr, SECTOR_ERSE_SIZE)
                log:info('[SPI WRITE] SECTOR_ERASE at 0x%06x (4KB)', addr)
            end
        elseif cmd == SPI_CMD_SECTOR_ERASE_4BYTE and #data >= 5 then
            addr = (string.byte(data, 2) << 24)
                 + (string.byte(data, 3) << 16)
                 + (string.byte(data, 4) << 8)
                 + string.byte(data, 5)
            if write_enable_latch then
                erase_flash(flash, addr, SECTOR_ERSE_SIZE)
                log:info('[SPI WRITE] SECTOR_ERASE_4BYTE at 0x%06x (4KB)', addr)
            end
        elseif cmd == SPI_CMD_BLOCK_32K_ERASE and #data >= 4 then
            addr = (string.byte(data, 2) << 16)
                 + (string.byte(data, 3) << 8)
                 + string.byte(data, 4)
            if write_enable_latch then
                erase_flash(flash, addr, BLOCK_32K_ERSE_SIZE)
                log:info('[SPI WRITE] BLOCK_32K_ERASE at 0x%06x (32KB)', addr)
            end
        elseif cmd == SPI_CMD_BLOCK_64K_ERASE and #data >= 4 then
            addr = (string.byte(data, 2) << 16)
                 + (string.byte(data, 3) << 8)
                 + string.byte(data, 4)
            if write_enable_latch then
                erase_flash(flash, addr, BLOCK_64K_ERSE_SIZE)
                log:info('[SPI WRITE] BLOCK_64K_ERASE at 0x%06x (64KB)', addr)
            end
        end
        if not write_enable_latch then
            log:info('[SPI WRITE] WARNING: WEL not set, erase ignored')
        end
        write_enable_latch = false

    elseif cmd == SPI_CMD_CHIP_ERASE then
        -- 整片擦除
        if write_enable_latch then
            for i = 0, SIMULATED_FLASH_SIZE - 1 do
                flash[i] = 0xFF
            end
            log:info('[SPI WRITE] CHIP_ERASE: all flash set to 0xFF')
        else
            log:info('[SPI WRITE] WARNING: WEL not set, chip erase ignored')
        end
        write_enable_latch = false

    elseif cmd == SPI_CMD_READ_STATUS or cmd == SPI_CMD_READ_DATA or cmd == SPI_CMD_READ_DATA_4BYTE then
        -- 读命令在 write 阶段只发送命令头，实际读取在 spi_read 中处理
        log:info('[SPI WRITE] read cmd header sent, actual read in spi_read')

    else
        log:info('[SPI WRITE] unknown cmd 0x%02x, ignored', cmd)
    end
end

-- ── I2C 读写桩 ────────────────────────────────────────────────────────
function hisport2:his_i2c_read(read_info)
    if not read_info then
        log:info('[I2C STUB] his_i2c_read: read_info is nil')
        return ''
    end
    local channel = read_info.channel or 0
    local addr = read_info.addr or 0
    local offset = read_info.offset or 0
    local r_len = read_info.r_len or 0
    local key = (channel << 8) + addr
    local storage = get_i2c_storage(key)

    log:info('[I2C READ]  ch=%s addr=0x%02x offset=0x%04x offset_width=%s r_len=%s',
        channel, addr, offset, read_info.offset_width or 0, r_len)

    -- 从模拟 I2C 存储读取
    local result = ""
    if offset + r_len <= SIMULATED_I2C_SIZE then
        local parts = {}
        for i = 0, r_len - 1 do
            parts[#parts + 1] = string.char(storage[offset + i])
        end
        result = table.concat(parts)
    else
        -- 超出范围，返回 0xFF
        local parts = {}
        for i = 1, r_len do
            parts[#parts + 1] = string.char(0xFF)
        end
        result = table.concat(parts)
    end

    log:info('[I2C READ]  DATA[%d]: %s', #result, bytes_to_hex(result))
    return result
end

function hisport2:his_i2c_write(write_info, data)
    if not write_info then
        log:info('[I2C STUB] his_i2c_write: write_info is nil')
        return
    end
    local channel = write_info.channel or 0
    local addr = write_info.addr or 0
    local offset = write_info.offset or 0
    local key = (channel << 8) + addr
    local storage = get_i2c_storage(key)

    log:info('[I2C WRITE] ch=%s addr=0x%02x offset=0x%04x offset_width=%s w_len=%s',
        channel, addr, offset, write_info.offset_width or 0, data and #data or 0)

    if not data or #data == 0 then
        return
    end

    log:info('[I2C WRITE] DATA: %s', bytes_to_hex(data))

    -- 写入模拟 I2C 存储
    if offset + #data <= SIMULATED_I2C_SIZE then
        for i = 1, #data do
            storage[offset + i - 1] = string.byte(data, i)
        end
        log:info('[I2C WRITE] wrote %d bytes to i2c[0x%04x]', #data, offset)
    else
        log:info('[I2C WRITE] WARNING: write out of bounds, offset=0x%04x, len=%d, max=0x%x',
            offset, #data, SIMULATED_I2C_SIZE)
    end
end

-- ── 方法别名，兼容不同调用方式 ─────────────────────────────────────
-- Lua 层调用: self.drv:spi_read / self.drv:spi_write
-- C++ 绑定调用: self.drv:his_spi_read / self.drv:his_spi_write
hisport2.his_spi_read = hisport2.spi_read
hisport2.his_spi_write = hisport2.spi_write
-- I2C 方法别名
hisport2.i2c_read = hisport2.his_i2c_read
hisport2.i2c_write = hisport2.his_i2c_write

function hisport2:read(input)
    return ''
end

function hisport2:write(input)
end

function hisport2:get_value_with_mask(t_type, value, length, mask)
    if t_type == 0 then
        return utils.bus_mask(value, #value, mask)
    end
    return value
end

return hisport2
