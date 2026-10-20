-- OpenFreq DCS exporter v0.7.0 - F-14A/B native PTT and radio telemetry
-- SPDX-License-Identifier: MIT
-- Runs in DCS Export.lua context. Sends JSON UDP to 127.0.0.1:29340.
-- No audio, no SRS dependency, no in-cockpit commands.

local M = { version = '0.7.0' }
local CONFIG = { host = '127.0.0.1', port = 29340, interval_s = 0.1 }
-- PTT comes from the Heatblur native radio and ICS devices (SRS method reference).
-- No PTT argument scanning or separate keyboard/HOTAS bindings are used.
-- Pilot ICS hot mic is cockpit argument 2044 (-1 = cold mic). RIO not yet supported.
local NULL = {} -- serializes as JSON null instead of omitting unavailable fields
local sock = nil
local next_send = nil
local previous_model_time = nil
local sequence = 0
local last_error = nil
local export_logger = _G.log

local function log_info(message)
  if export_logger and type(export_logger.write) == 'function' then
    pcall(export_logger.write, 'OpenFreqDCS', export_logger.INFO or 2, tostring(message))
  end
end

local function finite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end
local function val_or_null(n)
  if n == nil then return NULL end
  return n
end
local function number_or_null(n)
  if finite(n) then return n end
  return NULL
end
local function json_escape(s)
  return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
    local special = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
    return special[c] or string.format('\\u%04x', string.byte(c))
  end) .. '"'
end
local function array_shape(t)
  local count, max = 0, 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    count = count + 1
    if k > max then max = k end
  end
  return count > 0 and count == max
