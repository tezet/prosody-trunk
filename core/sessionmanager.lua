-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local tonumber, tostring = tonumber, tostring;
local ipairs, pairs, print, next= ipairs, pairs, print, next;
local collectgarbage = collectgarbage;
local format = import("string", "format");

local hosts = hosts;
local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

local modulemanager = require "core.modulemanager";
local logger = require "util.logger";
local log = logger.init("sessionmanager");
local error = error;
local uuid_generate = require "util.uuid".generate;
local rm_load_roster = require "core.rostermanager".load_roster;
local config_get = require "core.configmanager".get;
local nameprep = require "util.encodings".stringprep.nameprep;

local fire_event = require "core.eventmanager".fire_event;
local add_task = require "util.timer".add_task;
local gettime = require "socket".gettime;

local st = require "util.stanza";

local c2s_timeout = config_get("*", "core", "c2s_timeout");

local newproxy = newproxy;
local getmetatable = getmetatable;

module "sessionmanager"

local open_sessions = 0;

function new_session(conn)
	local session = { conn = conn, type = "c2s_unauthed", conntime = gettime() };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () open_sessions = open_sessions - 1; end;
	end
	open_sessions = open_sessions + 1;
	log("debug", "open sessions now: ".. open_sessions);
	local w = conn.write;
	session.send = function (t) w(tostring(t)); end
	session.ip = conn.ip();
	local conn_name = "c2s"..tostring(conn):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);
	
	if c2s_timeout then
		add_task(c2s_timeout, function ()
			if session.type == "c2s_unauthed" then
				session:close("connection-timeout");
			end
		end);
	end
		
	return session;
end

function destroy_session(session, err)
	(session.log or log)("info", "Destroying session for %s (%s@%s)", session.full_jid or "(unknown)", session.username or "(unknown)", session.host or "(unknown)");
	
	-- Remove session/resource from user's session list
	if session.full_jid then
		hosts[session.host].events.fire_event("resource-unbind", {session=session, error=err});

		hosts[session.host].sessions[session.username].sessions[session.resource] = nil;
		full_sessions[session.full_jid] = nil;
			
		if not next(hosts[session.host].sessions[session.username].sessions) then
			log("debug", "All resources of %s are now offline", session.username);
			hosts[session.host].sessions[session.username] = nil;
			bare_sessions[session.username..'@'..session.host] = nil;
		end
	end
	
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
end

function make_authenticated(session, username)
	session.username = username;
	if session.type == "c2s_unauthed" then
		session.type = "c2s";
	end
	session.log("info", "Authenticated as %s@%s", username or "(unknown)", session.host or "(unknown)");
	return true;
end

-- returns true, nil on success
-- returns nil, err_type, err, err_message on failure
function bind_resource(session, resource)
	if not session.username then return nil, "auth", "not-authorized", "Cannot bind resource before authentication"; end
	if session.resource then return nil, "cancel", "already-bound", "Cannot bind multiple resources on a single connection"; end
	-- We don't support binding multiple resources

	resource = resource or uuid_generate();
	--FIXME: Randomly-generated resources must be unique per-user, and never conflict with existing
	
	if not hosts[session.host].sessions[session.username] then
		local sessions = { sessions = {} };
		hosts[session.host].sessions[session.username] = sessions;
		bare_sessions[session.username..'@'..session.host] = sessions;
	else
		local sessions = hosts[session.host].sessions[session.username].sessions;
		local limit = config_get(session.host, "core", "max_resources") or 10;
		if #sessions >= limit then
			return nil, "cancel", "conflict", "Resource limit reached; only "..limit.." resources allowed";
		end
		if sessions[resource] then
			-- Resource conflict
			local policy = config_get(session.host, "core", "conflict_resolve");
			local increment;
			if policy == "random" then
				resource = uuid_generate();
				increment = true;
			elseif policy == "increment" then
				increment = true; -- TODO ping old resource
			elseif policy == "kick_new" then
				return nil, "cancel", "conflict", "Resource already exists";
			else -- if policy == "kick_old" then
				sessions[resource]:close {
					condition = "conflict";
					text = "Replaced by new connection";
				};
				if not next(sessions) then
					hosts[session.host].sessions[session.username] = { sessions = sessions };
					bare_sessions[session.username.."@"..session.host] = hosts[session.host].sessions[session.username];
				end
			end
			if increment and sessions[resource] then
				local count = 1;
				while sessions[resource.."#"..count] do
					count = count + 1;
				end
				resource = resource.."#"..count;
			end
		end
	end
	
	session.resource = resource;
	session.full_jid = session.username .. '@' .. session.host .. '/' .. resource;
	hosts[session.host].sessions[session.username].sessions[resource] = session;
	full_sessions[session.full_jid] = session;
	
	session.roster = rm_load_roster(session.username, session.host);
	
	hosts[session.host].events.fire_event("resource-bind", {session=session});
	
	return true;
end

function streamopened(session, attr)
	local send = session.send;
	session.host = attr.to or error("Client failed to specify destination hostname");
	session.host = nameprep(session.host);
	session.version = tonumber(attr.version) or 0;
	session.streamid = uuid_generate();
	(session.log or session)("debug", "Client sent opening <stream:stream> to %s", session.host);

	if not hosts[session.host] then
		-- We don't serve this host...
		session:close{ condition = "host-unknown", text = "This server does not serve "..tostring(session.host)};
		return;
	end

	send("<?xml version='1.0'?>");
	send(format("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='%s' from='%s' version='1.0' xml:lang='en'>", session.streamid, session.host));

	(session.log or log)("debug", "Sent reply <stream:stream> to client");
	session.notopen = nil;

	-- If session.secure is *false* (not nil) then it means we /were/ encrypting
	-- since we now have a new stream header, session is secured
	if session.secure == false then
		session.secure = true;
	end

	local features = st.stanza("stream:features");
	fire_event("stream-features", session, features);

	send(features);

end

function streamclosed(session)
	session.send("</stream:stream>");
	session.notopen = true;
end

function send_to_available_resources(user, host, stanza)
	local jid = user.."@"..host;
	local count = 0;
	local user = bare_sessions[jid];
	if user then
		for k, session in pairs(user.sessions) do
			if session.presence then
				session.send(stanza);
				count = count + 1;
			end
		end
	end
	return count;
end

return _M;
