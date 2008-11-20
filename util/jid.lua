
local match = string.match;

module "jid"

function split(jid)
	if not jid then return; end
	-- TODO verify JID, and return; if invalid
	local node = match(jid, "^([^@]+)@");
	local server = (node and match(jid, ".-@([^@/]+)")) or match(jid, "^([^@/]+)");
	local resource = match(jid, "/(.+)$");
	return node, server, resource;
end

function bare(jid)
	local node, host = split(jid);
	return node.."@"..host;
end

return _M;