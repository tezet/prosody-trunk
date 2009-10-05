-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local xmlns_stream = 'http://etherx.jabber.org/streams';
local xmlns_starttls = 'urn:ietf:params:xml:ns:xmpp-tls';

local secure_auth_only = module:get_option("c2s_require_encryption") or module:get_option("require_encryption");
local secure_s2s_only = module:get_option("s2s_require_encryption");

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
		
module:add_handler("s2sin_unauthed", "starttls", xmlns_starttls,
		function (session, stanza)
			if session.conn.starttls then
				session.sends2s(st.stanza("proceed", { xmlns = xmlns_starttls }));
				session:reset_stream();
				session.conn.starttls();
				session.log("info", "TLS negotiation started for incoming s2s...");
				session.secure = false;
			else
				-- FIXME: What reply?
				session.log("warn", "Attempt to start TLS, but TLS is not available on this s2s connection");
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

module:add_event_hook("s2s-stream-features", 
		function (session, features)
			-- This hook is possibly called once per host (at least if the
			-- remote server does not specify a to/from.
			if session.to_host and session.conn.starttls and not features:child_with_ns(xmlns_starttls) then
				features:tag("starttls", starttls_attr):up();
				if secure_s2s_only then
					features:tag("required"):up():up();
				else
					features:up();
				end
			end
		end);

-- For s2sout connections, start TLS if we can
module:hook_stanza(xmlns_stream, "features",
		function (session, stanza)
			module:log("debug", "Received features element");
			if stanza:child_with_ns(xmlns_starttls) then
				module:log("%s is offering TLS, taking up the offer...", session.to_host);
				session.sends2s("<starttls xmlns='"..xmlns_starttls.."'/>");
				return true;
			end
		end, 500);

module:hook_stanza(xmlns_starttls, "proceed",
		function (session, stanza)
			module:log("debug", "Proceeding with TLS on s2sout...");
			local format, to_host, from_host = string.format, session.to_host, session.from_host;
			session:reset_stream();
			session.conn.starttls(true);
			return true;
		end);
