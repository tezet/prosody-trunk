local log = require "util.logger".init("util.async");
local new_id = require "util.id".short;

local function checkthread()
	local thread, main = coroutine.running();
	if not thread or main then
		error("Not running in an async context, see https://prosody.im/doc/developers/util/async");
	end
	return thread;
end

local function runner_from_thread(thread)
	local level = 0;
	-- Find the 'level' of the top-most function (0 == current level, 1 == caller, ...)
	while debug.getinfo(thread, level, "") do level = level + 1; end
	local name, runner = debug.getlocal(thread, level-1, 1);
	if name ~= "self" or type(runner) ~= "table" or runner.thread ~= thread then
		return nil;
	end
	return runner;
end

local function call_watcher(runner, watcher_name, ...)
	local watcher = runner.watchers[watcher_name];
	if not watcher then
		return false;
	end
	runner:log("debug", "Calling '%s' watcher", watcher_name);
	local ok, err = pcall(watcher, runner, ...); -- COMPAT: Switch to xpcall after Lua 5.1
	if not ok then
		runner:log("error", "Error in '%s' watcher: %s", watcher_name, err);
		return nil, err;
	end
	return true;
end

local function runner_continue(thread)
	-- ASSUMPTION: runner is in 'waiting' state (but we don't have the runner to know for sure)
	if coroutine.status(thread) ~= "suspended" then -- This should suffice
		log("error", "unexpected async state: thread not suspended");
		return false;
	end
	local ok, state, runner = coroutine.resume(thread);
	if not ok then
		local err = state;
		-- Running the coroutine failed, which means we have to find the runner manually,
		-- in order to inform the error handler
		runner = runner_from_thread(thread);
		if not runner then
			log("error", "unexpected async state: unable to locate runner during error handling");
			return false;
		end
		call_watcher(runner, "error", debug.traceback(thread, err));
		runner.state, runner.thread = "ready", nil;
		return runner:run();
	elseif state == "ready" then
		-- If state is 'ready', it is our responsibility to update runner.state from 'waiting'.
		-- We also have to :run(), because the queue might have further items that will not be
		-- processed otherwise. FIXME: It's probably best to do this in a nexttick (0 timer).
		runner.state = "ready";
		runner:run();
	end
	return true;
end

local function waiter(num)
	local thread = checkthread();
	num = num or 1;
	local waiting;
	return function ()
		if num == 0 then return; end -- already done
		waiting = true;
		coroutine.yield("wait");
	end, function ()
		num = num - 1;
		if num == 0 and waiting then
			runner_continue(thread);
		elseif num < 0 then
			error("done() called too many times");
		end
	end;
end

local function guarder()
	local guards = {};
	return function (id, func)
		local thread = checkthread();
		local guard = guards[id];
		if not guard then
			guard = {};
			guards[id] = guard;
			log("debug", "New guard!");
		else
			table.insert(guard, thread);
			log("debug", "Guarded. %d threads waiting.", #guard)
			coroutine.yield("wait");
		end
		local function exit()
			local next_waiting = table.remove(guard, 1);
			if next_waiting then
				log("debug", "guard: Executing next waiting thread (%d left)", #guard)
				runner_continue(next_waiting);
			else
				log("debug", "Guard off duty.")
				guards[id] = nil;
			end
		end
		if func then
			func();
			exit();
			return;
		end
		return exit;
	end;
end

local runner_mt = {};
runner_mt.__index = runner_mt;

local function runner_create_thread(func, self)
	local thread = coroutine.create(function (self) -- luacheck: ignore 432/self
		while true do
			func(coroutine.yield("ready", self));
		end
	end);
	assert(coroutine.resume(thread, self)); -- Start it up, it will return instantly to wait for the first input
	return thread;
end

local empty_watchers = {};
local function runner(func, watchers, data)
	return setmetatable({ func = func, thread = false, state = "ready", notified_state = "ready",
		queue = {}, watchers = watchers or empty_watchers, data = data, id = new_id() }
	, runner_mt);
end

-- Add a task item for the runner to process
function runner_mt:run(input)
	if input ~= nil then
		table.insert(self.queue, input);
		self:log("debug", "queued new work item, %d items queued", #self.queue);
	end
	if self.state ~= "ready" then
		-- The runner is busy. Indicate that the task item has been
		-- queued, and return information about the current runner state
		return true, self.state, #self.queue;
	end

	local q, thread = self.queue, self.thread;
	if not thread or coroutine.status(thread) == "dead" then
		self:log("debug", "creating new coroutine");
		-- Create a new coroutine for this runner
		thread = runner_create_thread(self.func, self);
		self.thread = thread;
	end

	-- Process task item(s) while the queue is not empty, and we're not blocked
	local n, state, err = #q, self.state, nil;
	self.state = "running";
	self:log("debug", "running main loop");
	while n > 0 and state == "ready" and not err do
		local consumed;
		-- Loop through queue items, and attempt to run them
		for i = 1,n do
			local queued_input = q[i];
			local ok, new_state = coroutine.resume(thread, queued_input);
			if not ok then
				-- There was an error running the coroutine, save the error, mark runner as ready to begin again
				consumed, state, err = i, "ready", debug.traceback(thread, new_state);
				self.thread = nil;
				break;
			elseif new_state == "wait" then
				 -- Runner is blocked on waiting for a task item to complete
				consumed, state = i, "waiting";
				break;
			end
		end
		-- Loop ended - either queue empty because all tasks passed without blocking (consumed == nil)
		-- or runner is blocked/errored, and consumed will contain the number of tasks processed so far
		if not consumed then consumed = n; end
		-- Remove consumed items from the queue array
		if q[n+1] ~= nil then
			n = #q;
		end
		for i = 1, n do
			q[i] = q[consumed+i];
		end
		n = #q;
	end
	-- Runner processed all items it can, so save current runner state
	self.state = state;
	if err or state ~= self.notified_state then
		self:log("debug", "changed state from %s to %s", self.notified_state, err and ("error ("..state..")") or state);
		if err then
			state = "error"
		else
			self.notified_state = state;
		end
		local handler = self.watchers[state];
		if handler then handler(self, err); end
	end
	if n > 0 then
		return self:run();
	end
	return true, state, n;
end

-- Add a task item to the queue without invoking the runner, even if it is idle
function runner_mt:enqueue(input)
	table.insert(self.queue, input);
	self:log("debug", "queued new work item, %d items queued", #self.queue);
end

function runner_mt:log(level, fmt, ...)
	return log(level, "[runner %s] "..fmt, self.id, ...);
end

local function ready()
	return pcall(checkthread);
end

local once; -- forward declaration
do
	local once_watchers = {
		error = function (_, err)
			error(err);
		end;
	};
	local function once_runner(func) func(); end
	function once(func)
		local r = runner(func, once_watchers);
		return r:run(func);
	end
end

return {
	once = once;
	ready = ready;
	waiter = waiter;
	guarder = guarder;
	runner = runner
};
