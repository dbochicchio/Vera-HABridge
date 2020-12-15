module("L_HABridge1", package.seeall)

local _PLUGIN_NAME = "HABridge"
local _PLUGIN_VERSION = "0.10"

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

	updateDeviceStatus(masterID, devNum, -1, -1)
end

function updateBridge(masterID, devNum, internalId, currentStatus, currentBri)
	local endpoint = string.format(COMMANDS.endpoints.updateStatus, "vera", tostring(internalId))
	sendDeviceCommand(masterID, endpoint, "PUT", {on = currentStatus == "1" and "true" or "false", bri = string.format("%.0f", currentBri)},
	function() -- success
		D(masterID, '#%1 - Update status: success!', devNum)
	end,
	function(r)-- failed
		-- TODO: more logging?
		D(masterID, '#%1 - Update status failed: %2', devNum, r)
	end)
end

function updateDeviceStatus(masterID, devNum, bridgeStatus, bridgeBri)
	D(masterID, "updateDeviceStatus(%1,%2,%3,%4)", masterID, devNum, bridgeStatus, bridgeBri)

	local internalId = deviceMap[devNum] -- get mapped id

	-- current status
	local currentStatus = getVar(SWITCHSID, "Status", "0", devNum)

	-- current brightness
	local currentBri = getVar(DIMMERSID, "LoadLevelStatus", "-1", devNum)

	if currentBri == "-1" or currentStatus == "0" then
		-- special case for non dimmable lights -- alexa wants 1 as minimum value
		currentBri = currentStatus == "0" and "1" or "100"
	end

	-- compute bri on a scale of 1/254
	currentBri = tonumber(currentBri) * 254 / 100

	D(masterID, "#%1 - current status: %2 - bridge status: %3", devNum, currentStatus, bridgeStatus)
	D(masterID, "#%1 - current bri: %2 - bridge bri: %3", devNum, currentBri, bridgeBri)

	-- status not in sync, update bridge
	if force or currentStatus ~= bridgeStatus or currentBri ~= bridgeBri then
		updateBridge(masterID, devNum, internalId, currentStatus, currentBri)
	else
		D(masterID, "#%1 - Already up to date", devNum)
	end
end

function updateStatus(devNum, force)
	D(devNum, "updateStatus(%1,%2)", devNum, force)
	devNum = tonumber(devNum)

	local deviceNumberStartAt = getVar(MYSID, "DeviceNumberStartAt", 0, devNum) -- support bridges on openLuup

	sendDeviceCommand(devNum, COMMANDS.endpoints.list, "GET", "",
		function(r)
			L(devNum, "updateStatus: %1", r)
			local jsonResponse, _, err = json.decode(r)

			if not err then
				local devices = jsonResponse
				local veraCount = 0
				for _, device in ipairs(jsonResponse) do
					if device.mapType == "veraDevice" then -- get only lights
						local devId = tonumber(device.mapId)
						if devId ~= nil then
							local internalDevId = devId+deviceNumberStartAt	
							deviceMap[internalDevId] = device.id -- save mapping

							D(devNum, 'Discovery: #%1 - %2', devId, luup.devices[internalDevId].description)

							-- watches
							if not watchesReady then
								luup.variable_watch("HABridge1Watch", SWITCHSID, "Status", internalDevId)
								luup.variable_watch("HABridge1Watch", DIMMERSID, "LoadLevelStatus", internalDevId)

								D(devNum, 'Watch added for #%1 - %2', internalDevId, luup.devices[internalDevId].description)
							end

							-- update immediately on startup
							local bridgeStatus = device.deviceState.on == "true" and "1" or "0"
							local bridgeBri = tonumber(device.deviceState.bri)
							updateDeviceStatus(devNum, internalDevId, bridgeStatus, bridgeBri)

							veraCount = veraCount + 1
						end
					elseif device.map == "veraScene" then -- get only scenes
						local devId = tonumber(device.mapId)
						if devId ~= nil then
							local internalDevId = devId+deviceNumberStartAt	
							updateBridge(masterID, devNum, internalDevId, 0, 1)
						end
					end
				end

				setVar(ALTUISID, "DisplayLine1", "Devices: " .. tostring(#devices) .. ' - Vera: ' .. tostring(veraCount), devNum)

				watchesReady = true
			end

			setVar(ALTUISID, "DisplayLine2", "Last Update: " .. formatDateTime(os.time()), devNum)
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