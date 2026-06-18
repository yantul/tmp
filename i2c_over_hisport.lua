--[[
    I2C over Hisport 打桩实现 (Lua)
    参考 drivers/internal/bus/bus_i2c_over_hisport/i2c_over_hisport.cpp
    继承 hisport2 桩, 使用 his_i2c_read/his_i2c_write 进行内存读写
    用于 I2C over Hisport 的功能测试
]]

local class = require 'mc.class'
local hisport2 = require 'stream.hisport2'
local log = require 'mc.logging'

---@class i2c_over_hisport:stream
local i2c_over_hisport = class(hisport2)

-- MCTP 协议标志
local I2C_OVER_HISPORT_MCTP_FLAG = 0x02

function i2c_over_hisport:init()
    self.info = self.drv.HISPORT_I2C_INFO.new()
end

-- 普通 I2C 读取
function i2c_over_hisport:read(input)
    self.info.channel = self.channel_id
    self.info.addr = input.addr or 0
    self.info.offset_width = input.addr_width or 0
    self.info.offset = input.offset or 0
    self.info.retry_cnt = 1
    self.info.r_len = input.len or input.length or 1
    self.info.timeout = 100

    local data = self.drv:his_i2c_read(self.info)
    log:conditional_log(data, log.level.error, 'I2C read failed', 'I2C read success')
    return data
end

-- 普通 I2C 写入
function i2c_over_hisport:write(input)
    self.info.channel = self.channel_id
    self.info.addr = input.addr or 0
    self.info.offset_width = input.addr_width or 0
    self.info.offset = input.offset or 0
    self.info.retry_cnt = 1
    self.info.timeout = 100

    self.drv:his_i2c_write(self.info, input.buffer)
    log:conditional_log(true, log.level.error, 'I2C write failed', 'I2C write success')
    return true
end

return i2c_over_hisport
