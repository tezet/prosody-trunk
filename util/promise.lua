local promise_methods = {};
local promise_mt = { __name = "promise", __index = promise_methods };

local function is_promise(o)
	local mt = getmetatable(o);
	return mt == promise_mt;
end

local function next_pending(self, on_fulfilled, on_rejected)
	table.insert(self._pending_on_fulfilled, on_fulfilled);
	table.insert(self._pending_on_rejected, on_rejected);
end

local function next_fulfilled(promise, on_fulfilled, on_rejected) -- luacheck: ignore 212/on_rejected
	on_fulfilled(promise.value);
end

local function next_rejected(promise, on_fulfilled, on_rejected) -- luacheck: ignore 212/on_fulfilled
	on_rejected(promise.reason);
end

local function promise_settle(promise, new_state, new_next, cbs, value)
	if promise._state ~= "pending" then
		return;
	end
	promise._state = new_state;
	promise._next = new_next;
	for _, cb in ipairs(cbs) do
		cb(value);
	end
	return true;
end

local function new_resolve_functions(p)
	local resolved = false;
	local function _resolve(v)
		if resolved then return; end
		resolved = true;
		if is_promise(v) then
			v:next(new_resolve_functions(p));
		elseif promise_settle(p, "fulfilled", next_fulfilled, p._pending_on_fulfilled, v) then
			p.value = v;
		end

	end
	local function _reject(e)
		if resolved then return; end
		resolved = true;
		if promise_settle(p, "rejected", next_rejected, p._pending_on_rejected, e) then
			p.reason = e;
		end
	end
	return _resolve, _reject;
end

local function new(f)
	local p = setmetatable({ _state = "pending", _next = next_pending, _pending_on_fulfilled = {}, _pending_on_rejected = {} }, promise_mt);
	if f then
		local resolve, reject = new_resolve_functions(p);
		local ok, ret = pcall(f, resolve, reject);
		if not ok and p._state == "pending" then
			reject(ret);
		end
	end
	return p;
end

local function wrap_handler(f, resolve, reject)
	return function (param)
		local ok, ret = pcall(f, param);
		if ok then
			resolve(ret);
		else
			reject(ret);
		end
	end;
end

function promise_methods:next(on_fulfilled, on_rejected)
	return new(function (resolve, reject)
		self:_next(
			on_fulfilled and wrap_handler(on_fulfilled, resolve, reject) or nil,
			on_rejected and wrap_handler(on_rejected, resolve, reject) or nil
		);
	end);
end

function promise_methods:catch(on_rejected)
	return self:next(nil, on_rejected);
end

local function all(promises)
	return new(function (resolve, reject)
		local count, total, results = 0, #promises, {};
		for i = 1, total do
			promises[i]:next(function (v)
				results[i] = v;
				count = count + 1;
				if count == total then
					resolve(results);
				end
			end, reject);
		end
	end);
end

local function race(promises)
	return new(function (resolve, reject)
		for i = 1, #promises do
			promises[i]:next(resolve, reject);
		end
	end);
end

local function resolve(v)
	return new(function (_resolve)
		_resolve(v);
	end);
end

local function reject(v)
	return new(function (_, _reject)
		_reject(v);
	end);
end

return {
	new = new;
	resolve = resolve;
	reject = reject;
	all = all;
	race = race;
}
