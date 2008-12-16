-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--


local fatal;

local function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil; end end

local function missingdep(name, sources, msg)
	print("");
	print("**************************");
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	for k,v in pairs(sources) do
		print("", k, v);
	end
	print("");
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
	print("More help can be found on our website, at http://prosody.im/doc/depends");
	print("**************************");
	print("");
end

local lxp = softreq "lxp"

if not lxp then
	missingdep("luaexpat", { ["Ubuntu 8.04 (Hardy)"] = "sudo apt-get install liblua5.1-expat0"; ["luarocks"] = "luarocks install luaexpat"; });
	fatal = true;
end

local socket = softreq "socket"

if not socket then
	missingdep("luasocket", { ["Ubuntu 8.04 (Hardy)"] = "sudo apt-get install liblua5.1-socket2"; ["luarocks"] = "luarocks install luasocket"; });
	fatal = true;
end
	
local ssl = softreq "ssl"

if not ssl then
	if config.get("*", "core", "run_without_ssl") then
		log("warn", "Running without SSL support because run_without_ssl is defined in the config");
	else
		missingdep("LuaSec", { ["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/" }, "SSL/TLS support will not be available");
	end
end


if fatal then os.exit(1); end
