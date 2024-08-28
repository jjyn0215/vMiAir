--[[
  Copyright 2023 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  PC Control Device - supports WOL and Windows Remote Shutdown Manager (https://github.com/karpach/remote-shutdown-pc)

--]]
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"        -- for time only
local socket = require "cosock.socket" -- for time only
local log = require "log"
local comms = require "comms"
local swtemp, modetemp = '', ''

local function create_device(driver)
    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'MiAirVdevice'
    local VEND_LABEL = 'Mi Air Vdevice'
    local ID = 'MiAir_' .. socket.gettime()
    local PROFILE = 'miair.v1'

    log.info(string.format('Creating new device: label=<%s>, id=<%s>', VEND_LABEL, ID))

    local create_device_msg = {
        type = "LAN",
        device_network_id = ID,
        label = VEND_LABEL,
        profile = PROFILE,
        manufacturer = MFG_NAME,
        model = MODEL,
        vendor_provided_label = VEND_LABEL,
    }

    assert(driver:try_create_device(create_device_msg), "failed to create device")
end

local function mysplit(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

local function sync_status(device)
    local ok, response = comms.issue_request('POST', device.preferences.pcaddr, "/status", nil)
    local result = mysplit(response, " ")
    if result[6] == "offline" then
        device:offline()
    else
        device:online()
        device:emit_event(capabilities.fineDustSensor.fineDustLevel(tonumber(result[1])))
        device:emit_event(capabilities.relativeHumidityMeasurement.humidity(tonumber(result[2])))
        device:emit_event(capabilities.temperatureMeasurement.temperature({ value = tonumber(result[3]), unit = 'C' }))
        device:emit_event(capabilities.illuminanceMeasurement.illuminance(tonumber(result[4])))
        device:emit_event(capabilities.filterState.filterLifeRemaining(tonumber(result[5])))

        if swtemp ~= result[6] then
            if result[6] == 'on' then
                device:emit_event(capabilities.switch.switch('on'))
            elseif result[6] == 'off' then
                device:emit_event(capabilities.switch.switch('off'))
            end
        end
        if modetemp ~= result[7] then
            if result[7] == 'auto' then
                device:emit_event(capabilities.fanSpeed.fanSpeed(0))
            elseif result[7] == 'silent' then
                device:emit_event(capabilities.fanSpeed.fanSpeed(1))
            end
        end
        if result[7] == 'favorite' then
            if result[8] == "8" then
                device:emit_event(capabilities.fanSpeed.fanSpeed(2))
            elseif result[8] == "12" then
                device:emit_event(capabilities.fanSpeed.fanSpeed(3))
            elseif result[8] == "16" then
                device:emit_event(capabilities.fanSpeed.fanSpeed(4))
            end
        end
        swtemp, modetemp = result[6], result[7]
    end
end

local function setup_monitor(driver, device)
    local montimer = driver:call_on_schedule(device.preferences.rfrate, function()
        sync_status(device)
    end)
    device:set_field('montimer', montimer)
end

local function sync_to_device(driver, device, value)
    local ok, response = comms.issue_request('POST', device.preferences.pcaddr, "/status", value)
end

local function handle_switch(driver, device, command)
    device:emit_event(capabilities.switch.switch(command.command))
    sync_to_device(driver, device, device.state_cache.main.switch.switch.value);
end

local function handle_fanspeed(driver, device, command)
    device:emit_event(capabilities.fanSpeed.fanSpeed(command.args.speed))
    sync_to_device(driver, device, tostring(command.args.speed))
end

local function handle_refresh(driver, device, command)
    log.info('Manual refresh requested')
    sync_status(device)
end

local function device_init(driver, device)
    setup_monitor(driver, device)
    initialized = true
    device_init_counter = device_init_counter + 1
end

local function device_added(driver, device)
    device:emit_event(capabilities.switch.switch('off'))
    device:emit_event(capabilities.fanSpeed.fanSpeed(0))
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = 20, unit = 'C' }))
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(50))
    device:emit_event(capabilities.fineDustSensor.fineDustLevel(10))
    device:emit_event(capabilities.illuminanceMeasurement.illuminance(10))
    device:emit_event(capabilities.filterState.filterLifeRemaining(10))
end

local function device_doconfigure(_, device)
    log.info('Device doConfigure lifecycle invoked')
end

local function device_removed(driver, device)
    if device:get_field('montimer') then
        driver:cancel_timer(device:get_field('montimer'))
    end
    initialized = false
end

local function handler_driverchanged(driver, device, event, args)
    log.debug('*** Driver changed handler invoked ***')
end

local function shutdown_handler(driver, event)
    log.warn('shutdooooooooooooown')
end

local function handler_infochanged(driver, device, event, args)
    log.debug('Info changed handler invoked')
    if args.old_st_store.preferences then
        if args.old_st_store.preferences.pcaddr ~= device.preferences.pcaddr then
            log.info('PC Address changed to', device.preferences.pcaddr)
            sync_status(device)
        elseif args.old_st_store.preferences.rfrate ~= device.preferences.rfrate then
            if device:get_field('montimer') then
                driver:cancel_timer(device:get_field('montimer'))
            end
            setup_monitor(driver, device)
        end
    end
end
                               
local function discovery_handler(driver, _, should_continue)
    if not initialized then
        create_device(driver)
    end
end

local thisDriver = Driver("thisDriver", {
    discovery = discovery_handler,
    lifecycle_handlers = {
        init = device_init,
        added = device_added,
        driverSwitched = handler_driverchanged,
        infoChanged = handler_infochanged,
        doConfigure = device_doconfigure,
        removed = device_removed
    },
    driver_lifecycle = shutdown_handler,
    capability_handlers = {
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = handle_switch,
            [capabilities.switch.commands.off.NAME] = handle_switch,
        },
        [capabilities.fanSpeed.ID] = {
            [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handle_fanspeed,
        },
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
        },
    }
})


thisDriver:run()
