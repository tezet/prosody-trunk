
-- The code in this file should be self-explanatory, though the logic is horrible
-- for more info on that, see doc/stanza_routing.txt, which attempts to condense
-- the rules from the RFCs (mainly 3921)

require "core.servermanager"

local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local _send = require "core.sessionmanager".send_to_session;
local send_s2s = require "core.s2smanager".send_to_host;
function send(session, stanza)
	if session.type == "c2s" then
		_send(session, stanza);
	else
		local xmlns = stanza.attr.xmlns;
		--stanza.attr.xmlns = "jabber:server";
		stanza.attr.xmlns = nil;
		log("debug", "sending s2s stanza: %s", tostring(stanza));
		send_s2s(session.host, host, stanza); -- TODO handle remote routing errors
		stanza.attr.xmlns = xmlns; -- reset
	end
end
local user_exists = require "core.usermanager".user_exists;

local rostermanager = require "core.rostermanager";
local sessionmanager = require "core.sessionmanager";

local s2s_verify_dialback = require "core.s2smanager".verify_dialback;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;
local format = string.format;
local tostring = tostring;

local jid_split = require "util.jid".split;
local print = print;

function core_process_stanza(origin, stanza)
	log("debug", "Received: "..tostring(stanza))
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		if stanza.attr.type == "set" or stanza.attr.type == "get" then
			error("Invalid IQ");
		elseif #stanza.tags > 1 and not(stanza.attr.type == "error" or stanza.attr.type == "result") then
			error("Invalid IQ");
		end
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	local to = stanza.attr.to;
	-- TODO also, stazas should be returned to their original state before the function ends
	if origin.type == "c2s" then
		stanza.attr.from = origin.full_jid; -- quick fix to prevent impersonation (FIXME this would be incorrect when the origin is not c2s)
	end
	
	if not to then
		core_handle_stanza(origin, stanza);
	elseif hosts[to] and hosts[to].type == "local" then
		core_handle_stanza(origin, stanza);
	elseif stanza.name == "iq" and not select(3, jid_split(to)) then
		core_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" or origin.type == "s2sin" then
		core_route_stanza(origin, stanza);
	end
end

