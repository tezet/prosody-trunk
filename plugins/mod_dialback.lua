-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local send_s2s = require "core.s2smanager".send_to_host;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;
local s2s_verify_dialback = require "core.s2smanager".verify_dialback;
local s2s_destroy_session = require "core.s2smanager".destroy_session;

local st = require "util.stanza";

local log = require "util.logger".init("mod_dialback");

local xmlns_dialback = "jabber:server:dialback";

local dialback_requests = setmetatable({}, { __mode = 'v' });

module:add_handler({"s2sin_unauthed", "s2sin"}, "verify", xmlns_dialback,
	function (origin, stanza)
		-- We are being asked to verify the key, to ensure it was generated by us
		log("debug", "verifying dialback key...");
		local attr = stanza.attr;
		-- FIXME: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
		--if attr.from ~= origin.to_host then error("invalid-from"); end
		local type;
		if s2s_verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
			type = "valid"
		else
			type = "invalid"
			log("warn", "Asked to verify a dialback key that was incorrect. An imposter is claiming to be %s?", attr.to);
		end
		log("debug", "verified dialback key... it is %s", type);
		origin.sends2s(st.stanza("db:verify", { from = attr.to, to = attr.from, id = attr.id, type = type }):text(stanza[1]));
	end);

module:add_handler({ "s2sin_unauthed", "s2sin" }, "result", xmlns_dialback,
	function (origin, stanza)
		-- he wants to be identified through dialback
		-- We need to check the key with the Authoritative server
		local attr = stanza.attr;
		origin.hosts[attr.from] = { dialback_key = stanza[1] };
		
		if not hosts[attr.to] then
			-- Not a host that we serve
			log("info", "%s tried to connect to %s, which we don't serve", attr.from, attr.to);
			origin:close("host-unknown");
			return;
		end
		
		dialback_requests[attr.from] = origin;
		
		if not origin.from_host then
			-- Just used for friendlier logging
			origin.from_host = attr.from;
		end
		if not origin.to_host then
			-- Just used for friendlier logging
			origin.to_host = attr.to;
		end
		
		log("debug", "asking %s if key %s belongs to them", attr.from, stanza[1]);
		send_s2s(attr.to, attr.from,
			st.stanza("db:verify", { from = attr.to, to = attr.from, id = origin.streamid }):text(stanza[1]));
	end);

module:add_handler({ "s2sout_unauthed", "s2sout" }, "verify", xmlns_dialback,
	function (origin, stanza)
		local attr = stanza.attr;
		local dialback_verifying = dialback_requests[attr.from];
		if dialback_verifying then
			local valid;
			if attr.type == "valid" then
				s2s_make_authenticated(dialback_verifying, attr.from);
				valid = "valid";
			else
				-- Warn the original connection that is was not verified successfully
				log("warn", "authoritative server for "..(attr.from or "(unknown)").." denied the key");
				valid = "invalid";
			end
			if not dialback_verifying.sends2s then
				log("warn", "Incoming s2s session %s was closed in the meantime, so we can't notify it of the db result", tostring(dialback_verifying):match("%w+$"));
			else
				dialback_verifying.sends2s(
						st.stanza("db:result", { from = attr.to, to = attr.from, id = attr.id, type = valid })
								:text(dialback_verifying.hosts[attr.from].dialback_key));
			end
			dialback_requests[attr.from] = nil;
		end
	end);

module:add_handler({ "s2sout_unauthed", "s2sout" }, "result", xmlns_dialback,
	function (origin, stanza)
		-- Remote server is telling us whether we passed dialback
		
		local attr = stanza.attr;
		if not hosts[attr.to] then
			origin:close("host-unknown");
			return;
		elseif hosts[attr.to].s2sout[attr.from] ~= origin then
			-- This isn't right
			origin:close("invalid-id");
			return;
		end
		if stanza.attr.type == "valid" then
			s2s_make_authenticated(origin, attr.from);
		else
			s2s_destroy_session(origin)
		end
	end);
