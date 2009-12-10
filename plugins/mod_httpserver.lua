-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local httpserver = require "net.httpserver";

local open = io.open;
local t_concat = table.concat;

local http_base = config.get("*", "core", "http_path") or "www_files";

local response_400 = { status = "400 Bad Request", body = "<h1>Bad Request</h1>Sorry, we didn't understand your request :(" };
local response_404 = { status = "404 Not Found", body = "<h1>Page Not Found</h1>Sorry, we couldn't find what you were looking for :(" };

-- TODO: Should we read this from /etc/mime.types if it exists? (startup time...?)
local mime_map = {
	html = "text/html";
	htm = "text/html";
	xml = "text/xml";
	xsl = "text/xml";
	txt = "plain/text; charset=utf-8";
	js = "text/javascript";
	css = "text/css";
};

local function preprocess_path(path)
	if path:sub(1,1) ~= "/" then
		path = "/"..path;
	end
	local level = 0;
	for component in path:gmatch("([^/]+)/") do
		if component == ".." then
			level = level - 1;
		elseif component ~= "." then
			level = level + 1;
		end
		if level < 0 then
			return nil;
		end
	end
	return path;
end

function serve_file(path)
	local f, err = open(http_base..path, "rb");
	if not f then return response_404; end
	local data = f:read("*a");
	f:close();
	local ext = path:match("%.([^.]*)$");
	local mime = mime_map[ext]; -- Content-Type should be nil when not known
	module:log("warn", "ext: %s, mime: %s", ext or "(nil)", mime or "(nil)");
	return {
		headers = { ["Content-Type"] = mime; };
		body = data;
	};
end

local function handle_file_request(method, body, request)
	local path = preprocess_path(request.url.path);
	if not path then return response_400; end
	path = path:gsub("^/[^/]+", ""); -- Strip /files/
	return serve_file(path);
end

local function handle_default_request(method, body, request)
	local path = preprocess_path(request.url.path);
	if not path then return response_400; end
	return serve_file(path);
end

local ports = config.get(module.host, "core", "http_ports") or { 5280 };
httpserver.set_default_handler(handle_default_request);
httpserver.new_from_config(ports, handle_file_request, { base = "files" });
