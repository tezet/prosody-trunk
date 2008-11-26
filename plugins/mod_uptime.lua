
local st = require "util.stanza"

local jid_split = require "util.jid".split;
local t_concat = table.concat;

local start_time = os.time();

require "core.discomanager".set("uptime", "jabber:iq:last");

add_iq_handler({"c2s", "s2sin"}, "jabber:iq:last", 
	function (origin, stanza)
		if stanza.tags[1].name == "query" then
			if stanza.attr.type == "get" then
				local node, host, resource = jid_split(stanza.attr.to);
				if node or resource then
					-- TODO
				else
					origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = tostring(os.difftime(os.time(), start_time))}));
					return true;
				end
			end
		end
	end);
