
local config = require "core.configmanager";
local encodings = require "util.encodings";
local stringprep = encodings.stringprep;
local usermanager = require "core.usermanager";
local signal = require "util.signal";

local nodeprep, nameprep = stringprep.nodeprep, stringprep.nameprep;

local io, os = io, os;
local tostring, tonumber = tostring, tonumber;
module "prosodyctl"

function adduser(params)
	local user, host, password = nodeprep(params.user), nameprep(params.host), params.password;
	if not user then
		return false, "invalid-username";
	elseif not host then
		return false, "invalid-hostname";
	end
	
	local ok = usermanager.create_user(user, password, host);
	if not ok then
		return false, "unable-to-save-data";
	end
	return true;
end

function user_exists(params)
	return usermanager.user_exists(params.user, params.host);
end

function passwd(params)
	if not _M.user_exists(params) then
		return false, "no-such-user";
	end
	
	return _M.adduser(params);
end

function deluser(params)
	if not _M.user_exists(params) then
		return false, "no-such-user";
	end
	params.password = nil;
	
	return _M.adduser(params);
end

function getpid()
	local pidfile = config.get("*", "core", "pidfile");
	if not pidfile then
		return false, "no-pidfile";
	end
	
	local file, err = io.open(pidfile);
	if not file then
		return false, "pidfile-read-failed", ret;
	end
	
	local pid = tonumber(file:read("*a"));
	file:close();
	
	if not pid then
		return false, "invalid-pid";
	end
	
	return true, pid;
end

function isrunning()
	local ok, pid, err = _M.getpid();
	if not ok then
		if pid == "pidfile-read-failed" then
			-- Report as not running, since we can't open the pidfile
			-- (it probably doesn't exist)
			return true, false;
		end
		return ok, pid;
	end
	return true, signal.kill(pid, 0) == 0;
end

function start()
	local ok, ret = _M.isrunning();
	if not ok then
		return ok, ret;
	end
	if ret then
		return false, "already-running";
	end
	if not CFG_SOURCEDIR then
		os.execute("./prosody");
	elseif CFG_SOURCEDIR:match("^/usr/local") then
		os.execute("/usr/local/bin/prosody");
	else
		os.execute("prosody");
	end
	return true;
end

function stop()
	local ok, ret = _M.isrunning();
	if not ok then
		return ok, ret;
	end
	if not ret then
		return false, "not-running";
	end
	
	local ok, pid = _M.getpid()
	if not ok then return false, pid; end
	
	signal.kill(pid, signal.SIGTERM);
	return true;
end
