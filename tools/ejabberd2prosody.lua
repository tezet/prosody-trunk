#!/usr/bin/env lua
-- Prosody IM v0.1
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



require "erlparse";

package.path = package.path ..";../?.lua";
local serialize = require "util.serialization".serialize;
local st = require "util.stanza";
package.loaded["util.logger"] = {init = function() return function() end; end}
local dm = require "util.datamanager"
local data_path = "data";
dm.set_data_path(data_path);

local path_separator = "/"; if os.getenv("WINDIR") then path_separator = "\\" end
local _mkdir = {}
function mkdir(path)
	path = path:gsub("/", path_separator);
	--print("mkdir",path);
	local x = io.popen("mkdir "..path.." 2>&1"):read("*a");
end
function encode(s) return s and (s:gsub("%W", function (c) return string.format("%%%x", c:byte()); end)); end
function getpath(username, host, datastore, ext)
	ext = ext or "dat";
	if username then
		return format("%s/%s/%s/%s.%s", data_path, encode(host), datastore, encode(username), ext);
	elseif host then
		return format("%s/%s/%s.%s", data_path, encode(host), datastore, ext);
	else
		return format("%s/%s.%s", data_path, datastore, ext);
	end
end
function mkdirs(host)
	if not _mkdir[host] then
		local host_dir = string.format("%s/%s", data_path, encode(host));
		mkdir(host_dir);
		mkdir(host_dir.."/accounts");
		mkdir(host_dir.."/vcard");
		mkdir(host_dir.."/roster");
		mkdir(host_dir.."/private");
		mkdir(host_dir.."/offline");
		_mkdir[host] = true;
	end
end
mkdir(data_path);

function build_stanza(tuple, stanza)
	if tuple[1] == "xmlelement" then
		local name = tuple[2];
		local attr = {};
		for _, a in ipairs(tuple[3]) do attr[a[1]] = a[2]; end
		local up;
		if stanza then stanza:tag(name, attr); up = true; else stanza = st.stanza(name, attr); end
		for _, a in ipairs(tuple[4]) do build_stanza(a, stanza); end
		if up then stanza:up(); else return stanza end
	elseif tuple[1] == "xmlcdata" then
		stanza:text(tuple[2]);
	else
		error("unknown element type: "..serialize(tuple));
	end
end
function build_time(tuple)
	local Megaseconds,Seconds,Microseconds = unpack(tuple);
	return Megaseconds * 1000000 + Seconds;
end

function vcard(node, host, stanza)
	mkdirs(host);
	local ret, err = dm.store(node, host, "vcard", st.preserialize(stanza));
	print("["..(err or "success").."] vCard: "..node.."@"..host);
end
function password(node, host, password)
	mkdirs(host);
	local ret, err = dm.store(node, host, "accounts", {password = password});
	print("["..(err or "success").."] accounts: "..node.."@"..host.." = "..password);
end
function roster(node, host, jid, item)
	mkdirs(host);
	local roster = dm.load(node, host, "roster") or {};
	roster[jid] = item;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster: " ..node.."@"..host.." - "..jid);
end
function private_storage(node, host, xmlns, stanza)
	mkdirs(host);
	local private = dm.load(node, host, "private") or {};
	private[xmlns] = st.preserialize(stanza);
	local ret, err = dm.store(node, host, "private", private);
	print("["..(err or "success").."] private: " ..node.."@"..host.." - "..xmlns);
end
function offline_msg(node, host, t, stanza)
	mkdirs(host);
	stanza.attr.stamp = os.date("!%Y-%m-%dT%H:%M:%SZ", t);
	stanza.attr.stamp_legacy = os.date("!%Y%m%dT%H:%M:%S", t);
	local ret, err = dm.list_append(node, host, "offline", st.preserialize(stanza));
	print("["..(err or "success").."] offline: " ..node.."@"..host.." - "..os.date("!%Y-%m-%dT%H:%M:%SZ", t));
end


local filters = {
	passwd = function(tuple)
		password(tuple[2][1], tuple[2][2], tuple[3]);
	end;
	vcard = function(tuple)
		vcard(tuple[2][1], tuple[2][2], build_stanza(tuple[3]));
	end;
	roster = function(tuple)
		local node = tuple[3][1]; local host = tuple[3][2];
		local contact = tuple[4][1].."@"..tuple[4][2];
		local name = tuple[5]; local subscription = tuple[6];
		local ask = tuple[7]; local groups = tuple[8];
		if type(name) ~= type("") then name = nil; end
		if ask == "none" then ask = nil; elseif ask == "out" then ask = "subscribe" else error(ask) end
		if subscription ~= "both" and subscription ~= "from" and subscription ~= "to" and subscription ~= "none" then error(subscription) end
		local item = {name = name, ask = ask, subscription = subscription, groups = {}};
		for _, g in ipairs(groups) do item.groups[g] = true; end
		roster(node, host, contact, item);
	end;
	private_storage = function(tuple)
		private_storage(tuple[2][1], tuple[2][2], tuple[2][3], build_stanza(tuple[3]));
	end;
	offline_msg = function(tuple)
		offline_msg(tuple[2][1], tuple[2][2], build_time(tuple[3]), build_stanza(tuple[7]));
	end;
	config = function(tuple)
		if tuple[2] == "hosts" then
			local output = io.output(); io.output("prosody.cfg.lua");
			io.write("-- Configuration imported from ejabberd --\n");
			io.write([[Host "*"
	modules_enabled = {
		"saslauth"; -- Authentication for clients and servers. Recommended if you want to log in.
		"legacyauth"; -- Legacy authentication. Only used by some old clients and bots.
		"roster"; -- Allow users to have a roster. Recommended ;)
		"register"; -- Allow users to register on this server using a client
		"tls"; -- Add support for secure TLS on c2s/s2s connections
		"vcard"; -- Allow users to set vCards
		"private"; -- Private XML storage (for room bookmarks, etc.)
		"version"; -- Replies to server version requests
		"dialback"; -- s2s dialback support
		"uptime";
		"disco";
		"time";
		"ping";
		--"selftests";
	};
]]);
			for _, h in ipairs(tuple[3]) do
				io.write("Host \"" .. h .. "\"\n");
			end
			io.output(output);
			print("prosody.cfg.lua created");
		end
	end;
};

local arg = ...;
local help = "/? -? ? /h -h /help -help --help";
if not arg or help:find(arg, 1, true) then
	print([[ejabberd db dump importer for Prosody

  Usage: ejabberd2prosody.lua filename.txt

The file can be generated from ejabberd using:
  sudo ./bin/ejabberdctl dump filename.txt

Note: The path of ejabberdctl depends on your ejabberd installation, and ejabberd needs to be running for ejabberdctl to work.]]);
	os.exit(1);
end
local count = 0;
local t = {};
for item in erlparse.parseFile(arg) do
	count = count + 1;
	local name = item[1];
	t[name] = (t[name] or 0) + 1;
	--print(count, serialize(item));
	if filters[name] then filters[name](item); end
end
--print(serialize(t));
