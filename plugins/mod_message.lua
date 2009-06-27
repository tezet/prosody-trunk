
local full_sessions = full_sessions;
local bare_sessions = bare_sessions;

local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;
local user_exists = require "core.usermanager".user_exists;
local offlinemanager = require "core.offlinemanager";
local t_insert = table.insert;

local function process_to_bare(bare, origin, stanza)
	local user = bare_sessions[bare];
	
	local t = stanza.attr.type;
	if t == "error" then
		-- discard
	elseif t == "groupchat" then
		origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	elseif t == "headline" then
		if user then
			for _, session in pairs(user.sessions) do
				if session.presence and session.priority >= 0 then
					session.send(stanza);
				end
			end
		end  -- current policy is to discard headlines if no recipient is available
	else -- chat or normal message
		if user then -- some resources are connected
			local recipients = user.top_resources;
			if recipients then
				for i=1,#recipients do
					recipients[i].send(stanza);
				end
				return true;
			end
		end
		-- no resources are online
		local node, host = jid_split(bare);
		if user_exists(node, host) then
			-- TODO apply the default privacy list
			offlinemanager.store(node, host, stanza);
		else
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	end
	return true;
end

module:hook("message/full", function(data)
	-- message to full JID recieved
	local origin, stanza = data.origin, data.stanza;
	
	local session = full_sessions[stanza.attr.to];
	if session then
		-- TODO fire post processing event
		session.send(stanza);
		return true;
	else -- resource not online
		return process_to_bare(jid_bare(stanza.attr.to), origin, stanza);
	end
end);

module:hook("message/bare", function(data)
	-- message to bare JID recieved
	local origin, stanza = data.origin, data.stanza;

	return process_to_bare(stanza.attr.to or (origin.username..'@'..origin.host), origin, stanza);
end);

module:add_feature("msgoffline");
