local jid_bare = require "util.jid".bare;
local jid_resource = require "util.jid".resource;
local resourceprep = require "util.encodings".stringprep.resourceprep;
local st = require "util.stanza";
local dataforms = require "util.dataforms";

local allow_unaffiliated = module:get_option_boolean("allow_unaffiliated_register", false);

local enforce_nick = module:get_option_boolean("enforce_registered_nickname", false);

-- reserved_nicks[nick] = jid
local function get_reserved_nicks(room)
	if room._reserved_nicks then
		return room._reserved_nicks;
	end
	module:log("debug", "Refreshing reserved nicks...");
	local reserved_nicks = {};
	for jid in room:each_affiliation() do
		local data = room._affiliation_data[jid];
		local nick = data and data.reserved_nickname;
		module:log("debug", "Refreshed for %s: %s", jid, nick);
		if nick then
			reserved_nicks[nick] = jid;
		end
	end
	room._reserved_nicks = reserved_nicks;
	return reserved_nicks;
end

-- Returns the registered nick, if any, for a JID
-- Note: this is just the *nick* part, i.e. the resource of the in-room JID
local function get_registered_nick(room, jid)
	local registered_data = room._affiliation_data[jid];
	if not registered_data then
		return;
	end
	return registered_data.reserved_nickname;
end

-- Returns the JID, if any, that registered a nick (not in-room JID)
local function get_registered_jid(room, nick)
	local reserved_nicks = get_reserved_nicks(room);
	return reserved_nicks[nick];
end

module:hook("muc-set-affiliation", function (event)
	-- Clear reserved nick cache
	event.room._reserved_nicks = nil;
end);

module:add_feature("jabber:iq:register");

module:hook("muc-disco#info", function (event)
	event.reply:tag("feature", { var = "jabber:iq:register" }):up();
end);

local registration_form = dataforms.new {
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/muc#register" },
	{ name = "muc#register_roomnick", type = "text-single", label = "Nickname"},
};

local function enforce_nick_policy(event)
	local origin, stanza = event.origin, event.stanza;
	local room = assert(event.room); -- FIXME
	if not room then return; end

	-- Check if the chosen nickname is reserved
	local requested_nick = jid_resource(stanza.attr.to);
	local reserved_by = get_registered_jid(room, requested_nick);
	if reserved_by and reserved_by ~= jid_bare(stanza.attr.from) then
		module:log("debug", "%s attempted to use nick %s reserved by %s", stanza.attr.from, requested_nick, reserved_by);
		local reply = st.error_reply(stanza, "cancel", "conflict"):up();
		origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
		return true;
	end

	-- Check if the occupant has a reservation they must use
	if enforce_nick then
		local nick = get_registered_nick(room, jid_bare(stanza.attr.from));
		if nick then
			if event.occupant then
				event.occupant.nick = jid_bare(event.occupant.nick) .. "/" .. nick;
			elseif event.dest_occupant.nick ~= jid_bare(event.dest_occupant.nick) .. "/" .. nick then
				module:log("debug", "Attempt by %s to join as %s, but their reserved nick is %s", stanza.attr.from, requested_nick, nick);
				local reply = st.error_reply(stanza, "cancel", "not-acceptable"):up();
				origin.send(reply:tag("x", {xmlns = "http://jabber.org/protocol/muc"}));
				return true;
			end
		end
	end
end

module:hook("muc-occupant-pre-join", enforce_nick_policy);
module:hook("muc-occupant-pre-change", enforce_nick_policy);

-- Discovering Reserved Room Nickname
-- http://xmpp.org/extensions/xep-0045.html#reservednick
module:hook("muc-disco#info/x-roomuser-item", function (event)
	local nick = get_registered_nick(event.room, jid_bare(event.stanza.attr.from));
	if nick then
		event.reply:tag("identity", { category = "conference", type = "text", name = nick })
	end
end);

local function handle_register_iq(room, origin, stanza)
	local user_jid = jid_bare(stanza.attr.from)
	local affiliation = room:get_affiliation(user_jid);
	if affiliation == "outcast" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	elseif not (affiliation or allow_unaffiliated) then
		origin.send(st.error_reply(stanza, "auth", "registration-required"));
		return true;
	end
	local reply = st.reply(stanza);
	local registered_nick = get_registered_nick(room, user_jid);
	if stanza.attr.type == "get" then
		reply:query("jabber:iq:register");
		if registered_nick then
			reply:tag("registered"):up();
			reply:tag("username"):text(registered_nick);
			origin.send(reply);
			return true;
		end
		reply:add_child(registration_form:form());
	else -- type == set -- handle registration form
		local query = stanza.tags[1];
		if query:get_child("remove") then
			-- Remove "member" affiliation, but preserve if any other
			local new_affiliation = affiliation ~= "member" and affiliation;
			local ok, err_type, err_condition = room:set_affiliation(true, user_jid, new_affiliation, nil, false);
			if not ok then
				origin.send(st.error_reply(stanza, err_type, err_condition));
				return true;
			end
			origin.send(reply);
			return true;
		end
		local form_tag = query:get_child("x", "jabber:x:data");
		local reg_data = form_tag and registration_form:data(form_tag);
		if not reg_data then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Error in form"));
			return true;
		end
		-- Is the nickname valid?
		local desired_nick = resourceprep(reg_data["muc#register_roomnick"]);
		if not desired_nick then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid Nickname"));
			return true;
		end
		-- Is the nickname currently in use by another user?
		local current_occupant = room:get_occupant_by_nick(room.jid.."/"..desired_nick);
		if current_occupant and current_occupant.bare_jid ~= user_jid then
			origin.send(st.error_reply(stanza, "cancel", "conflict"));
			return true;
		end
		-- Is the nickname currently reserved by another user?
		local reserved_by = get_registered_jid(room, desired_nick);
		if reserved_by and reserved_by ~= user_jid then
			origin.send(st.error_reply(stanza, "cancel", "conflict"));
			return true;
		end

		-- Kick any sessions that are not using this nick before we register it
		if enforce_nick then
			local required_room_nick = room.jid.."/"..desired_nick;
			for room_nick, occupant in room:each_occupant() do
				if occupant.bare_jid == user_jid and room_nick ~= required_room_nick then
					room:set_role(true, room_nick, nil); -- Kick (TODO: would be nice to use 333 code)
				end
			end
		end

		-- Checks passed, save the registration
		if registered_nick ~= desired_nick then
			local registration_data = { reserved_nickname = desired_nick };
			local ok, err_type, err_condition = room:set_affiliation(true, user_jid, "member", nil, registration_data);
			if not ok then
				origin.send(st.error_reply(stanza, err_type, err_condition));
				return true;
			end
			module:log("debug", "Saved nick registration for %s: %s", user_jid, desired_nick);
			origin.send(reply);
			return true;
		end
	end
	origin.send(reply);
	return true;
end

return {
	get_registered_nick = get_registered_nick;
	get_registered_jid = get_registered_jid;
	handle_register_iq = handle_register_iq;
}
