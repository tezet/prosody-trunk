-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";

local xmlns_starttls ='urn:ietf:params:xml:ns:xmpp-tls';

local config = require "core.configmanager";
local secure_auth_only = config.get("*", "core", "require_encryption");

module:add_handler("c2s_unauthed", "starttls", xmlns_starttls,
		function (session, stanza)
			if session.conn.starttls then
				session.send(st.stanza("proceed", { xmlns = xmlns_starttls }));
				session:reset_stream();
				session.conn.starttls();
				session.log("info", "TLS negotiation started...");
				session.secure = false;
			else
				-- FIXME: What reply?
				session.log("warn", "Attempt to start TLS, but TLS is not available on this connection");
			end
		end);
		
local starttls_attr = { xmlns = xmlns_starttls };
module:add_event_hook("stream-features", 
		function (session, features)												
			if session.conn.starttls then
				features:tag("starttls", starttls_attr);
				if secure_auth_only then
					features:tag("required"):up():up();
				else
					features:up();
				end
			end
		end);
