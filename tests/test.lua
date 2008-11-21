
function run_all_tests()
	dotest "util.jid"
	dotest "core.stanza_router"
	dotest "core.s2smanager"
	dotest "core.configmanager"
end

local verbosity = tonumber(arg[1]) or 2;

package.path = package.path..";../?.lua";

require "util.import"

local env_mt = { __index = function (t,k) return rawget(_G, k) or print("WARNING: Attempt to access nil global '"..tostring(k).."'"); end };
function testlib_new_env(t)
	return setmetatable(t or {}, env_mt);
end

function assert_equal(a, b, message)
	if not (a == b) then
		error("\n   assert_equal failed: "..tostring(a).." ~= "..tostring(b)..(message and ("\n   Message: "..message) or ""), 2);
	elseif verbosity >= 4 then
		print("assert_equal succeeded: "..tostring(a).." == "..tostring(b));
	end
end

function dotest(unitname)
	local tests = setmetatable({}, { __index = _G });
	tests.__unit = unitname;
	local chunk, err = loadfile("test_"..unitname:gsub("%.", "_")..".lua");
	if not chunk then
		print("WARNING: ", "Failed to load tests for "..unitname, err);
		return;
	end

	setfenv(chunk, tests);
	local success, err = pcall(chunk);
	if not success then
		print("WARNING: ", "Failed to initialise tests for "..unitname, err);
		return;
	end
	
	local unit = setmetatable({}, { __index = setmetatable({ module = function () end }, { __index = _G }) });

	local fn = "../"..unitname:gsub("%.", "/")..".lua";
	local chunk, err = loadfile(fn);
	if not chunk then
		print("WARNING: ", "Failed to load module: "..unitname, err);
		return;
	end

	setfenv(chunk, unit);
	local success, err = pcall(chunk);
	if not success then
		print("WARNING: ", "Failed to initialise module: "..unitname, err);
		return;
	end
	
	for name, f in pairs(unit) do
		local test = rawget(tests, name);
		if type(f) ~= "function" then
			if verbosity >= 3 then
				print("INFO: ", "Skipping "..unitname.."."..name.." because it is not a function");
			end
		elseif type(test) ~= "function" then
			if verbosity >= 1 then
				print("WARNING: ", unitname.."."..name.." has no test!");
			end
		else
			local line_hook, line_info = new_line_coverage_monitor(fn);
			debug.sethook(line_hook, "l")
			local success, ret = pcall(test, f, unit);
			debug.sethook();
			if not success then
				print("TEST FAILED! Unit: ["..unitname.."] Function: ["..name.."]");
				print("   Location: "..ret:gsub(":%s*\n", "\n"));
				line_info(name, false, report_file);
			elseif verbosity >= 2 then
				print("TEST SUCCEEDED: ", unitname, name);
				print(string.format("TEST COVERED %d/%d lines", line_info(name, true, report_file)));
			else
				line_info(name, success, report_file);
			end
		end
	end
end

function runtest(f, msg)
	if not f then print("SUBTEST NOT FOUND: "..(msg or "(no description)")); return; end
	local success, ret = pcall(f);
	if success and verbosity >= 2 then
		print("SUBTEST PASSED: "..(msg or "(no description)"));
	elseif (not success) and verbosity >= 1 then
		print("SUBTEST FAILED: "..(msg or "(no description)"));
		error(ret, 0);
	end
end

function new_line_coverage_monitor(file)
	local lines_hit, funcs_hit = {}, {};
	local total_lines, covered_lines = 0, 0;
	
	for line in io.lines(file) do
		total_lines = total_lines + 1;
	end
	
	return function (event, line) -- Line hook
			if not lines_hit[line] then
				local info = debug.getinfo(2, "fSL")
				if not info.source:find(file) then return; end
				if not funcs_hit[info.func] and info.activelines then
					funcs_hit[info.func] = true;
					for line in pairs(info.activelines) do
						lines_hit[line] = false; -- Marks it as hittable, but not hit yet
					end
				end
				if lines_hit[line] == false then
					--print("New line hit: "..line.." in "..debug.getinfo(2, "S").source);
					lines_hit[line] = true;
					covered_lines = covered_lines + 1;
				end
			end
		end,
		function (test_name, success) -- Get info
			local fn = file:gsub("^%W*", "");
			local total_active_lines = 0;
			local coverage_file = io.open("reports/coverage_"..fn:gsub("%W+", "_")..".report", "a+");
			for line, active in pairs(lines_hit) do
				if active ~= nil then total_active_lines = total_active_lines + 1; end
				if coverage_file then
					if active == false then coverage_file:write(fn, "|", line, "|", name or "", "|miss\n"); 
					else coverage_file:write(fn, "|", line, "|", name or "", "|", tostring(success), "\n"); end
				end
			end
			if coverage_file then coverage_file:close(); end
			return covered_lines, total_active_lines, lines_hit;
		end
end

run_all_tests()
