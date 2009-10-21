-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local hosts = hosts;
local user_exists = require "core.usermanager".user_exists;
local is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;
local pairs, ipairs = pairs, ipairs;
local next = next;
local type = type;
local load_roster = require "core.rostermanager".load_roster;
local sha1 = require "util.hashes".sha1;
local base64 = require "util.encodings".base64.encode;

local NULL = {};
local data = {};
local recipients = {};
local hash_map = {};

module:add_identity("pubsub", "pep", "Prosody");
module:add_feature("http://jabber.org/protocol/pubsub#publish");

local function publish(session, node, item)
	item.attr.xmlns = nil;
	local disable = #item.tags ~= 1 or #item.tags[1].tags == 0;
	if #item.tags == 0 then item.name = "retract"; end
	local bare = session.username..'@'..session.host;
	local stanza = st.message({from=bare, type='headline'})
		:tag('event', {xmlns='http://jabber.org/protocol/pubsub#event'})
			:tag('items', {node=node})
				:add_child(item)
			:up()
		:up();

	-- store for the future
	local user_data = data[bare];
	if disable then
		if user_data then
			user_data[node] = nil;
			if not next(user_data) then data[bare] = nil; end
		end
	else
		if not user_data then user_data = {}; data[bare] = user_data; end
		user_data[node] = stanza;
	end
	
	-- broadcast
	for recipient, notify in pairs(recipients[bare] or NULL) do
		if notify[node] then
			stanza.attr.to = recipient;
			core_post_stanza(session, stanza);
		end
	end
end
local function publish_all(user, recipient, session)
	local d = data[user];
	local notify = recipients[user] and recipients[user][recipient];
	if d and notify then
		for node in pairs(notify) do
			local message = d[node];
			if message then
				message.attr.to = recipient;
				session.send(message);
			end
		end
	end
end

local function get_caps_hash_from_presence(stanza, current)
	local t = stanza.attr.type;
	if not t then
		for _, child in pairs(stanza.tags) do
			if child.name == "c" and child.attr.xmlns == "http://jabber.org/protocol/caps" then
				local attr = child.attr;
				if attr.hash then -- new caps
					if attr.hash == 'sha-1' and attr.node and attr.ver then return attr.ver, attr.node.."#"..attr.ver; end
				else -- legacy caps
					if attr.node and attr.ver then return attr.node.."#"..attr.ver.."#"..(attr.ext or ""), attr.node.."#"..attr.ver; end
				end
				return; -- bad caps format
			end
		end
	elseif t == "unavailable" or t == "error" then
		return;
	end
	return current; -- no caps, could mean caps optimization, so return current
end

module:hook("presence/bare", function(event)
	-- inbound presence to bare JID recieved
	local origin, stanza = event.origin, event.stanza;
	
	local user = stanza.attr.to or (origin.username..'@'..origin.host);
	local bare = jid_bare(stanza.attr.from);
	local item = load_roster(jid_split(user))[bare];
	if not stanza.attr.to or (item and (item.subscription == 'from' or item.subscription == 'both')) then
		local recipient = stanza.attr.from;
		local current = recipients[user] and recipients[user][recipient];
		local hash = get_caps_hash_from_presence(stanza, current);
		if current == hash then return; end
		if not hash then
			if recipients[user] then recipients[user][recipient] = nil; end
		else
			recipients[user] = recipients[user] or {};
			if hash_map[hash] then
				recipients[user][recipient] = hash_map[hash];
				publish_all(user, recipient, origin);
			else
				recipients[user][recipient] = hash;
				origin.send(
					st.stanza("iq", {from=stanza.attr.to, to=stanza.attr.from, id="disco", type="get"})
						:query("http://jabber.org/protocol/disco#info")
				);
			end
		end
	end
end, 10);

module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == 'set' and (not stanza.attr.to or jid_bare(stanza.attr.from) == stanza.attr.to) then
		local payload = stanza.tags[1];
		if payload.name == 'pubsub' then -- <pubsub xmlns='http://jabber.org/protocol/pubsub'>
			payload = payload.tags[1];
			if payload and (payload.name == 'publish' or payload.name == 'retract') and payload.attr.node then -- <publish node='http://jabber.org/protocol/tune'>
				local node = payload.attr.node;
				payload = payload.tags[1];
				if payload then -- <item>
					publish(session, node, payload);
					session.send(st.reply(stanza));
					return true;
				end
			end
		end
	end
end);

local function calculate_hash(disco_info)
	local identities, features, extensions = {}, {}, {};
	for _, tag in pairs(disco_info) do
		if tag.name == "identity" then
			table.insert(identities, (tag.attr.category or "").."\0"..(tag.attr.type or "").."\0"..(tag.attr["xml:lang"] or "").."\0"..(tag.attr.name or ""));
		elseif tag.name == "feature" then
			table.insert(features, tag.attr.var or "");
		elseif tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then
			local form = {};
			local FORM_TYPE;
			for _, field in pairs(tag.tags) do
				if field.name == "field" and field.attr.var then
					local values = {};
					for _, val in pairs(field.tags) do
						val = #val.tags == 0 and table.concat(val); -- FIXME use get_text?
						if val then table.insert(values, val); end
					end
					table.sort(values);
					if field.attr.var == "FORM_TYPE" then
						FORM_TYPE = values[1];
					elseif #values > 0 then
						table.insert(form, field.attr.var.."\0"..table.concat(values, "<"));
					else
						table.insert(form, field.attr.var);
					end
				end
			end
			table.sort(form);
			form = table.concat(form, "<");
			if FORM_TYPE then form = FORM_TYPE.."\0"..form; end
			table.insert(extensions, form);
		end
	end
	table.sort(identities);
	table.sort(features);
	table.sort(extensions);
	if #identities > 0 then identities = table.concat(identities, "<"):gsub("%z", "/").."<"; else identities = ""; end
	if #features > 0 then features = table.concat(features, "<").."<"; else features = ""; end
	if #extensions > 0 then extensions = table.concat(extensions, "<"):gsub("%z", "<").."<"; else extensions = ""; end
	local S = identities..features..extensions;
	local ver = base64(sha1(S));
	return ver, S;
end

module:hook("iq/bare/disco", function(event)
	local session, stanza = event.origin, event.stanza;
	if stanza.attr.type == "result" then
		local disco = stanza.tags[1];
		if disco and disco.name == "query" and disco.attr.xmlns == "http://jabber.org/protocol/disco#info" then
			-- Process disco response
			local user = stanza.attr.to or (session.username..'@'..session.host);
			local contact = stanza.attr.from;
			local current = recipients[user] and recipients[user][contact];
			if type(current) ~= "string" then return; end -- check if waiting for recipient's response
			local ver = current;
			if not string.find(current, "#") then
				ver = calculate_hash(disco.tags); -- calculate hash
			end
			local notify = {};
			for _, feature in pairs(disco.tags) do
				if feature.name == "feature" and feature.attr.var then
					local nfeature = feature.attr.var:match("^(.*)%+notify$");
					if nfeature then notify[nfeature] = true; end
				end
			end
			hash_map[ver] = notify; -- update hash map
			recipients[user][contact] = notify; -- set recipient's data to calculated data
			-- send messages to recipient
			publish_all(user, contact, session);
		end
	end
end);
