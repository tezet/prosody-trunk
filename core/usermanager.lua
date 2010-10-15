-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local datamanager = require "util.datamanager";
local modulemanager = require "core.modulemanager";
local log = require "util.logger".init("usermanager");
local type = type;
local error = error;
local ipairs = ipairs;
local hashes = require "util.hashes";
local jid_bare = require "util.jid".bare;
local config = require "core.configmanager";
local hosts = hosts;
local sasl_new = require "util.sasl".new;

local prosody = _G.prosody;

local setmetatable = setmetatable;

local default_provider = "internal_plain";

module "usermanager"

function new_null_provider()
	local function dummy() end;
	local function dummy_get_sasl_handler() return sasl_new(nil, {}); end
	return setmetatable({name = "null", get_sasl_handler = dummy_get_sasl_handler}, { __index = function() return dummy; end });
end

function initialize_host(host)
	local host_session = hosts[host];
	host_session.events.add_handler("item-added/auth-provider", function (event)
		local provider = event.item;
		local auth_provider = config.get(host, "core", "authentication") or default_provider;
		if provider.name == auth_provider then
			host_session.users = provider;
		end
		if host_session.users ~= nil and host_session.users.name ~= nil then
			log("debug", "host '%s' now set to use user provider '%s'", host, host_session.users.name);
		end
	end);
	host_session.events.add_handler("item-removed/auth-provider", function (event)
		local provider = event.item;
		if host_session.users == provider then
			host_session.users = new_null_provider();
		end
	end);
   	host_session.users = new_null_provider(); -- Start with the default usermanager provider
   	local auth_provider = config.get(host, "core", "authentication") or default_provider;
   	if auth_provider ~= "null" then
   		modulemanager.load(host, "auth_"..auth_provider);
   	end
end;
prosody.events.add_handler("host-activated", initialize_host, 100);
prosody.events.add_handler("component-activated", initialize_host, 100);

function test_password(username, host, password)
	return hosts[host].users.test_password(username, password);
end

function get_password(username, host)
	return hosts[host].users.get_password(username);
end

function set_password(username, password, host)
	return hosts[host].users.set_password(username, password);
end

function user_exists(username, host)
	return hosts[host].users.user_exists(username);
end

function create_user(username, password, host)
	return hosts[host].users.create_user(username, password);
end

function get_sasl_handler(host)
	return hosts[host].users.get_sasl_handler();
end

function get_provider(host)
	return hosts[host].users;
end

function is_admin(jid, host)
	local is_admin;
	jid = jid_bare(jid);
	host = host or "*";
	
	local host_admins = config.get(host, "core", "admins");
	local global_admins = config.get("*", "core", "admins");
	
	if host_admins and host_admins ~= global_admins then
		if type(host_admins) == "table" then
			for _,admin in ipairs(host_admins) do
				if admin == jid then
					is_admin = true;
					break;
				end
			end
		elseif host_admins then
			log("error", "Option 'admins' for host '%s' is not a list", host);
		end
	end
	
	if not is_admin and global_admins then
		if type(global_admins) == "table" then
			for _,admin in ipairs(global_admins) do
				if admin == jid then
					is_admin = true;
					break;
				end
			end
		elseif global_admins then
			log("error", "Global option 'admins' is not a list");
		end
	end
	
	-- Still not an admin, check with auth provider
	if not is_admin and host ~= "*" and hosts[host].users.is_admin then
		is_admin = hosts[host].users.is_admin(jid);
	end
	return is_admin or false;
end

return _M;