-- This function handles stanzas which are not routed any further,
-- that is, they are handled by this server
function core_handle_stanza(origin, stanza)
	-- Handlers
	if origin.type == "c2s" or origin.type == "c2s_unauthed" then
		local session = origin;
		
		if stanza.name == "presence" and origin.roster then
			if stanza.attr.type == nil or stanza.attr.type == "unavailable" then
				for jid in pairs(origin.roster) do -- broadcast to all interested contacts
					local subscription = origin.roster[jid].subscription;
					if subscription == "both" or subscription == "from" then
						stanza.attr.to = jid;
						core_route_stanza(origin, stanza);
					end
				end
				local node, host = jid_split(stanza.attr.from);
				for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast to all resources
					if res ~= origin and res.full_jid then -- to resource. FIXME is res.full_jid the correct check? Maybe it should be res.presence
						stanza.attr.to = res.full_jid;
						core_route_stanza(origin, stanza);
					end
				end
				if not origin.presence then -- presence probes on initial presence -- FIXME does unavailable qualify as initial presence?
					local probe = st.presence({from = origin.full_jid, type = "probe"});
					for jid in pairs(origin.roster) do -- probe all contacts we are subscribed to
						local subscription = origin.roster[jid].subscription;
						if subscription == "both" or subscription == "to" then
							probe.attr.to = jid;
							core_route_stanza(origin, probe);
						end
					end
					for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast from all resources
						if res ~= origin and stanza.attr.type ~= "unavailable" and res.presence then -- FIXME does unavailable qualify as initial presence?
							res.presence.attr.to = origin.full_jid;
							core_route_stanza(res, res.presence);
							res.presence.attr.to = nil;
						end
					end
					-- TODO resend subscription requests
				end
				origin.presence = stanza;
				stanza.attr.to = nil; -- reset it
			else
				-- TODO error, bad type
			end
		else
			log("debug", "Routing stanza to local");
			handle_stanza(session, stanza);
		end
	elseif origin.type == "s2sin_unauthed" or origin.type == "s2sin" then
		if stanza.attr.xmlns == "jabber:server:dialback" then
			if stanza.name == "verify" then
				-- We are being asked to verify the key, to ensure it was generated by us
				log("debug", "verifying dialback key...");
				local attr = stanza.attr;
				print(tostring(attr.to), tostring(attr.from))
				print(tostring(origin.to_host), tostring(origin.from_host))
				-- FIXME: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
				--if attr.from ~= origin.to_host then error("invalid-from"); end
				local type = "invalid";
				if s2s_verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
					type = "valid"
				end
				origin.send(format("<db:verify from='%s' to='%s' id='%s' type='%s'>%s</db:verify>", attr.to, attr.from, attr.id, type, stanza[1]));
			elseif stanza.name == "result" and origin.type == "s2sin_unauthed" then
				-- he wants to be identified through dialback
				-- We need to check the key with the Authoritative server
				local attr = stanza.attr;
				origin.from_host = attr.from;
				origin.to_host = attr.to;
				origin.dialback_key = stanza[1];
				log("debug", "asking %s if key %s belongs to them", attr.from, stanza[1]);
				send_s2s(attr.to, attr.from, format("<db:verify from='%s' to='%s' id='%s'>%s</db:verify>", attr.to, attr.from, origin.streamid, stanza[1]));
				hosts[attr.from].dialback_verifying = origin;
			end
		end
	elseif origin.type == "s2sout_unauthed" or origin.type == "s2sout" then
		if stanza.attr.xmlns == "jabber:server:dialback" then
			if stanza.name == "result" then
				if stanza.attr.type == "valid" then
					s2s_make_authenticated(origin);
				else
					-- FIXME
					error("dialback failed!");
				end
			elseif stanza.name == "verify" and origin.dialback_verifying then
				local valid;
				local attr = stanza.attr;
				if attr.type == "valid" then
					s2s_make_authenticated(origin.dialback_verifying);
					valid = "valid";
				else
					-- Warn the original connection that is was not verified successfully
					log("warn", "dialback for "..(origin.dialback_verifying.from_host or "(unknown)").." failed");
					valid = "invalid";
				end
				origin.dialback_verifying.send(format("<db:result from='%s' to='%s' id='%s' type='%s'>%s</db:result>", attr.from, attr.to, attr.id, valid, origin.dialback_verifying.dialback_key));
			end
		end
	else
		log("warn", "Unhandled origin: %s", origin.type);
	end
end

function send_presence_of_available_resources(user, host, jid, recipient_session)
	local h = hosts[host];
	local count = 0;
	if h and h.type == "local" then
		local u = h.sessions[user];
		if u then
			for k, session in pairs(u.sessions) do
				local pres = session.presence;
				if pres then
					pres.attr.to = jid;
					pres.attr.from = session.full_jid;
					send(recipient_session, pres);
					pres.attr.to = nil;
					pres.attr.from = nil;
					count = count + 1;
				end
			end
		end
	end
	return count;
end

