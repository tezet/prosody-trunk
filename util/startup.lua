-- Ignore the CFG_* variables
-- luacheck: ignore 113/CFG_CONFIGDIR 113/CFG_SOURCEDIR 113/CFG_DATADIR 113/CFG_PLUGINDIR
local startup = {};

local prosody = { events = require "util.events".new() };

local config = require "core.configmanager";

local dependencies = require "util.dependencies";

local original_logging_config;

function startup.read_config()
	local filenames = {};

	local filename;
	if arg[1] == "--config" and arg[2] then
		table.insert(filenames, arg[2]);
		if CFG_CONFIGDIR then
			table.insert(filenames, CFG_CONFIGDIR.."/"..arg[2]);
		end
		table.remove(arg, 1); table.remove(arg, 1);
	elseif os.getenv("PROSODY_CONFIG") then -- Passed by prosodyctl
			table.insert(filenames, os.getenv("PROSODY_CONFIG"));
	else
		table.insert(filenames, (CFG_CONFIGDIR or ".").."/prosody.cfg.lua");
	end
	for _,_filename in ipairs(filenames) do
		filename = _filename;
		local file = io.open(filename);
		if file then
			file:close();
			prosody.config_file = filename;
			CFG_CONFIGDIR = filename:match("^(.*)[\\/][^\\/]*$"); -- luacheck: ignore 111
			break;
		end
	end
	prosody.config_file = filename
	local ok, level, err = config.load(filename);
	if not ok then
		print("\n");
		print("**************************");
		if level == "parser" then
			print("A problem occured while reading the config file "..filename);
			print("");
			local err_line, err_message = tostring(err):match("%[string .-%]:(%d*): (.*)");
			if err:match("chunk has too many syntax levels$") then
				print("An Include statement in a config file is including an already-included");
				print("file and causing an infinite loop. An Include statement in a config file is...");
			else
				print("Error"..(err_line and (" on line "..err_line) or "")..": "..(err_message or tostring(err)));
			end
			print("");
		elseif level == "file" then
			print("Prosody was unable to find the configuration file.");
			print("We looked for: "..filename);
			print("A sample config file is included in the Prosody download called prosody.cfg.lua.dist");
			print("Copy or rename it to prosody.cfg.lua and edit as necessary.");
		end
		print("More help on configuring Prosody can be found at https://prosody.im/doc/configure");
		print("Good luck!");
		print("**************************");
		print("");
		os.exit(1);
	end
end

function startup.check_dependencies()
	if not dependencies.check_dependencies() then
		os.exit(1);
	end
end

-- luacheck: globals socket server

function startup.load_libraries()
	-- Load socket framework
	-- luacheck: ignore 111/server 111/socket
	socket = require "socket";
	server = require "net.server"
end

-- The global log() gets defined by loggingmanager
-- luacheck: ignore 113/log

function startup.init_logging()
	-- Initialize logging
	require "core.loggingmanager"
end

function startup.log_dependency_warnings()
	dependencies.log_warnings();
end

function startup.sanity_check()
	for host, host_config in pairs(config.getconfig()) do
		if host ~= "*"
		and host_config.enabled ~= false
		and not host_config.component_module then
			return;
		end
	end
	log("error", "No enabled VirtualHost entries found in the config file.");
	log("error", "At least one active host is required for Prosody to function. Exiting...");
	os.exit(1);
end

function startup.sandbox_require()
	-- Replace require() with one that doesn't pollute _G, required
	-- for neat sandboxing of modules
	-- luacheck: ignore 113/getfenv 111/require
	local _realG = _G;
	local _real_require = require;
	local getfenv = getfenv or function (f)
		-- FIXME: This is a hack to replace getfenv() in Lua 5.2
		local name, env = debug.getupvalue(debug.getinfo(f or 1).func, 1);
		if name == "_ENV" then
			return env;
		end
	end
	function require(...) -- luacheck: ignore 121
		local curr_env = getfenv(2);
		local curr_env_mt = getmetatable(curr_env);
		local _realG_mt = getmetatable(_realG);
		if curr_env_mt and curr_env_mt.__index and not curr_env_mt.__newindex and _realG_mt then
			local old_newindex, old_index;
			old_newindex, _realG_mt.__newindex = _realG_mt.__newindex, curr_env;
			old_index, _realG_mt.__index = _realG_mt.__index, function (_G, k) -- luacheck: ignore 212/_G
				return rawget(curr_env, k);
			end;
			local ret = _real_require(...);
			_realG_mt.__newindex = old_newindex;
			_realG_mt.__index = old_index;
			return ret;
		end
		return _real_require(...);
	end
