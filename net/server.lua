
local use_luaevent = require "core.configmanager".get("*", "core", "use_libevent");

if use_luaevent then
	use_luaevent = pcall(require, "luaevent.core");
	if not use_luaevent then
		log("error", "libevent not found, falling back to select()");
	end
end

local server;

if use_luaevent then
	server = require "net.server_event";
	-- util.timer requires "net.server", so instead of having
	-- Lua look for, and load us again (causing a loop) - set this here
	-- (usually it isn't set until we return, look down there...)
	package.loaded["net.server"] = server;
	
	-- Backwards compatibility for timers, addtimer
	-- called a function roughly every second
	local add_task = require "util.timer".add_task;
	function server.addtimer(f)
		return add_task(1, function (...) f(...); return 1; end);
	end
else
	server = require "net.server_select";
	package.loaded["net.server"] = server;
end

-- require "net.server" shall now forever return this,
-- ie. server_select or server_event as chosen above.
return server; 
