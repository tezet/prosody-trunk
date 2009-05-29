-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local sm_make_authenticated = require "core.sessionmanager".make_authenticated;
local base64 = require "util.encodings".base64;

local datamanager_load = require "util.datamanager".load;
local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;
local jid_split = require "util.jid".split
local md5 = require "util.hashes".md5;
local config = require "core.configmanager";

local secure_auth_only = config.get(module:get_host(), "core", "require_encryption");

local log = module._log;

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local new_sasl = require "util.sasl".new;

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "challenge" then
		log("debug", "%s", ret or "");
		reply:text(base64.encode(ret or ""));
	elseif status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"):text(err_msg); end
	elseif status == "success" then
		log("debug", "%s", ret or "");
		reply:text(base64.encode(ret or ""));
	else
		module:log("error", "Unknown sasl status: %s", status);
	end
	return reply;
end

local function handle_status(session, status)
	if status == "failure" then
		session.sasl_handler = nil;
	elseif status == "success" then
		if not session.sasl_handler.username then -- TODO move this to sessionmanager
			module:log("warn", "SASL succeeded but we didn't get a username!");
			session.sasl_handler = nil;
			session:reset_stream();
			return;
		end 
		sm_make_authenticated(session, session.sasl_handler.username);
		session.sasl_handler = nil;
		session:reset_stream();
	end
end

local function password_callback(node, host, mechanism, decoder)
	local password = (datamanager_load(node, host, "accounts") or {}).password; -- FIXME handle hashed passwords
	local func = function(x) return x; end;
	if password then
		if mechanism == "PLAIN" then
			return func, password;
		elseif mechanism == "DIGEST-MD5" then
			if decoder then node, host, password = decoder(node), decoder(host), decoder(password); end
			return func, md5(node..":"..host..":"..password);
		end
	end
	return func, nil;
end

local function sasl_handler(session, stanza)
	if stanza.name == "auth" then
		-- FIXME ignoring duplicates because ejabberd does
		if config.get(session.host or "*", "core", "anonymous_login") then
			if stanza.attr.mechanism ~= "ANONYMOUS" then
				return session.send(build_reply("failure", "invalid-mechanism"));
			end
		elseif stanza.attr.mechanism == "ANONYMOUS" then
			return session.send(build_reply("failure", "mechanism-too-weak"));
		end
		session.sasl_handler = new_sasl(stanza.attr.mechanism, session.host, password_callback);
		if not session.sasl_handler then
			return session.send(build_reply("failure", "invalid-mechanism"));
		end
	elseif not session.sasl_handler then
		return; -- FIXME ignoring out of order stanzas because ejabberd does
	end
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		log("debug", "%s", text);
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return;
		end
	end
	local status, ret, err_msg = session.sasl_handler:feed(text);
	handle_status(session, status);
	local s = build_reply(status, ret, err_msg); 
	log("debug", "sasl reply: %s", tostring(s));
	session.send(s);
end

module:add_handler("c2s_unauthed", "auth", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "abort", xmlns_sasl, sasl_handler);
module:add_handler("c2s_unauthed", "response", xmlns_sasl, sasl_handler);

local mechanisms_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-sasl' };
local bind_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-bind' };
local xmpp_session_attr = { xmlns='urn:ietf:params:xml:ns:xmpp-session' };
module:add_event_hook("stream-features", 
		function (session, features)												
			if not session.username then
				if secure_auth_only and not session.secure then
					return;
				end
				features:tag("mechanisms", mechanisms_attr);
				-- TODO: Provide PLAIN only if TLS is active, this is a SHOULD from the introduction of RFC 4616. This behavior could be overridden via configuration but will issuing a warning or so.
					if config.get(session.host or "*", "core", "anonymous_login") then
						features:tag("mechanism"):text("ANONYMOUS"):up();
					else
						features:tag("mechanism"):text("DIGEST-MD5"):up();
						features:tag("mechanism"):text("PLAIN"):up();
					end
				features:up();
			else
				features:tag("bind", bind_attr):tag("required"):up():up();
				features:tag("session", xmpp_session_attr):up();
			end
		end);
					
module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-bind", 
		function (session, stanza)
			log("debug", "Client requesting a resource bind");
			local resource;
			if stanza.attr.type == "set" then
				local bind = stanza.tags[1];
				if bind and bind.attr.xmlns == xmlns_bind then
					resource = bind:child_with_name("resource");
					if resource then
						resource = resource[1];
					end
				end
			end
			local success, err_type, err, err_msg = sm_bind_resource(session, resource);
			if not success then
				session.send(st.error_reply(stanza, err_type, err, err_msg));
			else
				session.send(st.reply(stanza)
					:tag("bind", { xmlns = xmlns_bind})
					:tag("jid"):text(session.full_jid));
			end
		end);
		
module:add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-session", 
		function (session, stanza)
			log("debug", "Client requesting a session");
			session.send(st.reply(stanza));
		end);
