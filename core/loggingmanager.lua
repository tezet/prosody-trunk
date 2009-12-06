-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local format, rep = string.format, string.rep;
local pcall = pcall;
local debug = debug;
local tostring, setmetatable, rawset, pairs, ipairs, type = 
	tostring, setmetatable, rawset, pairs, ipairs, type;
local io_open, io_write = io.open, io.write;
local math_max, rep = math.max, string.rep;
local os_date, os_getenv = os.date, os.getenv;
local getstyle, getstring = require "util.termcolours".getstyle, require "util.termcolours".getstring;

if os.getenv("__FLUSH_LOG") then
	local io_flush = io.flush;
	local _io_write = io_write;
	io_write = function(...) _io_write(...); io_flush(); end
end

local config = require "core.configmanager";
local eventmanager = require "core.eventmanager";
local logger = require "util.logger";
local debug_mode = config.get("*", "core", "debug");

_G.log = logger.init("general");

module "loggingmanager"

-- The log config used if none specified in the config file
local default_logging = { { to = "console" } };
local default_file_logging = { { to = "file", levels = { min = (debug_mode and "debug") or "info" }, timestamps = true } };
local default_timestamp = "%b %d %T";
-- The actual config loggingmanager is using
local logging_config = config.get("*", "core", "log") or default_logging;

local apply_sink_rules;
local log_sink_types = setmetatable({}, { __newindex = function (t, k, v) rawset(t, k, v); apply_sink_rules(k); end; });
local get_levels;
local logging_levels = { "debug", "info", "warn", "error", "critical" }

-- Put a rule into action. Requires that the sink type has already been registered.
-- This function is called automatically when a new sink type is added [see apply_sink_rules()]
local function add_rule(sink_config)
	local sink_maker = log_sink_types[sink_config.to];
	if sink_maker then
		if sink_config.levels and not sink_config.source then
			-- Create sink
			local sink = sink_maker(sink_config);
			
			-- Set sink for all chosen levels
			for level in pairs(get_levels(sink_config.levels)) do
				logger.add_level_sink(level, sink);
			end
		elseif sink_config.source and not sink_config.levels then
			logger.add_name_sink(sink_config.source, sink_maker(sink_config));
		elseif sink_config.source and sink_config.levels then
			local levels = get_levels(sink_config.levels);
			local sink = sink_maker(sink_config);
			logger.add_name_sink(sink_config.source,
				function (name, level, ...)
					if levels[level] then
						return sink(name, level, ...);
					end
				end);
		else
			-- All sources
			-- Create sink
			local sink = sink_maker(sink_config);
			
			-- Set sink for all levels
			for _, level in pairs(logging_levels) do
				logger.add_level_sink(level, sink);
			end
		end
	else
		-- No such sink type
	end
end

-- Search for all rules using a particular sink type, and apply
-- them. Called automatically when a new sink type is added to
-- the log_sink_types table.
function apply_sink_rules(sink_type)
	if type(logging_config) == "table" then
		for _, sink_config in pairs(logging_config) do
			if sink_config.to == sink_type then
				add_rule(sink_config);
			end
		end
	elseif type(logging_config) == "string" and (not logging_config:match("^%*")) and sink_type == "file" then
		-- User specified simply a filename, and the "file" sink type 
		-- was just added
		for _, sink_config in pairs(default_file_logging) do
			sink_config.filename = logging_config;
			add_rule(sink_config);
			sink_config.filename = nil;
		end
	elseif type(logging_config) == "string" and logging_config:match("^%*(.+)") == sink_type then
		-- Log all levels (debug+) to this sink
		add_rule({ levels = { min = "debug" }, to = sink_type });
	end
end



--- Helper function to get a set of levels given a "criteria" table
function get_levels(criteria, set)
	set = set or {};
	if type(criteria) == "string" then
		set[criteria] = true;
		return set;
	end
	local min, max = criteria.min, criteria.max;
	if min or max then
		local in_range;
		for _, level in ipairs(logging_levels) do
			if min == level then
				set[level] = true;
				in_range = true;
			elseif max == level then
				set[level] = true;
				return set;
			elseif in_range then
				set[level] = true;
			end	
		end
	end
	
	for _, level in ipairs(criteria) do
		set[level] = true;
	end
	return set;
end

--- Definition of built-in logging sinks ---

-- Null sink, must enter log_sink_types *first*
function log_sink_types.nowhere()
	return function () return false; end;
end

-- Column width for "source" (used by stdout and console)
local sourcewidth = 20;

function log_sink_types.stdout()
	local timestamps = config.timestamps;
	
	if timestamps == true then
		timestamps = default_timestamp; -- Default format
	end
	
	return function (name, level, message, ...)
		sourcewidth = math_max(#name+2, sourcewidth);
		local namelen = #name;
		if timestamps then
			io_write(os_date(timestamps), " ");
		end
		if ... then 
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", format(message, ...), "\n");
		else
			io_write(name, rep(" ", sourcewidth-namelen), level, "\t", message, "\n");
		end
	end	
end

do
	local do_pretty_printing = not os_getenv("WINDIR");
	
	local logstyles = {};
	if do_pretty_printing then
		logstyles["info"] = getstyle("bold");
		logstyles["warn"] = getstyle("bold", "yellow");
		logstyles["error"] = getstyle("bold", "red");
	end
	function log_sink_types.console(config)
		-- Really if we don't want pretty colours then just use plain stdout
		if not do_pretty_printing then
			return log_sink_types.stdout(config);
		end
		
		local timestamps = config.timestamps;

		if timestamps == true then
			timestamps = default_timestamp; -- Default format
		end

		return function (name, level, message, ...)
			sourcewidth = math_max(#name+2, sourcewidth);
			local namelen = #name;
			
			if timestamps then
				io_write(os_date(timestamps), " ");
			end
			if ... then 
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", format(message, ...), "\n");
			else
				io_write(name, rep(" ", sourcewidth-namelen), getstring(logstyles[level], level), "\t", message, "\n");
			end
		end
	end
end

local empty_function = function () end;
function log_sink_types.file(config)
	local log = config.filename;
	local logfile = io_open(log, "a+");
	if not logfile then
		return empty_function;
	end
	local write, flush = logfile.write, logfile.flush;

	eventmanager.add_event_hook("reopen-log-files", function ()
			if logfile then
				logfile:close();
			end
			logfile = io_open(log, "a+");
			if not logfile then
				write, flush = empty_function, empty_function;
			else
				write, flush = logfile.write, logfile.flush;
			end
		end);

	local timestamps = config.timestamps;

	if timestamps == nil or timestamps == true then
		timestamps = default_timestamp; -- Default format
	end

	return function (name, level, message, ...)
		if timestamps then
			write(logfile, os_date(timestamps), " ");
		end
		if ... then 
			write(logfile, name, "\t", level, "\t", format(message, ...), "\n");
		else
			write(logfile, name, "\t" , level, "\t", message, "\n");
		end
		flush(logfile);
	end;
end

function register_sink_type(name, sink_maker)
	local old_sink_maker = log_sink_types[name];
	log_sink_types[name] = sink_maker;
	return old_sink_maker;
end

return _M;
