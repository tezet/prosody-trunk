-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*";

local prosody = _G.prosody;
local hosts = prosody.hosts;
local connlisteners_register = require "net.connlisteners".register;

local console_listener = { default_port = 5582; default_mode = "*l"; };

require "util.iterators";
local set, array = require "util.set", require "util.array";

local commands = {};
local def_env = {};
local default_env_mt = { __index = def_env };

console = {};

function console:new_session(conn)
	local w = function(s) conn.write(s:gsub("\n", "\r\n")); end;
	local session = { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (t) w("| "..tostring(t).."\n"); end;
			disconnect = function () conn.close(); end;
			};
	session.env = setmetatable({}, default_env_mt);
	
	-- Load up environment with helper objects
	for name, t in pairs(def_env) do
		if type(t) == "table" then
			session.env[name] = setmetatable({ session = session }, { __index = t });
		end
	end
	
	return session;
end

local sessions = {};

function console_listener.listener(conn, data)
	local session = sessions[conn];
	
	if not session then
		-- Handle new connection
		session = console:new_session(conn);
		sessions[conn] = session;
		printbanner(session);
	end
	if data then
		-- Handle data
		(function(session, data)
			local useglobalenv;
			
			if data:match("[!.]$") then
				local command = data:lower();
				command = data:match("^%w+") or data:match("%p");
				if commands[command] then
					commands[command](session, data);
					return;
				end
			end

			if data:match("^>") then
				data = data:gsub("^>", "");
				useglobalenv = true;
			end
			
			session.env._ = data;
			
			local chunk, err = loadstring("return "..data);
			if not chunk then
				chunk, err = loadstring(data);
				if not chunk then
					err = err:gsub("^%[string .-%]:%d+: ", "");
					err = err:gsub("^:%d+: ", "");
					err = err:gsub("'<eof>'", "the end of the line");
					session.print("Sorry, I couldn't understand that... "..err);
					return;
				end
			end
			
			setfenv(chunk, (useglobalenv and _G) or session.env or nil);
			
			local ranok, taskok, message = pcall(chunk);
			
			if not ranok then
				session.print("Fatal error while running command, it did not complete");
				session.print("Error: "..taskok);
				return;
			end
			
			if not message then
				session.print("Result: "..tostring(taskok));
				return;
			elseif (not taskok) and message then
				session.print("Command completed with a problem");
				session.print("Message: "..tostring(message));
				return;
			end
			
			session.print("OK: "..tostring(message));
		end)(session, data);
	end
	session.send(string.char(0));
end

function console_listener.disconnect(conn, err)
	
end

connlisteners_register('console', console_listener);

-- Console commands --
-- These are simple commands, not valid standalone in Lua

function commands.bye(session)
	session.print("See you! :)");
	session.disconnect();
end

commands["!"] = function (session, data)
	if data:match("^!!") then
		session.print("!> "..session.env._);
		return console_listener.listener(session.conn, session.env._);
	end
	local old, new = data:match("^!(.-[^\\])!(.-)!$");
	if old and new then
		local ok, res = pcall(string.gsub, session.env._, old, new);
		if not ok then
			session.print(res)
			return;
		end
		session.print("!> "..res);
		return console_listener.listener(session.conn, res);
	end
	session.print("Sorry, not sure what you want");
end

-- Session environment --
-- Anything in def_env will be accessible within the session as a global variable

def_env.server = {};
function def_env.server:reload()
	prosody.unlock_globals();
	dofile "prosody"
	prosody = _G.prosody;
	return true, "Server reloaded";
end

def_env.module = {};

local function get_hosts_set(hosts)
	if type(hosts) == "table" then
		if hosts[1] then
			return set.new(hosts);
		elseif hosts._items then
			return hosts;
		end
	elseif type(hosts) == "string" then
		return set.new { hosts };
	elseif hosts == nil then
		return set.new(array.collect(keys(prosody.hosts)))
			/ function (host) return prosody.hosts[host].type == "local"; end;
	end
end

function def_env.module:load(name, hosts, config)
	local mm = require "modulemanager";
	
	hosts = get_hosts_set(hosts);
	
	-- Load the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if (not mm.is_loaded(host, name)) then
			ok, err = mm.load(host, name, config);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error loading module");
			else
				count = count + 1;
				self.session.print("Loaded for "..host);
			end
		end
	end
	
	return ok, (ok and "Module loaded onto "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));	
end

