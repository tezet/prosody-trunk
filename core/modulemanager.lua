
local log = require "util.logger".init("modulemanager")

local loadfile, pcall = loadfile, pcall;
local setmetatable, setfenv, getfenv = setmetatable, setfenv, getfenv;
local pairs, ipairs = pairs, ipairs;
local type = type;

local tostring, print = tostring, print;

local _G = _G;

module "modulemanager"

local handler_info = {};
local handlers = {};
					
local modulehelpers = setmetatable({}, { __index = _G });

function modulehelpers.add_iq_handler(origin_type, xmlns, handler)
	handlers[origin_type] = handlers[origin_type] or {};
	handlers[origin_type].iq = handlers[origin_type].iq or {};
	if not handlers[origin_type].iq[xmlns] then
		handlers[origin_type].iq[xmlns]= handler;
		handler_info[handler] = getfenv(2).module;
		log("debug", "mod_%s now handles tag 'iq' with query namespace '%s'", getfenv(2).module.name, xmlns);
	else
		log("warning", "mod_%s wants to handle tag 'iq' with query namespace '%s' but mod_%s already handles that", getfenv(2).module.name, xmlns, handler_info[handlers[origin_type].iq[xmlns]].module.name);
	end
end

function modulehelpers.add_handler(origin_type, tag, handler)
	handlers[origin_type] = handlers[origin_type] or {};
	if not handlers[origin_type][tag] then
		handlers[origin_type][tag]= handler;
		handler_info[handler] = getfenv(2).module;
		log("debug", "mod_%s now handles tag '%s'", getfenv(2).module.name, tag);
	elseif handler_info[handlers[origin_type][tag]] then
		log("warning", "mod_%s wants to handle tag '%s' but mod_%s already handles that", getfenv(2).module.name, tag, handler_info[handlers[origin_type][tag]].module.name);
	end
end
					
function loadall()
	load("saslauth");
	load("legacyauth");
	load("roster");
end

function load(name)
	local mod, err = loadfile("plugins/mod_"..name..".lua");
	if not mod then
		log("error", "Unable to load module '%s': %s", name or "nil", err or "nil");
		return;
	end
	
	local pluginenv = setmetatable({ module = { name = name } }, { __index = modulehelpers });
	
	setfenv(mod, pluginenv);
	local success, ret = pcall(mod);
	if not success then
		log("error", "Error initialising module '%s': %s", name or "nil", ret or "nil");
		return;
	end
end

function handle_stanza(origin, stanza)
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns, origin.type;
	
	if name == "iq" and xmlns == "jabber:client" and handlers[origin_type] then
		log("debug", "Stanza is an <iq/>");
		local child = stanza.tags[1];
		if child then
			local xmlns = child.attr.xmlns;
			log("debug", "Stanza has xmlns: %s", xmlns);
			local handler = handlers[origin_type][name][xmlns];
			if  handler then
				log("debug", "Passing stanza to mod_%s", handler_info[handler].name);
				return handler(origin, stanza) or true;
			end

		end
		--FIXME: All iq's must be replied to, here we should return service-unavailable I think
	elseif handlers[origin_type] then
		local handler = handlers[origin_type][name];
		if  handler then
			log("debug", "Passing stanza to mod_%s", handler_info[handler].name);
			return handler(origin, stanza) or true;
		end
	end
	log("debug", "Stanza unhandled by any modules");
	return false; -- we didn't handle it
end