end

function startup.set_function_metatable()
	local mt = {};
	function mt.__index(f, upvalue)
		local i, name, value = 0;
		repeat
			i = i + 1;
			name, value = debug.getupvalue(f, i);
		until name == upvalue or name == nil;
		return value;
	end
	function mt.__newindex(f, upvalue, value)
		local i, name = 0;
		repeat
			i = i + 1;
			name = debug.getupvalue(f, i);
		until name == upvalue or name == nil;
		if name then
			debug.setupvalue(f, i, value);
		end
	end
	function mt.__tostring(f)
		local info = debug.getinfo(f);
		return ("function(%s:%d)"):format(info.short_src:match("[^\\/]*$"), info.linedefined);
	end
	debug.setmetatable(function() end, mt);
end

function startup.detect_platform()
	prosody.platform = "unknown";
	if os.getenv("WINDIR") then
		prosody.platform = "windows";
	elseif package.config:sub(1,1) == "/" then
		prosody.platform = "posix";
	end
end

function startup.detect_installed()
	prosody.installed = nil;
	if CFG_SOURCEDIR and (prosody.platform == "windows" or CFG_SOURCEDIR:match("^/")) then
		prosody.installed = true;
	end
end

function startup.init_global_state()
	-- luacheck: ignore 121
	prosody.bare_sessions = {};
	prosody.full_sessions = {};
	prosody.hosts = {};

	-- COMPAT: These globals are deprecated
	-- luacheck: ignore 111/bare_sessions 111/full_sessions 111/hosts
	bare_sessions = prosody.bare_sessions;
	full_sessions = prosody.full_sessions;
	hosts = prosody.hosts;

	local data_path = config.get("*", "data_path") or CFG_DATADIR or "data";
	local custom_plugin_paths = config.get("*", "plugin_paths");
	if custom_plugin_paths then
		local path_sep = package.config:sub(3,3);
		-- path1;path2;path3;defaultpath...
		-- luacheck: ignore 111
		CFG_PLUGINDIR = table.concat(custom_plugin_paths, path_sep)..path_sep..(CFG_PLUGINDIR or "plugins");
	end
	prosody.paths = { source = CFG_SOURCEDIR, config = CFG_CONFIGDIR or ".",
	                  plugins = CFG_PLUGINDIR or "plugins", data = data_path };

	prosody.arg = _G.arg;

	startup.detect_platform();
	startup.detect_installed();
	_G.prosody = prosody;
end

function startup.chdir()
	if prosody.installed then
		-- Change working directory to data path.
		require "lfs".chdir(prosody.paths.data);
	end
end

function startup.add_global_prosody_functions()
	-- Function to reload the config file
	function prosody.reload_config()
		log("info", "Reloading configuration file");
		prosody.events.fire_event("reloading-config");
		local ok, level, err = config.load(prosody.config_file);
		if not ok then
			if level == "parser" then
				log("error", "There was an error parsing the configuration file: %s", tostring(err));
			elseif level == "file" then
				log("error", "Couldn't read the config file when trying to reload: %s", tostring(err));
			end
		end
		return ok, (err and tostring(level)..": "..tostring(err)) or nil;
	end

	-- Function to reopen logfiles
	function prosody.reopen_logfiles()
		log("info", "Re-opening log files");
		prosody.events.fire_event("reopen-log-files");
	end

	-- Function to initiate prosody shutdown
	function prosody.shutdown(reason, code)
		log("info", "Shutting down: %s", reason or "unknown reason");
		prosody.shutdown_reason = reason;
		prosody.shutdown_code = code;
		prosody.events.fire_event("server-stopping", {
			reason = reason;
			code = code;
		});
		server.setquitting(true);
	end