function handle_outbound_presence_subscriptions(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(to_bare);
	if stanza.attr.type == "subscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none, ask = subscribe)
		if rostermanager.set_contact_pending_out(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end -- else file error
		core_route_stanza(origin, st.presence({from=from_bare, to=to_bare, type="subscribe"}));
	elseif stanza.attr.type == "unsubscribe" then
		-- 1. route stanza
		-- 2. roster push (subscription = none or from)
		if rostermanager.unsubscribe(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare); -- FIXME do roster push when roster has in fact not changed?
		end -- else file error
		core_route_stanza(origin, st.presence({from=from_bare, to=to_bare, type="unsubscribe"}));
	elseif stanza.attr.type == "subscribed" then
		-- 1. route stanza
		-- 2. roster_push ()
		-- 3. send_presence_of_available_resources
		if rostermanager.subscribed(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
			core_route_stanza(origin, st.presence({from=from_bare, to=to_bare, type="subscribed"}));
			send_presence_of_available_resources(user, host, from_bare, origin);
		end
	elseif stanza.attr.type == "unsubscribed" then
		-- 1. route stanza
		-- 2. roster push (subscription = none or to)
		if rostermanager.unsubscribed(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
			core_route_stanza(origin, st.presence({from=from_bare, to=to_bare, type="unsubscribed"}));
		end
	end
end

function handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare)
	local node, host = jid_split(to_bare);
	if stanza.attr.type == "probe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			if 0 == send_presence_of_available_resources(node, host, from_bare, origin) then
				-- TODO send last recieved unavailable presence (or we MAY do nothing, which is fine too)
			end
		else
			send(origin, st.presence({from=to_bare, to=from_bare, type="unsubscribed"}));
		end
	elseif stanza.attr.type == "subscribe" then
		if rostermanager.is_contact_subscribed(node, host, from_bare) then
			send(origin, st.presence({from=to_bare, to=from_bare, type="subscribed"})); -- already subscribed
		else
			if not rostermanager.is_contact_pending(node, host, from_bare) then
				if rostermanager.set_contact_pending(node, host, from_bare) then
					sessionmanager.send_to_available_resources(node, host, st.presence({from=from_bare, type="subscribe"}));
				end -- TODO else return error, unable to save
			end
		end
	elseif stanza.attr.type == "unsubscribe" then
		if rostermanager.process_inbound_unsubscribe(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	elseif stanza.attr.type == "subscribed" then
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
			send_presence_of_available_resources(node, host, from_bare, origin);
		end
	elseif stanza.attr.type == "unsubscribed" then
		if rostermanager.process_inbound_subscription_approval(node, host, from_bare) then
			rostermanager.roster_push(node, host, from_bare);
		end
	end -- discard any other type
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later
	
	-- Deliver
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID
	local from = stanza.attr.from;
	local from_node, from_host, from_resource = jid_split(from);
	local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID

	if stanza.name == "presence" and (stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable") then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare);
					else -- sender is available or unavailable
						for k in pairs(user.sessions) do -- presence broadcast to all user resources. FIXME should this be just for available resources? Do we need to check subscription?
							if user.sessions[k].full_jid then
								stanza.attr.to = user.sessions[k].full_jid; -- reset at the end of function
								send(user.sessions[k], stanza);
							end
						end
					end
				elseif stanza.name == "message" then -- select a resource to recieve message
					for k in pairs(user.sessions) do
						if user.sessions[k].full_jid then
							res = user.sessions[k];
							break;
						end
					end
					-- TODO find resource with greatest priority
					send(res, stanza);
				else
					-- TODO send IQ error
				end
			else
				-- User + resource is online...
				stanza.attr.to = res.full_jid; -- reset at the end of function
				send(res, stanza); -- Yay \o/
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type ~= nil and stanza.attr.type ~= "unavailable" then
						handle_inbound_presence_subscriptions_and_probes(origin, stanza, from_bare, to_bare);
					else
						-- TODO send unavailable presence or unsubscribed
					end
				elseif stanza.name == "message" then
					-- TODO send message error, or store offline messages
				elseif stanza.name == "iq" then
					-- TODO send IQ error
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						send(origin, st.presence({from = to_bare, to = from_bare, type = "unsubscribed"}));
					end
					-- else ignore
				else
					send(origin, st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		end
	elseif origin.type == "c2s" then
		-- Remote host
		local xmlns = stanza.attr.xmlns;
		--stanza.attr.xmlns = "jabber:server";
		stanza.attr.xmlns = nil;
		log("debug", "sending s2s stanza: %s", tostring(stanza));
		send_s2s(origin.host, host, stanza); -- TODO handle remote routing errors
		stanza.attr.xmlns = xmlns; -- reset
	else
		log("warn", "received stanza from unhandled connection type: %s", origin.type);
	end
	stanza.attr.to = to; -- reset
end

function handle_stanza_toremote(stanza)
	log("error", "Stanza bound for remote host, but s2s is not implemented");
end
