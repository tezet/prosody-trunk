-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local t_insert      =  table.insert;
local t_concat      =  table.concat;
local t_remove      =  table.remove;
local t_concat      =  table.concat;
local s_format      = string.format;
local s_match       =  string.match;
local tostring      =      tostring;
local setmetatable  =  setmetatable;
local getmetatable  =  getmetatable;
local pairs         =         pairs;
local ipairs        =        ipairs;
local type          =          type;
local next          =          next;
local print         =         print;
local unpack        =        unpack;
local s_gsub        =   string.gsub;
local s_char        =   string.char;
local s_find        =   string.find;
local os            =            os;

local do_pretty_printing = not os.getenv("WINDIR");
local getstyle, getstring;
if do_pretty_printing then
	local ok, termcolours = pcall(require, "util.termcolours");
	if ok then
		getstyle, getstring = termcolours.getstyle, termcolours.getstring;
	else
		do_pretty_printing = nil;
	end
end

local log = require "util.logger".init("stanza");

module "stanza"

stanza_mt = { __type = "stanza" };
stanza_mt.__index = stanza_mt;

function stanza(name, attr)
	local stanza = { name = name, attr = attr or {}, tags = {}, last_add = {}};
	return setmetatable(stanza, stanza_mt);
end

function stanza_mt:query(xmlns)
	return self:tag("query", { xmlns = xmlns });
end

function stanza_mt:body(text, attr)
	return self:tag("body", attr):text(text);
end

function stanza_mt:tag(name, attrs)
	local s = stanza(name, attrs);
	(self.last_add[#self.last_add] or self):add_direct_child(s);
	t_insert(self.last_add, s);
	return self;
end

function stanza_mt:text(text)
	(self.last_add[#self.last_add] or self):add_direct_child(text);
	return self; 
end

function stanza_mt:up()
	t_remove(self.last_add);
	return self;
end

function stanza_mt:reset()
	local last_add = self.last_add;
	for i = 1,#last_add do
		last_add[i] = nil;
	end
	return self;
end

function stanza_mt:add_direct_child(child)
	if type(child) == "table" then
		t_insert(self.tags, child);
	end
	t_insert(self, child);
end

function stanza_mt:add_child(child)
	(self.last_add[#self.last_add] or self):add_direct_child(child);
	return self;
end

function stanza_mt:child_with_name(name)
	for _, child in ipairs(self.tags) do	
		if child.name == name then return child; end
	end
end

function stanza_mt:child_with_ns(ns)
	for _, child in ipairs(self.tags) do	
		if child.attr.xmlns == ns then return child; end
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

local xml_escape
do
	local escape_table = { ["'"] = "&apos;", ["\""] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" };
	function xml_escape(str) return (s_gsub(str, "['&<>\"]", escape_table)); end
	_M.xml_escape = xml_escape;
end

local function _dostring(t, buf, self, xml_escape)
	local nsid = 0;
	local name = t.name
	t_insert(buf, "<"..name);
	for k, v in pairs(t.attr) do
		if s_find(k, "|", 1, true) then
			local ns, attrk = s_match(k, "^([^|]+)|(.+)$");
			nsid = nsid + 1;
			t_insert(buf, " xmlns:ns"..nsid.."='"..xml_escape(ns).."' ".."ns"..nsid..":"..attrk.."='"..xml_escape(v).."'");
		else
			t_insert(buf, " "..k.."='"..xml_escape(v).."'");
		end
	end
	local len = #t;
	if len == 0 then
		t_insert(buf, "/>");
	else
		t_insert(buf, ">");
		for n=1,len do
			local child = t[n];
			if child.name then
				self(child, buf, self, xml_escape);
			else
				t_insert(buf, xml_escape(child));
			end
		end
		t_insert(buf, "</"..name..">");
	end
end
function stanza_mt.__tostring(t)
	local buf = {};
	_dostring(t, buf, _dostring, xml_escape);
	return t_concat(buf);
end

function stanza_mt.top_tag(t)
	local attr_string = "";
	if t.attr then
		for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(" %s='%s'", k, xml_escape(tostring(v))); end end
	end
	return s_format("<%s%s>", t.name, attr_string);
end

function stanza_mt.get_text(t)
	if #t.tags == 0 then
		return t_concat(t);
	end
end

function stanza_mt.__add(s1, s2)
	return s1:add_direct_child(s2);
end


do
	local id = 0;
	function new_id()
		id = id + 1;
		return "lx"..id;
	end
end

function preserialize(stanza)
	local s = { name = stanza.name, attr = stanza.attr };
	for _, child in ipairs(stanza) do
		if type(child) == "table" then
			t_insert(s, preserialize(child));
		else
			t_insert(s, child);
		end
	end
	return s;
end

function deserialize(stanza)
	-- Set metatable
	if stanza then
		local attr = stanza.attr;
		for i=1,#attr do attr[i] = nil; end
		setmetatable(stanza, stanza_mt);
		for _, child in ipairs(stanza) do
			if type(child) == "table" then
				deserialize(child);
			end
		end
		if not stanza.tags then
			-- Rebuild tags
			local tags = {};
			for _, child in ipairs(stanza) do
				if type(child) == "table" then
					t_insert(tags, child);
				end
			end
			stanza.tags = tags;
			if not stanza.last_add then
				stanza.last_add = {};
			end
		end
	end
	
	return stanza;
end

function clone(stanza)
	local lookup_table = {};
	local function _copy(object)
		if type(object) ~= "table" then
			return object;
		elseif lookup_table[object] then
			return lookup_table[object];
		end
		local new_table = {};
		lookup_table[object] = new_table;
		for index, value in pairs(object) do
			new_table[_copy(index)] = _copy(value);
		end
		return setmetatable(new_table, getmetatable(object));
	end
	
	return _copy(stanza)
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
	return stanza(orig.name, orig.attr and { to = orig.attr.from, from = orig.attr.to, id = orig.attr.id, type = ((orig.name == "iq" and "result") or orig.attr.type) });
end

function error_reply(orig, type, condition, message)
	local t = reply(orig);
	t.attr.type = "error";
	t:tag("error", {type = type})
		:tag(condition, {xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}):up();
	if (message) then t:tag("text"):text(message):up(); end
	return t; -- stanza ready for adding app-specific errors
end

function presence(attr)
	return stanza("presence", attr);
end

if do_pretty_printing then
	local style_attrk = getstyle("yellow");
	local style_attrv = getstyle("red");
	local style_tagname = getstyle("red");
	local style_punc = getstyle("magenta");
	
	local attr_format = " "..getstring(style_attrk, "%s")..getstring(style_punc, "=")..getstring(style_attrv, "'%s'");
	local top_tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">");
	--local tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">").."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	local tag_format = top_tag_format.."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	function stanza_mt.pretty_print(t)
		local children_text = "";
		for n, child in ipairs(t) do
			if type(child) == "string" then	
				children_text = children_text .. xml_escape(child);
			else
				children_text = children_text .. child:pretty_print();
			end
		end

		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(tag_format, t.name, attr_string, children_text, t.name);
	end
	
	function stanza_mt.pretty_top_tag(t)
		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(top_tag_format, t.name, attr_string);
	end
else
	-- Sorry, fresh out of colours for you guys ;)
	stanza_mt.pretty_print = stanza_mt.__tostring;
	stanza_mt.pretty_top_tag = stanza_mt.top_tag;
end

return _M;