function def_env.module:unload(name, hosts)
	local mm = require "modulemanager";

	hosts = get_hosts_set(hosts);
	
	-- Unload the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if mm.is_loaded(host, name) then
			ok, err = mm.unload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error unloading module");
			else
				count = count + 1;
				self.session.print("Unloaded from "..host);
			end
		end
	end
	return ok, (ok and "Module unloaded from "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

function def_env.module:reload(name, hosts)
	local mm = require "modulemanager";

	hosts = get_hosts_set(hosts);
	
	-- Reload the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if mm.is_loaded(host, name) then
			ok, err = mm.reload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error reloading module");
			else
				count = count + 1;
				if ok == nil then
					ok = true;
				end
				self.session.print("Reloaded on "..host);
			end
		end
	end
	return ok, (ok and "Module reloaded on "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

def_env.config = {};
function def_env.config:load(filename, format)
	local config_load = require "core.configmanager".load;
	local ok, err = config_load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end

function def_env.config:get(host, section, key)
	local config_get = require "core.configmanager".get
	return true, tostring(config_get(host, section, key));
end

def_env.hosts = {};
function def_env.hosts:list()
	for host, host_session in pairs(hosts) do
		self.session.print(host);
	end
	return true, "Done";
end

function def_env.hosts:add(name)
end

def_env.c2s = {};

local function show_c2s(callback)
	for hostname, host in pairs(hosts) do
		for username, user in pairs(host.sessions or {}) do
			for resource, session in pairs(user.sessions or {}) do
				local jid = username.."@"..hostname.."/"..resource;
				callback(jid, session);
			end
		end
	end
end

function def_env.c2s:show(match_jid)
	local print, count = self.session.print, 0;
	show_c2s(function (jid)
		if (not match_jid) or jid:match(match_jid) then
			count = count + 1;
			print(jid);
		end		
	end);
	return true, "Total: "..count.." clients";
end

function def_env.c2s:show_insecure(match_jid)
	local print, count = self.session.print, 0;
	show_c2s(function (jid, session)
		if ((not match_jid) or jid:match(match_jid)) and not session.secure then
			count = count + 1;
			print(jid);
		end		
	end);
	return true, "Total: "..count.." insecure client connections";
end

function def_env.c2s:show_secure(match_jid)
	local print, count = self.session.print, 0;
	show_c2s(function (jid, session)
		if ((not match_jid) or jid:match(match_jid)) and session.secure then
			count = count + 1;
			print(jid);
		end		
	end);
	return true, "Total: "..count.." secure client connections";
end


def_env.s2s = {};
function def_env.s2s:show(match_jid)
	local _print = self.session.print;
	local print = self.session.print;
	
	local count_in, count_out = 0,0;
	
	for host, host_session in pairs(hosts) do
		print = function (...) _print(host); _print(...); print = _print; end
		for remotehost, session in pairs(host_session.s2sout) do
			if (not match_jid) or remotehost:match(match_jid) or host:match(match_jid) then
				count_out = count_out + 1;
				print("    "..host.." -> "..remotehost);
				if session.sendq then
					print("        There are "..#session.sendq.." queued outgoing stanzas for this connection");
				end
				if session.type == "s2sout_unauthed" then
					if session.connecting then
						print("        Connection not yet established");
						if not session.srv_hosts then
							if not session.conn then
								print("        We do not yet have a DNS answer for this host's SRV records");
							else
								print("        This host has no SRV records, using A record instead");
							end
						elseif session.srv_choice then
							print("        We are on SRV record "..session.srv_choice.." of "..#session.srv_hosts);
							local srv_choice = session.srv_hosts[session.srv_choice];
							print("        Using "..(srv_choice.target or ".")..":"..(srv_choice.port or 5269));
						end
					elseif session.notopen then
						print("        The <stream> has not yet been opened");
					elseif not session.dialback_key then
						print("        Dialback has not been initiated yet");
					elseif session.dialback_key then
						print("        Dialback has been requested, but no result received");
					end
				end
			end
		end	
		
		for session in pairs(incoming_s2s) do
			if session.to_host == host and ((not match_jid) or host:match(match_jid) 
				or (session.from_host and session.from_host:match(match_jid))) then
				count_in = count_in + 1;
				print("    "..host.." <- "..(session.from_host or "(unknown)"));
				if session.type == "s2sin_unauthed" then
						print("        Connection not yet authenticated");
				end
				for name in pairs(session.hosts) do
					if name ~= session.from_host then
						print("        also hosts "..tostring(name));
					end
				end
			end
		end
		
		print = _print;
	end
	
	for session in pairs(incoming_s2s) do
		if not session.to_host and ((not match_jid) or session.from_host and session.from_host:match(match_jid)) then
			count_in = count_in + 1;
			print("Other incoming s2s connections");
			print("    (unknown) <- "..(session.from_host or "(unknown)"));			
		end
	end
	
	return true, "Total: "..count_out.." outgoing, "..count_in.." incoming connections";
end

-------------

function printbanner(session)
session.print [[
                   ____                \   /     _       
                    |  _ \ _ __ ___  ___  _-_   __| |_   _ 
                    | |_) | '__/ _ \/ __|/ _ \ / _` | | | |
                    |  __/| | | (_) \__ \ |_| | (_| | |_| |
                    |_|   |_|  \___/|___/\___/ \__,_|\__, |
                    A study in simplicity            |___/ 

]]
session.print("Welcome to the Prosody administration console. For a list of commands, type: help");
session.print("You may find more help on using this console in our online documentation at ");
session.print("http://prosody.im/doc/console\n");
end
