------------------------------------------------------------------------
-- Copyright (c) 2020-2021 Daniele Bochicchio
-- License: MIT License
-- Source Code: https://github.com/dbochicchio/Vera-HaBridge
------------------------------------------------------------------------

module("L_HABridge1", package.seeall)

local _PLUGIN_NAME = "HA-Bridge"
local _PLUGIN_VERSION = "0.11"

local debugMode = false

local MYSID									= "urn:bochicchio-com:serviceId:HABridge1"
local HASID									= "urn:micasaverde-com:serviceId:HaDevice1"
local SWITCHSID								= "urn:upnp-org:serviceId:SwitchPower1"
local DIMMERSID								= "urn:upnp-org:serviceId:Dimming1"
local COLORSID								= "urn:micasaverde-com:serviceId:Color1"
local ALTUISID								= "urn:upnp-org:serviceId:altui1"

local MAX_RETRIES = 3
local dateFormat = "yy-mm-dd"
local timeFormat = "24hr"
local masterID = -1
local watchesReady = false
local deviceMap = {}

local COMMANDS = {
    basePath = "/api/",
    endpoints = {
        list = "devices",
        updateStatus = "%s/lights/%s/bridgeupdatestate",
    }
}

local json = require "dkjson"

local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k, v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then
				val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			if #v > 255 then
				val = string.format("%q", v:sub(1, 252) .. "...")
			else
				val = string.format("%q", v)
			end
		elseif type(v) == "number" and (math.abs(v - os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function getVarNumeric(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	s = tonumber(s)
	return (s == nil) and dflt or s
end

local function getVar(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	return (s == nil) and dflt or s
end

local function L(devNum, msg, ...) -- luacheck: ignore 212
	local str = (_PLUGIN_NAME .. "[" .. _PLUGIN_VERSION .. "]@" .. tostring(devNum))
	local level = 50
	if type(msg) == "table" then
		str = str .. tostring(msg.prefix or _PLUGIN_NAME) .. ": " .. tostring(msg.msg)
		level = msg.level or level
	else
		str = str .. ": " .. tostring(msg)
	end
	str = string.gsub(str, "%%(%d+)", function(n)
		n = tonumber(n, 10)
		if n < 1 or n > #arg then return "nil" end
		local val = arg[n]
		if type(val) == "table" then
			return dump(val)
		elseif type(val) == "string" then
			return string.format("%q", val)
		elseif type(val) == "number" and math.abs(val - os.time()) <= 86400 then
			return tostring(val) .. "(" .. os.date("%x.%X", val) .. ")"
		end
		return tostring(val)
	end)
	luup.log(str, level)
end

local function D(devNum, msg, ...)
	debugMode = getVarNumeric(MYSID, "DebugMode", 0, devNum) == 1

	if debugMode then
		local t = debug.getinfo(2)
		local pfx = "(" .. tostring(t.name) .. "@" .. tostring(t.currentline) .. ")"
		L(devNum, {msg = msg, prefix = pfx}, ...)
	end
end

-- Set variable, only if value has changed.
local function setVar(sid, name, val, devNum)
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get(sid, name, devNum) or ""
	D(devNum, "setVar(%1,%2,%3,%4) old value %5", sid, name, val, devNum, s)
	if s ~= val then
		luup.variable_set(sid, name, val, devNum)
		return true, s
	end
	return false, s
end

local function split(str, sep)
	if sep == nil then sep = "," end
	local arr = {}
	if #(str or "") == 0 then return arr, 0 end
	local rest = string.gsub(str or "", "([^" .. sep .. "]*)" .. sep,
		function(m)
			table.insert(arr, m)
			return ""
		end)
	table.insert(arr, rest)
	return arr, #arr
end

local function trim(s)
	if s == nil then return "" end
	if type(s) ~= "string" then s = tostring(s) end
	local from = s:match "^%s*()"
	return from > #s and "" or s:match(".*%S", from)
end

-- Array to map, where f(elem) returns key[,value]
local function map(arr, f, res)
	res = res or {}
	for ix, x in ipairs(arr) do
		if f then
			local k, v = f(x, ix)
			res[k] = (v == nil) and x or v
		else
			res[x] = x
		end
	end
	return res
end

local function initVar(sid, name, dflt, devNum)
	local currVal = luup.variable_get(sid, name, devNum)
	if currVal == nil then
		luup.variable_set(sid, name, tostring(dflt), devNum)
		return tostring(dflt)
	end
	return currVal
end

local function formatDateTime(v)
	return string.format("%s %s",
		os.date(dateFormat:gsub("yy", "%%Y"):gsub("mm", "%%m"):gsub("dd", "%%d"), v),
		os.date(timeFormat == "12hr" and "%I:%M:%S%p" or "%H:%M:%S", v)
		)
end

function safeCall(devNum, call)
	local function err(x)
		local s = string.dump(call)
		L(devNum, "LUA error: %1 - %2", x, s)
	end

	local s, r, e = xpcall(call, err)
	return r
end

-- COLORS - Thanks amg0 - added from ALTHue
local function round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end

local function cieToRgb(x, y, brightness)
	local function enforceByte(r)
		return (r<0) and 0 or (r>255) and 255 or r
	end

	-- //Set to maximum brightness if no custom value was given (Not the slick ECMAScript 6 way for compatibility reasons)
	-- debug(string.format("cie_to_rgb(%s,%s,%s)",x, y, brightness or ""))
	x = tonumber(x)
	y = tonumber(y)
	brightness = tonumber(brightness)
	
	if (brightness == nil) then brightness = 254 end

	local z = 1.0 - x - y
	local Y = math.floor( 100 * (brightness / 254)) /100	-- .toFixed(2);
	local X = (Y / y) * x
	local Z = (Y / y) * z

	-- //Convert to RGB using Wide RGB D65 conversion
	local red 	=  X * 1.656492 - Y * 0.354851 - Z * 0.255038
	local green	= -X * 0.707196 + Y * 1.655397 + Z * 0.036152
	local blue 	=  X * 0.051713 - Y * 0.121364 + Z * 1.011530

	-- //If red, green or blue is larger than 1.0 set it back to the maximum of 1.0
	if (red > blue) and (red > green) and (red > 1.0) then
		green = green / red
		blue = blue / red
		red = 1.0
	elseif (green > blue) and (green > red) and (green > 1.0) then
		red = red / green
		blue = blue / green
		green = 1.0
	elseif (blue > red) and (blue > green) and (blue > 1.0) then
		red = red / blue
		green = green / blue
		blue = 1.0
	end

	-- //Reverse gamma correction
	red 	= (red <= 0.0031308) and (12.92 * red) or (1.0 + 0.055) * (red^(1.0 / 2.4)) - 0.055
	green 	= (green <= 0.0031308) and (12.92 * green) or (1.0 + 0.055) * (green^(1.0 / 2.4)) - 0.055
	blue 	= (blue <= 0.0031308) and (12.92 * blue) or (1.0 + 0.055) * (blue^(1.0 / 2.4)) - 0.055

	-- //Convert normalized decimal to decimal
	red 	= round(red * 255)
	green 	= round(green * 255)
	blue 	= round(blue * 255)
	return enforceByte(red), enforceByte(green), enforceByte(blue)
end

local function hsbToRgb(h, s, v) 
	h = tonumber(h or 0) / 65535
	s = tonumber(s or 0) / 254
	v = tonumber(v or 0) / 254
	local r, g, b, i, f, p, q, t
	i = math.floor(h * 6)
	f = h * 6 - i
	p = v * (1 - s)
	q = v * (1 - f * s)
	t = v * (1 - (1 - f) * s)
	if i==0 then
		r = v
		g = t
		b = p
	elseif i==1 then
		r = q
		g = v
		b = p
	elseif i==2 then
		r = p
		g = v
		b = t
	elseif i==3 then
		r = p
		g = q
		b = v
	elseif i==4 then
		r = t
		g = p
		b = v
	elseif i==5 then
		r = v
		g = p
		b = q
	end
	return round(r * 255), round(g * 255), round(b * 255)
end

local function rgbToCie(red, green, blue)
	-- Apply a gamma correction to the RGB values, which makes the color more vivid and more the like the color displayed on the screen of your device
	red = tonumber(red)
	green = tonumber(green)
	blue = tonumber(blue)
	red	= (red > 0.04045) and ((red + 0.055) / (1.0 + 0.055))^2.4 or (red / 12.92)
	green = (green > 0.04045) and ((green + 0.055) / (1.0 + 0.055))^2.4 or (green / 12.92)
	blue = (blue > 0.04045) and ((blue + 0.055) / (1.0 + 0.055))^2.4 or (blue / 12.92)

	-- //RGB values to XYZ using the Wide RGB D65 conversion formula
	local X = red * 0.664511 + green * 0.154324 + blue * 0.162028
	local Y = red * 0.283881 + green * 0.668433 + blue * 0.047685
	local Z	= red * 0.000088 + green * 0.072310 + blue * 0.986039

	-- //Calculate the xy values from the XYZ values
	local x1 = math.floor( 10000 * (X / (X + Y + Z)) )/10000  --.toFixed(4);
	local y1 = math.floor( 10000 * (Y / (X + Y + Z)) )/10000  --.toFixed(4);

	return x1, y1
end

function fromHueToVeraColor(state)
	local w,d,r,g,b=0,0,0,0,0
	if state.colormode == "xy" and state.xy ~= nil then
		r,g,b = cieToRgb(state.xy[1], state.xy[2], nil)
	elseif state.colormode == "hs" then
		r,g,b = hsbToRgb(state.hue, state.sat, state.bri)
	elseif state.colormode == "ct" and state.ct ~= nil then
		local kelvin = math.floor(((1000000/state.ct)/100)+0.5)*100
		w = (kelvin < 5450) and (math.floor((kelvin-2000)/13.52) + 1) or 0
		d = (kelvin > 5450) and (math.floor((kelvin-5500)/13.52) + 1) or 0
	else
		return nil
	end
	return string.format("0=%s,1=%s,2=%s,3=%s,4=%s", w, d, r, g, b)
end

-- HTTP
local function httpCall(devNum, url, method, additionalHeaders, payload, onSuccess, onFailure)
	local ltn12 = require("ltn12")
	local _, async = pcall(require, "http_async")
	local response_body = {}
	
	D(devNum, "httpCall(%1,%2,%3,%4)", type(async) == "table" and "async" or "sync", url, method, payload)

	if (additionalHeaders == nil) then
		additionalHeaders = {}
	end

	additionalHeaders["Content-Type"] = "application/json; charset=utf-8"
	additionalHeaders["Connection"] = "keep-alive"
	additionalHeaders["Content-Length"] = (payload or ""):len()

	-- async
	if type(async) == "table" then
		-- Async Handler for HTTP or HTTPS
		local _, err = async.request(
			{
				method = method or "GET",
				url = url,
				headers = additionalHeaders,
				source = ltn12.source.string(payload),
				sink = ltn12.sink.table(response_body)
			},
			function (response, status, headers, statusline)
				D(devNum, "httpCall.Async(%1, %2, %3, %4)", url, (response or ""), (status or "-1"), table.concat(response_body or ""))

				status = tonumber(status or 100)

				if onSuccess ~= nil and status >= 200 and status < 400 then
					-- call is ok
					D(devNum, "httpCall: onSuccess(%1)", status)
					onSuccess(table.concat(response_body or ""))
				else
					-- device is reachable, but call failed
					if onFailure ~= nil then onFailure(status, table.concat(response_body or "")) end
				end
			end)

		-- device is not reachable
		if err ~= nil and onFailure ~= nil then onFailure(status, table.concat(response_body or "")) end
	else
		-- Sync Handler for HTTP or HTTPS
		local requestor = url:lower():find("^https:") and require("ssl.https") or require("socket.http")
		local response, status, headers = requestor.request{
			method = method or "GET",
			url = url,
			headers = additionalHeaders,
			source = ltn12.source.string(payload),
			sink = ltn12.sink.table(response_body)
		}

		D(devNum, "httpCall(%1, %2, %3, %4)", url, (response or ""), (status or "-1"), table.concat(response_body or ""))

		status = tonumber(status or 100)

		if status >= 200 and status < 400 then
			if onSuccess ~= nil then
				D(devNum, "httpCall: onSuccess(%1)", status)
				onSuccess(table.concat(response_body or ""))
			end
		else
			if onFailure ~= nil then onFailure(status, table.concat(response_body or "")) end
		end
	end
end

function sendDeviceCommand(devNum, url, method, body, onSuccess, onFailure, retryCount)
	if retryCount == nil then retryCount = 0 end
	D(devNum, "sendDeviceCommand(%1,%2,%3,%4)", url, method, params, retryCount)

	--- headers
	local headers = {}

	local ip = luup.attr_get("ip", devNum)

	-- json body
	if type(body) == "table" then
		body = json.encode(body)
	end
	
	httpCall(devNum, string.format("http://%s%s%s", ip, COMMANDS.basePath, url), method, headers, body or "", 
		function(r) -- onSuccess
			D(devNum, "sendDeviceCommand.onSuccess(%1)", r)
			if onSuccess ~= nil then onSuccess(r) end
		end, 
		function(responseCode) -- onFailure
			-- try command again in case of errors
			if retryCount +1 < MAX_RETRIES then
				sendDeviceCommand(devNum, url, method, body, onSuccess, onFailure, retryCount + 1)
				return
			end
	
			if onFailure ~= nil then onFailure(r) end
		end)

	return false
end

function statusWatch(devNum, sid, var, oldVal, newVal)
	D(masterID, "statusWatch(%1,%2,%3,%4,%5) %6", devNum, sid, var, oldVal, newVal, oldVal ~= newVal)

	if oldVal == newVal then return end

	updateDeviceStatus(masterID, devNum, -1, -1, nil)
end

function updateBridge(masterID, devNum, internalId, currentStatus, currentBri, currentColor)
	L(masterID, "updateBridge(%1,%2,%3,%4,%5,%6)", masterID, devNum, internalId, currentStatus, currentBri, currentColor)
	local p = {
		on = currentStatus == "1" and "true" or "false", 
		reachable = true
	}

	if currentStatus == "1" then
		p.bri = string.format("%.0f", (currentBri or 0) == 0 and 1 or currentBri)
	end

	if currentColor ~= nil then
		local parts = split(currentColor, ',')
		local w, d = tonumber(split(parts[1], '=')[2]), tonumber(split(parts[2], '=')[2])
		
		if w == 0 and d == 0 then
			local x, y = rgbToCie(split(parts[3], '=')[2], split(parts[4], '=')[2], split(parts[5], '=')[2])
			local nan = tostring(0/0)
			if tostring(x) ~= nan and tostring(y) ~= nan then
				p.colormode = "xy"
				p.xy = { string.format("%4f", x), string.format("%4f", y)}
				p.sat = 254 -- TODO: get saturation?
				p.ct = 153
			end
		else
			-- color temperature
			local kelvin = math.floor((d*3500/255)) + ((w>0) and 5500 or 2000)
			local mired = math.floor(1000000/kelvin)
			local loadLevelStatus = getVarNumeric(DIMMERSID, "LoadLevelStatus", 100, devNum)
			local bri = math.floor(255*loadLevelStatus/100)

			p.colormode = "ct"
			p.bri = bri
			p.ct = mired
		end
	end

	local endpoint = string.format(COMMANDS.endpoints.updateStatus, "vera", tostring(internalId))
	sendDeviceCommand(masterID, endpoint, "PUT", p,
		function() -- success
			D(masterID, '#%1 - updateBridge: success', devNum)
		end,
		function(r)-- failed
			-- TODO: more logging?
			D(masterID, '#%1 - updateBridge: failed - %2', devNum, r)
		end)
end

function updateDeviceStatus(masterID, devNum, bridgeStatus, bridgeBri, bridgeColor)
	safeCall(masterID, function()
		D(masterID, "updateDeviceStatus(%1,%2,%3,%4,%5)", masterID, devNum, bridgeStatus, bridgeBri, bridgeColor)

		local internalId = deviceMap[devNum] -- get mapped id

		-- current status
		local currentStatus = getVar(SWITCHSID, "Status", "0", devNum)

		-- current brightness
		local currentBri = getVar(DIMMERSID, "LoadLevelStatus", "-1", devNum)

		if currentBri == "-1" then
			-- special case for non dimmable lights -- alexa wants 1 as minimum value
			currentBri = currentStatus == "0" and "0" or "100"
		end

		-- compute bri on a scale of 1/254
		currentBri = tonumber(currentBri) * 254 / 100

		-- colors, if supported
		local currentColor = getVar(COLORSID, "CurrentColor", nil, devNum)

		D(masterID, "#%1 - current status: %2 - bridge status: %3", devNum, currentStatus, bridgeStatus)
		D(masterID, "#%1 - current bri: %2 - bridge bri: %3", devNum, currentBri, bridgeBri)
		D(masterID, "#%1 - current color: %2 - bridge color: %3", devNum, currentColor, bridgeColor)

		-- status not in sync, update bridge
		if force or currentStatus ~= bridgeStatus or currentBri ~= bridgeBri or currentColor ~= bridgeColor then
			updateBridge(masterID, devNum, internalId, currentStatus, currentBri, currentColor)
		else
			D(masterID, "#%1 - Already up to date", devNum)
		end
	end)
end

function updateStatus(devNum, force)
	D(devNum, "updateStatus(%1,%2)", devNum, force)
	devNum = tonumber(devNum)

	local deviceNumberStartAt = getVar(MYSID, "DeviceNumberStartAt", 0, devNum) -- support bridges on openLuup

	sendDeviceCommand(devNum, COMMANDS.endpoints.list, "GET", "",
		function(r)
			L(devNum, "updateStatus: %1", r)
			local jsonResponse, _, err = json.decode(r)
			local mappedDevices = ""

			if not err then
				local devices = jsonResponse
				local handledDevices = 0
				local handledScenes = 0

				for _, device in ipairs(jsonResponse) do
					if device.mapType == "veraDevice" then -- get only lights
						local devId = tonumber(device.mapId)
						if devId ~= nil then
							local internalDevId = devId+deviceNumberStartAt	
							if luup.devices[internalDevId] == nil or device.id == nil then
								L(devNum, "Cannot find #%1", internalDevId)
							else
								deviceMap[internalDevId] = device.id -- save mapping

								D(devNum, 'Discovery: #%1 - %2 (#%3)', internalDevId, luup.devices[internalDevId].description, device.id)

								-- get bridge values
								local bridgeStatus = device.deviceState.on == "true" and "1" or "0"
								local bridgeBri = tonumber(device.deviceState.bri or "-1")
								local bridgeColor = fromHueToVeraColor(device.deviceState)
							
								-- set watches
								if not watchesReady then
									luup.variable_watch("HABridge1Watch", SWITCHSID, "Status", internalDevId)

									if bridgeBri >-1 then
										luup.variable_watch("HABridge1Watch", DIMMERSID, "LoadLevelStatus", internalDevId)
									end

									if device.deviceState.colormode ~= nil then
										luup.variable_watch("HABridge1Watch", COLORSID, "CurrentColor", internalDevId)
									end

									D(devNum, 'Watch added for #%1 - %2 (#%3)', internalDevId, luup.devices[internalDevId].description, device.id)

									mappedDevices = mappedDevices .. tostring(internalDevId) .. "-" .. tostring(device.id) .. " \n" 
								end

								-- update immediately on startup
								updateDeviceStatus(devNum, internalDevId, bridgeStatus, bridgeBri, bridgeColor)

								handledDevices = handledDevices + 1
							end
						end
					elseif device.mapType == "veraScene" then -- get only scenes
						local devId = tonumber(device.mapId)
						if devId ~= nil then
							local internalDevId = devId+deviceNumberStartAt	

							D(devNum, 'Discovery (scene): #%1 (#%2)', internalDevId, device.id)
							updateBridge(masterID, devNum, internalDevId, 0, 1, nil)

							handledScenes = handledScenes + 1
						end
					else
						D(devNum, 'Discovery [IGNORED]: #%1 (#%2) - %3', device.mapType, device.id, device)
					end
				end

				setVar(ALTUISID, "DisplayLine1", "Devices: " .. tostring(#devices) .. ' - Mapped: ' .. tostring(handledDevices).. ' - Scenes: ' .. tostring(handledScenes), devNum)

				watchesReady = true
			end

			setVar(ALTUISID, "DisplayLine2", "Last Global Sync: " .. formatDateTime(os.time()), devNum)
			setVar(MYSID, "DeviceMapping", mappedDevices, devNum)

			-- update after startup
			updateDeviceStatus(devNum, internalDevId, bridgeStatus, bridgeBri, bridgeColor)
		end,
		function() -- failure
			-- TODO: more logging?
			L(devNum, 'Discovery failed: %1', r)
		end
		)
end

function startPlugin(deviceID)
	masterID = deviceID
	L(deviceID, "Plugin starting")

	-- date format support
	dateFormat = luup.attr_get("date_format", 0) or "yy-mm-dd"
	timeFormat = luup.attr_get("timeFormat", 0) or "24hr"

	L(devNum, "Plugin start: child #%1 - %2", deviceID, luup.devices[deviceID].description)

	-- generic init
	initVar(MYSID, "DebugMode", 0, deviceID)
	initVar(MYSID, "DeviceNumberStartAt", 0, deviceID)

	-- device categories
	local category_num = luup.attr_get("category_num", deviceID) or 0
	if category_num == 0 then
		luup.attr_set("category_num", "2", deviceID)
		luup.attr_set("subcategory_num", "4", deviceID)
	end

	setVar(HASID, "Configured", 1, deviceID)
	setVar(HASID, "CommFailure", 0, deviceID)

	-- IP is mandatory, so inform the user
	local ip = luup.attr_get("ip", deviceID)
	if ip == nil or string.len(ip) == 0 then -- no IP = failure
		luup.set_failure(2, deviceID)
		return false, "Please set your HA-Bridge IP adddress", _PLUGIN_NAME
	end

	-- check for dependencies at startup
	local _ ,dkjson = pcall(require, "dkjson")
	if not dkjson or type(dkjson) ~= "table" then
		L('Failure: dkjson library not found')
		luup.set_failure(1, deviceID)
		return false, "Please install dkjson", _PLUGIN_NAME
	end

	-- start update
	updateStatus(deviceID, true)

	-- status
	luup.set_failure(0, deviceID)

	D(devNum, "Plugin start (completed): child #%1", deviceID)

	return true, "Ready", _PLUGIN_NAME
end