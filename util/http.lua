-- Prosody IM
-- Copyright (C) 2013 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local http = {};

function http.urlencode(s)
	return s and (s:gsub("[^a-zA-Z0-9.~_-]", function (c) return format("%%%02x", c:byte()); end));
end
function http.urldecode(s)
	return s and (s:gsub("%%(%x%x)", function (c) return char(tonumber(c,16)); end));
end

local function _formencodepart(s)
	return s and (s:gsub("%W", function (c)
		if c ~= " " then
			return format("%%%02x", c:byte());
		else
			return "+";
		end
	end));
end

function http.formencode(form)
	local result = {};
	if form[1] then -- Array of ordered { name, value }
		for _, field in ipairs(form) do
			t_insert(result, _formencodepart(field.name).."=".._formencodepart(field.value));
		end
	else -- Unordered map of name -> value
		for name, value in pairs(form) do
			t_insert(result, _formencodepart(name).."=".._formencodepart(value));
		end
	end
	return t_concat(result, "&");
end

function http.formdecode(s)
	if not s:match("=") then return urldecode(s); end
	local r = {};
	for k, v in s:gmatch("([^=&]*)=([^&]*)") do
		k, v = k:gsub("%+", "%%20"), v:gsub("%+", "%%20");
		k, v = urldecode(k), urldecode(v);
		t_insert(r, { name = k, value = v });
		r[k] = v;
	end
	return r;
end

function http.contains_token(field, token)
	field = ","..field:gsub("[ \t]", ""):lower()..",";
	return field:find(","..token:lower()..",", 1, true) ~= nil;
end



return http;
