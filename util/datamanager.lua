-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local format = string.format;
local setmetatable, type = setmetatable, type;
local pairs, ipairs = pairs, ipairs;
local char = string.char;
local loadfile, setfenv, pcall = loadfile, setfenv, pcall;
local log = require "util.logger".init("datamanager");
local io_open = io.open;
local os_remove = os.remove;
local io_popen = io.popen;
local tostring, tonumber = tostring, tonumber;
local error = error;
local next = next;
local t_insert = table.insert;
local append = require "util.serialization".append;
local path_separator = "/"; if os.getenv("WINDIR") then path_separator = "\\" end

module "datamanager"

---- utils -----
local encode, decode;
do 
	local urlcodes = setmetatable({}, { __index = function (t, k) t[k] = char(tonumber("0x"..k)); return t[k]; end });

	decode = function (s)
		return s and (s:gsub("+", " "):gsub("%%([a-fA-F0-9][a-fA-F0-9])", urlcodes));
	end

	encode = function (s)
		return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end));
	end
end

local _mkdir = {};
local function mkdir(path)
	path = path:gsub("/", path_separator); -- TODO as an optimization, do this during path creation rather than here
	if not _mkdir[path] then
		local x = io_popen("mkdir \""..path.."\" 2>&1"):read("*a");
		_mkdir[path] = true;
	end
	return path;
end

local data_path = "data";
local callback;

------- API -------------

function set_data_path(path)
	log("info", "Setting data path to: %s", path);
	data_path = path;
end
function set_callback(func)
	callback = func;
end

function getpath(username, host, datastore, ext, create)
	ext = ext or "dat";
	host = host and encode(host);
	username = username and encode(username);
	if username then
		if create then mkdir(mkdir(mkdir(data_path).."/"..host).."/"..datastore); end
		return format("%s/%s/%s/%s.%s", data_path, host, datastore, username, ext);
	elseif host then
		if create then mkdir(mkdir(data_path).."/"..host); end
		return format("%s/%s/%s.%s", data_path, host, datastore, ext);
	else
		if create then mkdir(data_path); end
		return format("%s/%s.%s", data_path, datastore, ext);
	end
end

function load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore));
	if not data then
		log("debug", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	setfenv(data, {});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	return ret;
end

function store(username, host, datastore, data)
	if not data then
		data = {};
	end
	if callback and callback(username, host, datastore) then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, nil, true), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("return ");
	append(f, data);
	f:close();
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username, host);
		os_remove(getpath(username, host, datastore));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_append(username, host, datastore, data)
	if not data then return; end
	if callback and callback(username, host, datastore) then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list", true), "a+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	f:write("item(");
	append(f, data);
	f:write(");\n");
	f:close();
	return true;
end

function list_store(username, host, datastore, data)
	if not data then
		data = {};
	end
	if callback and callback(username, host, datastore) then return true; end
	-- save the datastore
	local f, msg = io_open(getpath(username, host, datastore, "list", true), "w+");
	if not f then
		log("error", "Unable to write to "..datastore.." storage ('"..msg.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return;
	end
	for _, d in ipairs(data) do
		f:write("item(");
		append(f, d);
		f:write(");\n");
	end
	f:close();
	if next(data) == nil then -- try to delete empty datastore
		log("debug", "Removing empty %s datastore for user %s@%s", datastore, username, host);
		os_remove(getpath(username, host, datastore, "list"));
	end
	-- we write data even when we are deleting because lua doesn't have a
	-- platform independent way of checking for non-exisitng files
	return true;
end

function list_load(username, host, datastore)
	local data, ret = loadfile(getpath(username, host, datastore, "list"));
	if not data then
		log("debug", "Failed to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	local items = {};
	setfenv(data, {item = function(i) t_insert(items, i); end});
	local success, ret = pcall(data);
	if not success then
		log("error", "Unable to load "..datastore.." storage ('"..ret.."') for user: "..(username or "nil").."@"..(host or "nil"));
		return nil;
	end
	return items;
end

return _M;
