local class = require 'mc.class'
local stream = require 'stream.base'
local jtag_base = require 'stream.jtag_base'

---@class jtag_over_hisport:stream
local jtag_over_hisport = class(jtag_base)

function jtag_over_hisport:ctor(property, bus_name)
    self.channel_id = property.channelId
    self.component_id = jtag_base.def.CPLD_UPG_BY_JTAG_OVER_HISPORT + self.id * jtag_base.def.MAX_HISPORT_NUM + self.channel_id
end

function jtag_over_hisport:init()
    if self.reset_gpio then
        self.drv:reset_init(self.reset_gpio)
    end

    self.hisport_drv = stream.open_drive('libsoc_adapter.hisport2', self.id)
    local init_info = self.hisport_drv.HISPORT_INFO_S.new()
    init_info.nego_max_speed = 3 -- 0:25k 1:25M 2:50M 3:100M other:非法
    init_info.en_mode = 0x35
    self.hisport_drv:init(init_info, self.bus_name)
    self.hisport_drv:close()
    self.drv:init(self.component_id)
end

function jtag_over_hisport:get_cpld_id()
    self:init()
    return jtag_base.get_cpld_id(self)
end

function jtag_over_hisport:wirte(input)
    jtag_base.write(self,input)
end

function jtag_over_hisport:check_bypass_channel(chip_id, jtag_channel)
    return jtag_base.check_bypass_channel(self, chip_id, jtag_channel)
end

return jtag_over_hisport