end

function startup.load_secondary_libraries()
	--- Load and initialise core modules
	require "util.import"
	require "util.xmppstream"
	require "core.stanza_router"
	require "core.statsmanager"
	require "core.hostmanager"
	require "core.portmanager"
	require "core.modulemanager"
	require "core.usermanager"
	require "core.rostermanager"
	require "core.sessionmanager"
	package.loaded['core.componentmanager'] = setmetatable({},{__index=function()
		log("warn", "componentmanager is deprecated: %s", debug.traceback():match("\n[^\n]*\n[ \t]*([^\n]*)"));
		return function() end
	end});

	require "util.array"
	require "util.datetime"
	require "util.iterators"
	require "util.timer"
	require "util.helpers"

	pcall(require, "util.signal") -- Not on Windows

	-- Commented to protect us from
	-- the second kind of people
	--[[
	pcall(require, "remdebug.engine");
	if remdebug then remdebug.engine.start() end
	]]

	require "util.stanza"
	require "util.jid"
end

function startup.init_http_client()
	local http = require "net.http"
	local config_ssl = config.get("*", "ssl") or {}
	local https_client = config.get("*", "client_https_ssl")
	http.default.options.sslctx = require "core.certmanager".create_context("client_https port 0", "client",
		{ capath = config_ssl.capath, cafile = config_ssl.cafile, verify = "peer", }, https_client);
end

function startup.init_data_store()
	require "core.storagemanager";
end

function startup.prepare_to_start()
	log("info", "Prosody is using the %s backend for connection handling", server.get_backend());
	-- Signal to modules that we are ready to start
	prosody.events.fire_event("server-starting");
	prosody.start_time = os.time();
end

function startup.init_global_protection()
	-- Catch global accesses
	-- luacheck: ignore 212/t
	local locked_globals_mt = {
		__index = function (t, k) log("warn", "%s", debug.traceback("Attempt to read a non-existent global '"..tostring(k).."'", 2)); end;
		__newindex = function (t, k, v) error("Attempt to set a global: "..tostring(k).." = "..tostring(v), 2); end;
	};

	function prosody.unlock_globals()
		setmetatable(_G, nil);
	end

	function prosody.lock_globals()
		setmetatable(_G, locked_globals_mt);
	end

	-- And lock now...
	prosody.lock_globals();
end

function startup.read_version()
	-- Try to determine version
	local version_file = io.open((CFG_SOURCEDIR or ".").."/prosody.version");
	prosody.version = "unknown";
	if version_file then
		prosody.version = version_file:read("*a"):gsub("%s*$", "");
		version_file:close();
		if #prosody.version == 12 and prosody.version:match("^[a-f0-9]+$") then
			prosody.version = "hg:"..prosody.version;
		end
	else
		local hg = require"util.mercurial";
		local hgid = hg.check_id(CFG_SOURCEDIR or ".");
		if hgid then prosody.version = "hg:" .. hgid; end
	end
end

function startup.log_greeting()
	log("info", "Hello and welcome to Prosody version %s", prosody.version);
end

function startup.notify_started()
	prosody.events.fire_event("server-started");
end

-- Override logging config (used by prosodyctl)
function startup.force_console_logging()
	original_logging_config = config.get("*", "log");
	config.set("*", "log", { { levels = { min="info" }, to = "console" } });
end

