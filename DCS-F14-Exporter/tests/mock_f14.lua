-- Mocked Heatblur devices for OpenFreq v0.7 native PTT tests.
local name = 'F-14B'
local values = { [2031]=0.75, [2038]=0.45, [2048]=0.6, [2044]=-1 }
local panel = {get_argument_value=function(self,arg) return values[arg] or 0 end}
local uhf1_ptt, uhf2_ptt, ics_tx = false, false, false
local function radio(freq, power, mod, volume)
  return {
    get_frequency=function() return freq end,
    is_on=function() return power end,
    get_modulation=function() return mod end,
    get_volume=function() return volume end,
  }
end
local d2 = { intercom_transmit=function() return ics_tx end,
             get_volume=function() return 0.33 end }
local d3 = radio(251000000, true, 0, 0.62)
local d4 = radio(124800000, true, 1, nil)
d3.is_ptt_pressed=function() return uhf1_ptt end
d4.is_ptt_pressed=function() return uhf2_ptt end
local devices = { [0]=panel, [2]=d2, [3]=d3, [4]=d4 }
GetDevice = function(id) return devices[id] end
LoGetSelfData = function() return {Name=name, UnitName='Tomcat', Position={x=10,y=1500,z=20},Heading=0.25} end
LoGetModelTime = function() return 1.5 end
LoGetAltitudeAboveSeaLevel = function() return 1500 end
LoGetIndicatedAirSpeed = function() return 130 end
LoGetTrueAirSpeed = function() return 150 end
LoLoCoordinatesToGeoCoordinates = function() return {latitude=25,longitude=55} end
local module = dofile('OpenFreqDCSExport.lua')
assert(module.version == '0.7.0')
local function state(tx, pressed, source)
  local t=module._test_snapshot(1)
  if tx == nil then
    assert(type(t.selected_tx_radio) == 'table', 'TX should be JSON null')
  else
    assert(t.selected_tx_radio==tx, 'incorrect TX')
  end
  if pressed == nil then
    assert(type(t.ptt_pressed)=='table', 'PTT should be JSON null')
  else
    assert(t.ptt_pressed==pressed, 'incorrect PTT')
  end
  assert(t.cockpit.ptt_source==source, 'incorrect PTT source')
  return t
end
local normal='heatblur_native_devices'
local t = state(nil, false, normal)
assert(t.aircraft.name=='F-14B')
assert(t.radio_export_status=='partial')
assert(t.radios[1].frequency_hz==251000000 and t.radios[2].frequency_hz==124800000)
assert(t.radios[1].volume==0.62 and t.radios[2].volume==0.45)
assert(t.radios[1].modulation=='AM' and t.radios[2].modulation=='FM')
assert(t.cockpit.pilot_ics_volume==0.33)
assert(t.cockpit.native_ptt.ics_hot_mic==false)
assert(t.cockpit.native_ptt.uhf1==false and t.cockpit.native_ptt.uhf2==false)
assert(t.radios[1].tx_selected==false and t.radios[2].tx_selected==false)
uhf1_ptt=true
local r1=state(1, true, normal)
assert(r1.radios[1].ptt_pressed==true and r1.radios[2].ptt_pressed==false)
uhf1_ptt=false
uhf2_ptt=true
local r2=state(2, true, normal)
assert(r2.radios[2].tx_selected==true and r2.radios[1].tx_selected==false)
uhf1_ptt=true -- simultaneous: 182 takes priority, as in SRS
state(2, true, normal)
uhf1_ptt=false
uhf2_ptt=false
ics_tx=true
local i=state(0, true, normal)
assert(i.radios[1].ptt_pressed==false and i.radios[2].ptt_pressed==false)
values[2044]=0  -- HOT MIC: do not translate ICS into held PTT
state(nil, false, normal)
assert(module._test_snapshot(1).cockpit.ics_hot_mic==true)
-- Even if hot mic is on, UHF PTT has priority and must still transmit.
uhf1_ptt=true
state(1,true,normal)
uhf1_ptt=false
ics_tx=false
state(nil,false,normal)
-- Missing HOT MIC selector while ICS is true: avoid guessing PTT.
values[2044]=nil
panel.get_argument_value=function(self,arg)
  if arg==2044 then error('missing ics switch') end
  return values[arg] or 0
end
ics_tx=true
state(nil,nil,'native_ptt_incomplete')
ics_tx=false
state(nil,false,normal)
-- No PTT methods at all must NOT be reported as released.
d3.is_ptt_pressed=nil
d4.is_ptt_pressed=nil
d2.intercom_transmit=nil
local unavailable=state(nil,nil,'native_ptt_unavailable')
local packet=module._test_encode(unavailable)
assert(packet:find('"ptt_pressed":null',1,true))
assert(packet:find('"selected_tx_radio":null',1,true))
-- Unsupported aircraft should not export stale F-14 PTT.
name='FA-18C_hornet'
local other=module._test_snapshot(1.5)
assert(other.radio_export_status=='unsupported_aircraft')
assert(type(other.ptt_pressed)=='table')
name='F-14A-135-GR'
local f14=module._test_snapshot(1.6)
assert(f14.aircraft.name=='F-14A-135-GR')
print('PASS: F-14 native UHF1/UHF2/ICS PTT, priority, hot-mic, errors, null, volume and switching')