end
local function encode(v, depth)
  depth = depth or 0
  if depth > 12 or v == NULL then return 'null' end
  if type(v) == 'nil' then return 'null' end
  if type(v) == 'boolean' then return tostring(v) end
  if type(v) == 'number' then return finite(v) and tostring(v) or 'null' end
  if type(v) == 'string' then return json_escape(v) end
  if type(v) ~= 'table' then return 'null' end
  local out = {}
  if array_shape(v) then
    for i = 1, #v do out[#out+1] = encode(v[i], depth+1) end
    return '[' .. table.concat(out, ',') .. ']'
  end
  for k, value in pairs(v) do
    if type(k) == 'string' then
      out[#out+1] = json_escape(k) .. ':' .. encode(value, depth+1)
    end
  end
  return '{' .. table.concat(out, ',') .. '}'
end
local function safe_global(name, ...)
  local fn = _G[name]
  if type(fn) ~= 'function' then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end
local function safe_method(device, method)
  if device == nil then return nil end
  local ok, result = pcall(function()
    if type(device[method]) == 'function' then
      return device[method](device)
    end
    return nil
  end)
  if ok then return result end
  return nil
end

-- Device and pilot-cockpit volume mappings documented by DCS-BIOS F-14B.
-- UHF1 ARC-159 = device 3, pilot volume arg 2031.
-- UHF2 ARC-182 = device 4, pilot volume arg 2038.
local F14_RADIOS = {
  { id = 1, device_id = 3, name = 'UHF1 ARC-159', volume_argument = 2031 },
  { id = 2, device_id = 4, name = 'UHF2 ARC-182', volume_argument = 2038 },
}

local function cockpit_argument(panel, argument_id)
  if panel == nil then return nil end
  local ok, value = pcall(function()
    if type(panel.get_argument_value) ~= 'function' then return nil end
    return panel:get_argument_value(argument_id)
  end)
  if ok and finite(value) then return value end
  return nil
end

local function f14_volume(panel, argument_id)
  local value = cockpit_argument(panel, argument_id)
  if value == nil or value < 0 or value > 1 then return NULL end
  return value
end

-- Heatblur F-14 native PTT, as accessed by SRS's F14.lua aircraft adapter.
-- Radio priority ARC-182 > ARC-159 > ICS; ICS hot mic alone must not be
-- reported as an explicit PTT press. Nil means unavailable, not 'released'.
-- We deliberately do NOT rely on cockpit argument scanning.
local function native_boolean(device, method)
  local value = safe_method(device, method)
  if type(value) == 'boolean' then return value end
  return nil
end

local function native_f14_ptt(panel, ics_device, uhf1_device, uhf2_device)
  local arc159 = native_boolean(uhf1_device, 'is_ptt_pressed')
  local arc182 = native_boolean(uhf2_device, 'is_ptt_pressed')
  local intercom = native_boolean(ics_device, 'intercom_transmit')
  local hot_mic_arg = cockpit_argument(panel, 2044)
  local hot_mic = nil
  if hot_mic_arg ~= nil then hot_mic = hot_mic_arg > -1 end

  local tx, pressed = nil, nil
  if arc182 == true then
    tx, pressed = 2, true
  elseif arc159 == true then
    tx, pressed = 1, true
  elseif intercom == true and hot_mic == false then
    tx, pressed = 0, true
  elseif arc182 == false and arc159 == false and
         (intercom == false or (intercom == true and hot_mic == true)) then
    -- An inactive ICS with active hot mic is not a PTT press.
    pressed = false
  end

  local source = 'heatblur_native_devices'
  if arc159 == nil and arc182 == nil and intercom == nil then
    source = 'native_ptt_unavailable'
  elseif pressed == nil then
    source = 'native_ptt_incomplete'
  end
  return tx, pressed, source, {
    uhf1 = val_or_null(arc159),
    uhf2 = val_or_null(arc182),
    ics = val_or_null(intercom),
    ics_hot_mic = val_or_null(hot_mic),
    ics_hot_mic_argument = number_or_null(hot_mic_arg),
  }
end

local function f14_radio(config, panel, device)
  local power = safe_method(device, 'is_on')
  local frequency = safe_method(device, 'get_frequency')
  local raw_modulation = safe_method(device, 'get_modulation')
  local modulation = nil
  if raw_modulation == 0 then modulation = 'AM'
  elseif raw_modulation == 1 then modulation = 'FM' end
  -- Allow ARC-182 VHF frequencies as well as UHF.
  if not finite(frequency) or frequency < 20000000 or frequency > 500000000 then
    frequency = nil
  end
  if frequency ~= nil then frequency = math.floor(frequency + 0.5) end
  if type(power) ~= 'boolean' then power = nil end
  return {
    id = config.id, name = config.name, device_id = config.device_id,
    frequency_hz = val_or_null(frequency), modulation = val_or_null(modulation),
    power_on = val_or_null(power), volume = (function()
      local v = safe_method(device, 'get_volume')
      if finite(v) and v >= 0 and v <= 1 then return v end
      return f14_volume(panel, config.volume_argument)
    end)(),
    tx_selected = NULL, ptt_pressed = NULL,
    state_valid = frequency ~= nil and device ~= nil,
  }
end

local function geographic_position(position)
  if type(position) ~= 'table' or not finite(position.x) or not finite(position.z) then
    return NULL
  end
  local geo = safe_global('LoLoCoordinatesToGeoCoordinates', position.x, position.z)
  if type(geo) ~= 'table' or not finite(geo.latitude) or not finite(geo.longitude) then
    return NULL
  end
  if geo.latitude < -90 or geo.latitude > 90 or geo.longitude < -180 or geo.longitude > 180 then
    return NULL
  end
  return { latitude_deg = geo.latitude, longitude_deg = geo.longitude,
    altitude_msl_m = number_or_null(position.y) }
end

local function is_f14(name)
  return type(name) == 'string' and (
    name == 'F-14B' or name == 'F-14A-135-GR' or
    name == 'F-14A-95-GR' or name == 'F-14B(U)' or
    string.match(name, '^F%-14') ~= nil)
end

local function snapshot(model_time)
  local data = safe_global('LoGetSelfData')
  if type(data) ~= 'table' then data = nil end
  local aircraft_name = data and data.Name or nil
  local tomcat = is_f14(aircraft_name)
  local position = data and data.Position or nil
  local radios = NULL
  local availability = 'no_aircraft'
  if data then availability = 'unsupported_aircraft' end
  local cockpit = NULL
  local selected_tx_radio, ptt_pressed, ptt_source = nil, nil, 'unavailable'
  if tomcat then
    local panel = safe_global('GetDevice', 0)
    local ics_device = safe_global('GetDevice', 2)
    local uhf1_device = safe_global('GetDevice', 3)
    local uhf2_device = safe_global('GetDevice', 4)
    local native_ptt
    selected_tx_radio, ptt_pressed, ptt_source, native_ptt =
      native_f14_ptt(panel, ics_device, uhf1_device, uhf2_device)

    radios = {
      f14_radio(F14_RADIOS[1], panel, uhf1_device),
      f14_radio(F14_RADIOS[2], panel, uhf2_device)
    }
    if ptt_pressed ~= nil then
      for _, radio in ipairs(radios) do
        radio.tx_selected = (ptt_pressed and selected_tx_radio == radio.id) or false
        radio.ptt_pressed = (ptt_pressed and selected_tx_radio == radio.id) or false
      end
    end

    local ics_volume = safe_method(ics_device, 'get_volume')
    if not finite(ics_volume) or ics_volume < 0 or ics_volume > 1 then
      ics_volume = f14_volume(panel, 2048)
    end
    cockpit = {
      station = 'pilot_assumed', -- Export.lua does not verify local seat.
      ptt_source = ptt_source,
      native_ptt = native_ptt,
      pilot_ics_volume = ics_volume,
      -- Not a transmit command: exposed only for future multicrew use.
      ics_hot_mic = native_ptt.ics_hot_mic,
    }
    availability = (radios[1].state_valid or radios[2].state_valid)
      and 'partial' or 'unavailable'
  end
  sequence = sequence + 1
  return {
    schema = 'openfreq.dcs.telemetry.v1',
    exporter_version = M.version,
    sequence = sequence, model_time = model_time,
    aircraft = {
      name = val_or_null(aircraft_name),
      unit_name = val_or_null(data and data.UnitName or nil),
      coalition = val_or_null(data and data.Coalition or nil),
      heading_rad = number_or_null(data and data.Heading or nil),
      position = type(position) == 'table' and {
        x = number_or_null(position.x), y = number_or_null(position.y),
        z = number_or_null(position.z),
      } or NULL,
      geo = geographic_position(position),
    },
    altitude_msl_m = number_or_null(safe_global('LoGetAltitudeAboveSeaLevel')),
    indicated_airspeed_mps = number_or_null(safe_global('LoGetIndicatedAirSpeed')),
    true_airspeed_mps = number_or_null(safe_global('LoGetTrueAirSpeed')),
    radios = radios, cockpit = cockpit,
    radio_export_status = availability,
    selected_tx_radio = val_or_null(selected_tx_radio),
    ptt_pressed = val_or_null(ptt_pressed),
  }
end

local function start()
  local ok, socket_library = pcall(require, 'socket')
  if not ok then log_info('LuaSocket unavailable: ' .. tostring(socket_library)); return end
  local made, created = pcall(socket_library.udp)
  if not made or not created then log_info('Unable to create UDP socket'); return end
  sock = created
  pcall(function() sock:settimeout(0) end)
  next_send = nil
  previous_model_time = nil
  sequence = 0
  last_error = nil
  log_info('F-14 telemetry exporter initialized -> ' .. CONFIG.host .. ':' .. CONFIG.port)
end
local function stop()
  if sock then pcall(function() sock:close() end) end
  sock = nil
  next_send = nil
  previous_model_time = nil
end
local function after_next_frame()
  if not sock then return end
  local t = safe_global('LoGetModelTime')
  if not finite(t) then return end
  if next_send == nil or (previous_model_time and t < previous_model_time - 0.01) then next_send = t end
  previous_model_time = t
  if t + 0.000001 < next_send then return end
  next_send = t + CONFIG.interval_s
  local ok, packet = pcall(function() return encode(snapshot(t)) end)
  if not ok then
    if last_error ~= tostring(packet) then log_info('Snapshot error: ' .. tostring(packet)) end
    last_error = tostring(packet)
    return
  end
  local sent, err = sock:sendto(packet, CONFIG.host, CONFIG.port)
  if not sent then
    if last_error ~= tostring(err) then log_info('UDP error: ' .. tostring(err)) end
    last_error = tostring(err)
  else
    last_error = nil
  end
end

-- Callback chaining: this file should be loaded LAST in Export.lua.
local prior_start = LuaExportStart
local prior_stop = LuaExportStop
local prior_after = LuaExportAfterNextFrame
LuaExportStart = function(...)
  if prior_start then
    local ok, err = pcall(prior_start, ...)
    if not ok then log_info('Prior exporter start error: ' .. tostring(err)) end
  end
  local ok, err = pcall(start)
  if not ok then log_info('Exporter start error: ' .. tostring(err)) end
end
LuaExportAfterNextFrame = function(...)
  if prior_after then
    local ok, err = pcall(prior_after, ...)
    if not ok and last_error ~= tostring(err) then log_info('Prior frame exporter error: ' .. tostring(err)) end
  end
  local ok, err = pcall(after_next_frame)
  if not ok and last_error ~= tostring(err) then
    log_info('Exporter frame error: ' .. tostring(err))
    last_error = tostring(err)
  end
end
LuaExportStop = function(...)
  pcall(stop)
  if prior_stop then
    local ok, err = pcall(prior_stop, ...)
    if not ok then log_info('Prior exporter stop error: ' .. tostring(err)) end
  end
end

M._test_snapshot = snapshot -- unit-test entry point; not used by DCS integration
M._test_encode = encode -- unit-test entry point; not used by DCS integration
return M