function startup.switch_user()
	-- Switch away from root and into the prosody user --
	-- NOTE: This function is only used by prosodyctl.
	-- The prosody process is built with the assumption that
	-- it is already started as the appropriate user.

	local want_pposix_version = "0.4.0";
	local have_pposix, pposix = pcall(require, "util.pposix");

	if have_pposix and pposix then
		if pposix._VERSION ~= want_pposix_version then
			print(string.format("Unknown version (%s) of binary pposix module, expected %s",
				tostring(pposix._VERSION), want_pposix_version));
			os.exit(1);
		end
		prosody.current_uid = pposix.getuid();
		local arg_root = arg[1] == "--root";
		if arg_root then table.remove(arg, 1); end
		if prosody.current_uid == 0 and config.get("*", "run_as_root") ~= true and not arg_root then
			-- We haz root!
			local desired_user = config.get("*", "prosody_user") or "prosody";
			local desired_group = config.get("*", "prosody_group") or desired_user;
			local ok, err = pposix.setgid(desired_group);
			if ok then
				ok, err = pposix.initgroups(desired_user);
			end
			if ok then
				ok, err = pposix.setuid(desired_user);
				if ok then
					-- Yay!
					prosody.switched_user = true;
				end
			end
			if not prosody.switched_user then
				-- Boo!
				print("Warning: Couldn't switch to Prosody user/group '"..tostring(desired_user).."'/'"..tostring(desired_group).."': "..tostring(err));
			else
				-- Make sure the Prosody user can read the config
				local conf, err, errno = io.open(prosody.config_file);
				if conf then
					conf:close();
				else
					print("The config file is not readable by the '"..desired_user.."' user.");
					print("Prosody will not be able to read it.");
					print("Error was "..err);
					os.exit(1);
				end
			end
		end

		-- Set our umask to protect data files
		pposix.umask(config.get("*", "umask") or "027");
		pposix.setenv("HOME", prosody.paths.data);
		pposix.setenv("PROSODY_CONFIG", prosody.config_file);
	else
		print("Error: Unable to load pposix module. Check that Prosody is installed correctly.")
		print("For more help send the below error to us through https://prosody.im/discuss");
		print(tostring(pposix))
		os.exit(1);
	end
end

function startup.check_unwriteable()
	local function test_writeable(filename)
		local f, err = io.open(filename, "a");
		if not f then
			return false, err;
		end
		f:close();
		return true;
	end

	local unwriteable_files = {};
	if type(original_logging_config) == "string" and original_logging_config:sub(1,1) ~= "*" then
		local ok, err = test_writeable(original_logging_config);
		if not ok then
			table.insert(unwriteable_files, err);
		end
	elseif type(original_logging_config) == "table" then
		for _, rule in ipairs(original_logging_config) do
			if rule.filename then
				local ok, err = test_writeable(rule.filename);
				if not ok then
					table.insert(unwriteable_files, err);
				end
			end
		end
	end

	if #unwriteable_files > 0 then
		print("One of more of the Prosody log files are not");
		print("writeable, please correct the errors and try");
		print("starting prosodyctl again.");
		print("");
		for _, err in ipairs(unwriteable_files) do
			print(err);
		end
		print("");
		os.exit(1);
	end
end

function startup.make_host(hostname)
	return {
		type = "local",
		events = prosody.events,
		modules = {},
		sessions = {},
		users = require "core.usermanager".new_null_provider(hostname)
	};
end

function startup.make_dummy_hosts()
	-- When running under prosodyctl, we don't want to
	-- fully initialize the server, so we populate prosody.hosts
	-- with just enough things for most code to work correctly
	-- luacheck: ignore 122/hosts
	prosody.core_post_stanza = function () end; -- TODO: mod_router!

	for hostname in pairs(config.getconfig()) do
		hosts[hostname] = startup.make_host(hostname);
	end
end

-- prosodyctl only
function startup.prosodyctl()
	startup.read_config();
	startup.init_global_state();
	startup.chdir();
	startup.switch_user();
	startup.check_dependencies();
	startup.force_console_logging();
	startup.init_logging();
	startup.log_dependency_warnings();
	startup.check_unwriteable();
	startup.load_libraries();
	startup.init_global_protection();
	startup.init_http_client();
	startup.make_dummy_hosts();
end

function startup.prosody()
	-- These actions are in a strict order, as many depend on
	-- previous steps to have already been performed
	startup.read_config();
	startup.sanity_check();
	startup.sandbox_require();
	startup.set_function_metatable();
	startup.check_dependencies();
	startup.load_libraries();
	startup.init_global_state();
	startup.init_logging();
	startup.chdir();
	startup.add_global_prosody_functions();
	startup.read_version();
	startup.log_greeting();
	startup.log_dependency_warnings();
	startup.load_secondary_libraries();
	startup.init_http_client();
	startup.init_data_store();
	startup.init_global_protection();
	startup.prepare_to_start();
	startup.notify_started();
end

return startup;
