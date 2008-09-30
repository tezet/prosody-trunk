local t_insert      =  table.insert;
local t_remove      =  table.remove;
local s_format      = string.format;
local tostring      =      tostring;
local setmetatable  =  setmetatable;
local pairs         =         pairs;
local ipairs        =        ipairs;
local type          =          type;
local s_gsub        =   string.gsub;
module "stanza"

stanza_mt = {};
stanza_mt.__index = stanza_mt;

function stanza(name, attr)
	local stanza = { name = name, attr = attr or {}, tags = {}, last_add = {}};
	return setmetatable(stanza, stanza_mt);
end

function stanza_mt:iq(attrs)
	return self + stanza("iq", attrs)
end
function stanza_mt:message(attrs)
	return self + stanza("message", attrs)
end
function stanza_mt:presence(attrs)
	return self + stanza("presence", attrs)
end
function stanza_mt:query(xmlns)
	return self:tag("query", { xmlns = xmlns });
end
function stanza_mt:tag(name, attrs)
	local s = stanza(name, attrs);
	(self.last_add[#self.last_add] or self):add_child(s);
	t_insert(self.last_add, s);
	return self;
end

function stanza_mt:text(text)
	(self.last_add[#self.last_add] or self):add_child(text);
	return self; 
end

function stanza_mt:up()
	t_remove(self.last_add);
	return self;
end

function stanza_mt:add_child(child)
	if type(child) == "table" then
		t_insert(self.tags, child);
	end
	t_insert(self, child);
end

function stanza_mt:child_with_name(name)
	for _, child in ipairs(self) do	
		if child.name == name then return child; end
	end
end

function stanza_mt:children()
	local i = 0;
	return function (a)
			i = i + 1
			local v = a[i]
			if v then return v; end
		end, self, i;
	                                    
end
function stanza_mt:childtags()
	local i = 0;
	return function (a)
			i = i + 1
			local v = self.tags[i]
			if v then return v; end
		end, self.tags[1], i;
	                                    
end

do
	local xml_entities = { ["'"] = "&apos;", ["\""] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" };
	function xml_escape(s) return s_gsub(s, "['&<>\"]", xml_entities); end
end

local xml_escape = xml_escape;

function stanza_mt.__tostring(t)
	local children_text = "";
	for n, child in ipairs(t) do
		if type(child) == "string" then	
			children_text = children_text .. xml_escape(child);
		else
			children_text = children_text .. tostring(child);
		end
	end

	local attr_string = "";
	if t.attr then
		for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(" %s='%s'", k, tostring(v)); end end
	end

	return s_format("<%s%s>%s</%s>", t.name, attr_string, children_text, t.name);
end

function stanza_mt.__add(s1, s2)
	return s1:add_child(s2);
end


do
        local id = 0;
        function new_id()
                id = id + 1;
                return "lx"..id;
        end
end

function message(attr, body)
	if not body then
		return stanza("message", attr);
	else
		return stanza("message", attr):tag("body"):text(body);
	end
end
function iq(attr)
	if attr and not attr.id then attr.id = new_id(); end
	return stanza("iq", attr or { id = new_id() });
end

function reply(orig)
	return stanza(orig.name, orig.attr and { to = orig.attr.from, from = orig.attr.to, id = orig.attr.id, type = ((orig.name == "iq" and "result") or nil) });
end

function presence(attr)
	return stanza("presence", attr);
end

return _M;