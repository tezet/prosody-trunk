
local coroutine = coroutine;
local tonumber = tonumber;

local deadroutine = coroutine.create(function() end);
coroutine.resume(deadroutine);

module("httpstream")

local function parser(data, success_cb)
	local function readline()
		local pos = data:find("\r\n", nil, true);
		while not pos do
			data = data..coroutine.yield();
			pos = data:find("\r\n", nil, true);
		end
		local r = data:sub(1, pos-1);
		data = data:sub(pos+2);
		return r;
	end
	local function readlength(n)
		while #data < n do
			data = data..coroutine.yield();
		end
		local r = data:sub(1, n);
		data = data:sub(n + 1);
		return r;
	end
	local function readheaders()
		local headers = {}; -- read headers
		while true do
			local line = readline();
			if line == "" then break; end -- headers done
			local key, val = line:match("^([^%s:]+): *(.*)$");
			if not key then coroutine.yield("invalid-header-line"); end -- TODO handle multi-line and invalid headers
			key = key:lower();
			headers[key] = headers[key] and headers[key]..","..val or val;
		end
	end
	
	while true do
		-- read status line
		local status_line = readline();
		local method, path, httpversion = status_line:match("^(%S+)%s+(%S+)%s+HTTP/(%S+)$");
		if not method then coroutine.yield("invalid-status-line"); end
		-- TODO parse url
		local headers = readheaders();
		
		-- read body
		local len = tonumber(headers["content-length"]);
		len = len or 0; -- TODO check for invalid len
		local body = readlength(len);
		
		success_cb({
			method = method;
			path = path;
			httpversion = httpversion;
			headers = headers;
			body = body;
		});
	end
end

function new(success_cb, error_cb)
	local co = coroutine.create(parser);
	return {
		feed = function(self, data)
			if not data then
				co = deadroutine;
				return error_cb();
			end
			local success, result = coroutine.resume(co, data, success_cb);
			if result then
				co = deadroutine;
				return error_cb(result);
			end
		end;
	};
end

return _M;
