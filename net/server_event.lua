--[[


			server.lua based on lua/libevent by blastbeat

			notes:
			-- when using luaevent, never register 2 or more EV_READ at one socket, same for EV_WRITE
			-- you cant even register a new EV_READ/EV_WRITE callback inside another one
			-- never call eventcallback:close( ) from inside eventcallback
			-- to do some of the above, use timeout events or something what will called from outside
			-- dont let garbagecollect eventcallbacks, as long they are running
			-- when using luasec, there are 4 cases of timeout errors: wantread or wantwrite during reading or writing

--]]


local SCRIPT_NAME           = "server_event.lua"
local SCRIPT_VERSION        = "0.05"
local SCRIPT_AUTHOR         = "blastbeat"
local LAST_MODIFIED         = "2009/11/20"

local cfg = {
	MAX_CONNECTIONS       = 100000,  -- max per server connections (use "ulimit -n" on *nix)
	MAX_HANDSHAKE_ATTEMPS = 10,  -- attemps to finish ssl handshake
	HANDSHAKE_TIMEOUT     = 1,  -- timout in seconds per handshake attemp
	MAX_READ_LENGTH       = 1024 * 1024 * 1024 * 1024,  -- max bytes allowed to read from sockets
	MAX_SEND_LENGTH       = 1024 * 1024 * 1024 * 1024,  -- max bytes size of write buffer (for writing on sockets)
	ACCEPT_DELAY          = 10,  -- seconds to wait until the next attemp of a full server to accept
	READ_TIMEOUT          = 60 * 30,  -- timeout in seconds for read data from socket
	WRITE_TIMEOUT         = 30,  -- timeout in seconds for write data on socket
	CONNECT_TIMEOUT       = 10,  -- timeout in seconds for connection attemps
	CLEAR_DELAY           = 5,  -- seconds to wait for clearing interface list (and calling ondisconnect listeners) 
	DEBUG                 = true,  -- show debug messages
}

local function use(x) return rawget(_G, x); end
local print = use "print"
local pcall = use "pcall"
local ipairs = use "ipairs"
local string = use "string"
local select = use "select"
local require = use "require"
local tostring = use "tostring"
local coroutine = use "coroutine"
local setmetatable = use "setmetatable"

local ssl = use "ssl"
local socket = use "socket"

local log = require ("util.logger").init("socket")

local function debug(...)
	return log("debug", ("%s "):rep(select('#', ...)), ...)
end

local bitor = ( function( ) -- thx Rici Lake
	local hasbit = function( x, p )
		return x % ( p + p ) >= p
	end
	return function( x, y ) 
		local p = 1
		local z = 0
		local limit = x > y and x or y
		while p <= limit do 
			if hasbit( x, p ) or hasbit( y, p ) then
				z = z + p
			end
			p = p + p
		end
		return z
	end
end )( )

local getid = function( )
	return function( )
	end
end

local event = require "luaevent.core"
local base = event.new( )
local EV_READ = event.EV_READ
local EV_WRITE = event.EV_WRITE
local EV_TIMEOUT = event.EV_TIMEOUT

local EV_READWRITE = bitor( EV_READ, EV_WRITE )

local interfacelist = ( function( )  -- holds the interfaces for sockets
	local array = { }
	local len = 0
	return function( method, arg )
		if "add" == method then
			len = len + 1
			array[ len ] = arg
			arg:_position( len )
			return len
		elseif "delete" == method then
			if len <= 0 then
				return nil, "array is already empty"
			end
			local position = arg:_position()  -- get position in array
			if position ~= len then
				local interface = array[ len ]  -- get last interface
				array[ position ] = interface  -- copy it into free position
				array[ len ] = nil  -- free last position
				interface:_position( position )  -- set new position in array
			else  -- free last position
				array[ len ] = nil
			end
			len = len - 1
			return len    
		else
			return array
		end
	end
end )( )

-- Client interface methods
local interface_mt
do
	interface_mt = {}; interface_mt.__index = interface_mt;
	
	local addevent = base.addevent
	local coroutine_wrap, coroutine_yield = coroutine.wrap,coroutine.yield
	local string_len = string.len
	
	-- Private methods
	function interface_mt:_position(new_position)
			self.position = new_position or self.position
			return self.position;
	end
	function interface_mt:_close() -- regs event to start self:_destroy()
			local callback = function( )
				self:_destroy();
				self.eventclose = nil
				return -1
			end
			self.eventclose = addevent( base, nil, EV_TIMEOUT, callback, 0 )
			return true
	end
	
	function interface_mt:_start_connection(plainssl) -- should be called from addclient
			local callback = function( event )
				if EV_TIMEOUT == event then  -- timout during connection
					self.fatalerror = "connection timeout"
					self.listener.ontimeout( self )  -- call timeout listener
					self:_close()
					debug( "new connection failed. id:", self, "error:", self.fatalerror )
				else
					if plainssl then  -- start ssl session
						self:_start_ssl( self.listener.onconnect )
					else  -- normal connection
						self:_start_session( self.listener.onconnect )
					end
					debug( "new connection established. id:", self )
				end
				self.eventconnect = nil
				return -1
			end
			self.eventconnect = addevent( base, self.conn, EV_WRITE, callback, cfg.CONNECT_TIMEOUT )
			return true
	end
	function interface_mt:_start_session(onconnect) -- new session, for example after startssl
		if self.type == "client" then
			local callback = function( )
				self:_lock( false,  false, false )
				--vdebug( "start listening on client socket with id:", self )      
				self.eventread = addevent( base, self.conn, EV_READ, self.readcallback, cfg.READ_TIMEOUT )  -- register callback
				onconnect( self )
				self.eventsession = nil
				return -1
			end
			self.eventsession = addevent( base, nil, EV_TIMEOUT, callback, 0 )
		else
			self:_lock( false )
			--vdebug( "start listening on server socket with id:", self )
			self.eventread = addevent( base, self.conn, EV_READ, self.readcallback )  -- register callback
		end
		return true
	end
	function interface_mt:_start_ssl(arg) -- old socket will be destroyed, therefore we have to close read/write events first
			--vdebug( "starting ssl session with client id:", self )
			local _
			_ = self.eventread and self.eventread:close( )  -- close events; this must be called outside of the event callbacks!
			_ = self.eventwrite and self.eventwrite:close( )
			self.eventread, self.eventwrite = nil, nil
			local err
			self.conn, err = ssl.wrap( self.conn, self.sslctx )
			if err then
				self.fatalerror = err
				self.conn = nil  -- cannot be used anymore
				if "onconnect" == arg then
					self.ondisconnect = nil  -- dont call this when client isnt really connected
				end
				self:_close()
				debug( "fatal error while ssl wrapping:", err )
				return false
			end
			self.conn:settimeout( 0 )  -- set non blocking
			local handshakecallback = coroutine_wrap(
				function( event )
					local _, err
					local attempt = 0
					local maxattempt = cfg.MAX_HANDSHAKE_ATTEMPS
					while attempt < 1000 do  -- no endless loop
						attempt = attempt + 1
						debug( "ssl handshake of client with id:", self, "attemp:", attempt )
						if attempt > maxattempt then
							self.fatalerror = "max handshake attemps exceeded"
						elseif EV_TIMEOUT == event then
							self.fatalerror = "timeout during handshake"
						else
							_, err = self.conn:dohandshake( )
							if not err then
								self:_lock( false, false, false )  -- unlock the interface; sending, closing etc allowed
								self.send = self.conn.send  -- caching table lookups with new client object
								self.receive = self.conn.receive
								local onsomething
								if "onconnect" == arg then  -- trigger listener
									onsomething = self.listener.onconnect
								else
									onsomething = self.listener.onsslconnection
								end
								self:_start_session( onsomething )
								debug( "ssl handshake done" )
								self.eventhandshake = nil
								return -1
							end
							debug( "error during ssl handshake:", err )  
							if err == "wantwrite" then
								event = EV_WRITE
							elseif err == "wantread" then
								event = EV_READ
							else
								self.fatalerror = err
							end            
						end
						if self.fatalerror then
							if "onconnect" == arg then
								self.ondisconnect = nil  -- dont call this when client isnt really connected
							end
							self:_close()
							debug( "handshake failed because:", self.fatalerror )
							self.eventhandshake = nil
							return -1
						end
						event = coroutine_yield( event, cfg.HANDSHAKE_TIMEOUT )  -- yield this monster...
					end
				end
			)
			debug "starting handshake..."
			self:_lock( false, true, true )  -- unlock read/write events, but keep interface locked 
			self.eventhandshake = addevent( base, self.conn, EV_READWRITE, handshakecallback, cfg.HANDSHAKE_TIMEOUT )
			return true
	end
	function interface_mt:_destroy()  -- close this interface + events and call last listener
			debug( "closing client with id:", self )
			self:_lock( true, true, true )  -- first of all, lock the interface to avoid further actions
			local _
			_ = self.eventread and self.eventread:close( )  -- close events; this must be called outside of the event callbacks!
			if self.type == "client" then
				_ = self.eventwrite and self.eventwrite:close( )
				_ = self.eventhandshake and self.eventhandshake:close( )
				_ = self.eventstarthandshake and self.eventstarthandshake:close( )
				_ = self.eventconnect and self.eventconnect:close( )
				_ = self.eventsession and self.eventsession:close( )
				_ = self.eventwritetimeout and self.eventwritetimeout:close( )
				_ = self.eventreadtimeout and self.eventreadtimeout:close( )
				_ = self.ondisconnect and self:ondisconnect( self.fatalerror )  -- call ondisconnect listener (wont be the case if handshake failed on connect)
				_ = self.conn and self.conn:close( ) -- close connection, must also be called outside of any socket registered events!
				self._server:counter(-1);
				self.eventread, self.eventwrite = nil, nil
				self.eventstarthandshake, self.eventhandshake, self.eventclose = nil, nil, nil
				self.readcallback, self.writecallback = nil, nil
			else
				self.conn:close( )
				self.eventread, self.eventclose = nil, nil
				self.interface, self.readcallback = nil, nil
			end
			interfacelist( "delete", self )
			return true
	end
	function interface_mt:_lock(nointerface, noreading, nowriting)  -- lock or unlock this interface or events
			self.nointerface, self.noreading, self.nowriting = nointerface, noreading, nowriting
			return nointerface, noreading, nowriting
	end

	function interface_mt:counter(c)
		if c then
			self._connections = self._connections - c
		end
		return self._connections
	end
	
	-- Public methods
	function interface_mt:write(data)
		--vdebug( "try to send data to client, id/data:", self, data )
		data = tostring( data )
		local len = string_len( data )
		local total = len + self.writebufferlen
		if total > cfg.MAX_SEND_LENGTH then  -- check buffer length
			local err = "send buffer exceeded"
			debug( "error:", err )  -- to much, check your app
			return nil, err
		end 
		self.writebuffer = self.writebuffer .. data -- new buffer
		self.writebufferlen = total
		if not self.eventwrite then  -- register new write event
			--vdebug( "register new write event" )
			self.eventwrite = addevent( base, self.conn, EV_WRITE, self.writecallback, cfg.WRITE_TIMEOUT )
		end
		return true
	end
	function interface_mt:close(now)
		debug( "try to close client connection with id:", self )
		if self.type == "client" then
			self.fatalerror = "client to close"
			if ( not self.eventwrite ) or now then  -- try to close immediately
				self:_lock( true, true, true )
				self:_close()
				return true
			else  -- wait for incomplete write request
				self:_lock( true, true, false )
				debug "closing delayed until writebuffer is empty"
				return nil, "writebuffer not empty, waiting"
			end
		else
			debug( "try to close server with id:", self, "args:", now )
			self.fatalerror = "server to close"
			self:_lock( true )
			local count = 0
			for _, item in ipairs( interfacelist( ) ) do
				if ( item.type ~= "server" ) and ( item._server == self ) then  -- client/server match
					if item:close( now ) then  -- writebuffer was empty
						count = count + 1
					end
				end
			end
			local timeout = 0  -- dont wait for unfinished writebuffers of clients...
			if not now then
				timeout = cfg.WRITE_TIMEOUT  -- ...or wait for it
			end
			self:_close( timeout )  -- add new event to remove the server interface
			debug( "seconds remained until server is closed:", timeout )
			return count  -- returns finished clients with empty writebuffer
		end
	end
	
	function interface_mt:server()
		return self._server or self;
	end
	
	function interface_mt:port()
		return self._port
	end
	
	function interface_mt:ip()
		return self._ip
	end
	
	function interface_mt:ssl()
		return self.usingssl
	end

	function interface_mt:type()
		return self._type or "client"
	end
	
	function interface_mt:connections()
		return self._connections
	end
	
	function interface_mt:address()
		return self.addr
	end
	
			
	
	function interface_mt:starttls()
		debug( "try to start ssl at client id:", self )
		local err
		if not self.sslctx then  -- no ssl available
			err = "no ssl context available"
		elseif self.usingssl then  -- startssl was already called
			err = "ssl already active"
		end
		if err then
			debug( "error:", err )
			return nil, err      
		end
		self.usingssl = true
		self.startsslcallback = function( )  -- we have to start the handshake outside of a read/write event
			self:_start_ssl();
			self.eventstarthandshake = nil
			return -1
		end
		if not self.eventwrite then
			self:_lock( true, true, true )  -- lock the interface, to not disturb the handshake
			self.eventstarthandshake = addevent( base, nil, EV_TIMEOUT, self.startsslcallback, 0 )  -- add event to start handshake
		else  -- wait until writebuffer is empty
			self:_lock( true, true, false )
			debug "ssl session delayed until writebuffer is empty..."
		end
		return true
	end
	
	function interface_mt.onconnect()
	end
end			

-- End of client interface methods

local handleclient;
do
	local string_sub = string.sub  -- caching table lookups
	local string_len = string.len
	local addevent = base.addevent
	local coroutine_wrap = coroutine.wrap
	local socket_gettime = socket.gettime
	local coroutine_yield = coroutine.yield
	function handleclient( client, ip, port, server, pattern, listener, _, sslctx )  -- creates an client interface
		--vdebug("creating client interfacce...")
		local interface = {
			type = "client";
			conn = client;
			currenttime = socket_gettime( );  -- safe the origin
			writebuffer = "";  -- writebuffer
			writebufferlen = 0;  -- length of writebuffer
			send = client.send;  -- caching table lookups
			receive = client.receive;
			onconnect = listener.onconnect;  -- will be called when client disconnects
			ondisconnect = listener.ondisconnect;  -- will be called when client disconnects
			onincoming = listener.onincoming;  -- will be called when client sends data
			eventread = false, eventwrite = false, eventclose = false,
			eventhandshake = false, eventstarthandshake = false;  -- event handler
			eventconnect = false, eventsession = false;  -- more event handler...
			eventwritetimeout = false;  -- even more event handler...
			eventreadtimeout = false;
			fatalerror = false;  -- error message
			writecallback = false;  -- will be called on write events
			readcallback = false;  -- will be called on read events
			nointerface = true;  -- lock/unlock parameter of this interface
			noreading = false, nowriting = false;  -- locks of the read/writecallback
			startsslcallback = false;  -- starting handshake callback
			position = false;  -- position of client in interfacelist
			
			-- Properties
			_ip = ip, _port = port, _server = server, _pattern = pattern,
			_sslctx = sslctx; -- parameters
			_usingssl = false;  -- client is using ssl;
		}
		interface.writecallback = function( event )  -- called on write events
			--vdebug( "new client write event, id/ip/port:", interface, ip, port )
			if interface.nowriting or ( interface.fatalerror and ( "client to close" ~= interface.fatalerror ) ) then  -- leave this event
				--vdebug( "leaving this event because:", interface.nowriting or interface.fatalerror )
				interface.eventwrite = false
				return -1
			end
			if EV_TIMEOUT == event then  -- took too long to write some data to socket -> disconnect
				interface.fatalerror = "timeout during writing"
				debug( "writing failed:", interface.fatalerror ) 
				interface:_close()
				interface.eventwrite = false
				return -1
			else  -- can write :)
				if interface.usingssl then  -- handle luasec
					if interface.eventreadtimeout then  -- we have to read first
						local ret = interface.readcallback( )  -- call readcallback
						--vdebug( "tried to read in writecallback, result:", ret )
					end
					if interface.eventwritetimeout then  -- luasec only
						interface.eventwritetimeout:close( )  -- first we have to close timeout event which where regged after a wantread error
						interface.eventwritetimeout = false
					end
				end
				local succ, err, byte = interface.send( interface.conn, interface.writebuffer, 1, interface.writebufferlen )
				--vdebug( "write data:", interface.writebuffer, "error:", err, "part:", byte )
				if succ then  -- writing succesful
					interface.writebuffer = ""
					interface.writebufferlen = 0
					if interface.fatalerror then
						debug "closing client after writing"
						interface:_close()  -- close interface if needed
					elseif interface.startsslcallback then  -- start ssl connection if needed
						debug "starting ssl handshake after writing"
						interface.eventstarthandshake = addevent( base, nil, EV_TIMEOUT, interface.startsslcallback, 0 )
					elseif interface.eventreadtimeout then
						return EV_WRITE, EV_TIMEOUT
					end
					interface.eventwrite = nil
					return -1
				elseif byte then  -- want write again
					--vdebug( "writebuffer is not empty:", err )
					interface.writebuffer = string_sub( interface.writebuffer, byte + 1, interface.writebufferlen )  -- new buffer
					interface.writebufferlen = interface.writebufferlen - byte            
					if "wantread" == err then  -- happens only with luasec
						local callback = function( )
							interface:_close()
							interface.eventwritetimeout = nil
							return evreturn, evtimeout
						end
						interface.eventwritetimeout = addevent( base, nil, EV_TIMEOUT, callback, cfg.WRITE_TIMEOUT )  -- reg a new timeout event
						debug( "wantread during write attemp, reg it in readcallback but dont know what really happens next..." )
						-- hopefully this works with luasec; its simply not possible to use 2 different write events on a socket in luaevent
						return -1
					end
					return EV_WRITE, cfg.WRITE_TIMEOUT 
				else  -- connection was closed during writing or fatal error
					interface.fatalerror = err or "fatal error"
					debug( "connection failed in write event:", interface.fatalerror ) 
					interface:_close()
					interface.eventwrite = nil
					return -1
				end
			end
		end
		local usingssl, receive = interface._usingssl, interface.receive;
		interface.readcallback = function( event )  -- called on read events
			--vdebug( "new client read event, id/ip/port:", interface, ip, port )
			if interface.noreading or interface.fatalerror then  -- leave this event
				--vdebug( "leaving this event because:", interface.noreading or interface.fatalerror )
				interface.eventread = nil
				return -1
			end
			if EV_TIMEOUT == event then  -- took too long to get some data from client -> disconnect
				interface.fatalerror = "timeout during receiving"
				debug( "connection failed:", interface.fatalerror ) 
				interface:_close()
				interface.eventread = nil
				return -1
			else -- can read
				if usingssl then  -- handle luasec
					if interface.eventwritetimeout then  -- ok, in the past writecallback was regged
						local ret = interface.writecallback( )  -- call it
						--vdebug( "tried to write in readcallback, result:", ret )
					end
					if interface.eventreadtimeout then
						interface.eventreadtimeout:close( )
						interface.eventreadtimeout = nil
					end
				end
				local buffer, err, part = receive( client, pattern )  -- receive buffer with "pattern"
				--vdebug( "read data:", buffer, "error:", err, "part:", part )        
				buffer = buffer or part or ""
				local len = string_len( buffer )
				if len > cfg.MAX_READ_LENGTH then  -- check buffer length
					interface.fatalerror = "receive buffer exceeded"
					debug( "fatal error:", interface.fatalerror )
					interface:_close()
					interface.eventread = nil
					return -1
				end
				if err and ( "timeout" ~= err ) then
					if "wantwrite" == err then -- need to read on write event
						if not interface.eventwrite then  -- register new write event if needed
							interface.eventwrite = addevent( base, interface.conn, EV_WRITE, interface.writecallback, cfg.WRITE_TIMEOUT )
						end
						interface.eventreadtimeout = addevent( base, nil, EV_TIMEOUT,
							function( )
								interface:_close()
							end, cfg.READ_TIMEOUT
						)             
						debug( "wantwrite during read attemp, reg it in writecallback but dont know what really happens next..." )
						-- to be honest i dont know what happens next, if it is allowed to first read, the write etc...
					else  -- connection was closed or fatal error            
						interface.fatalerror = err
						debug( "connection failed in read event:", interface.fatalerror ) 
						interface:_close()
						interface.eventread = nil
						return -1
					end
				end
				interface.onincoming( interface, buffer, err )  -- send new data to listener
				return EV_READ, cfg.READ_TIMEOUT
			end
		end

		client:settimeout( 0 )  -- set non blocking
		setmetatable(interface, interface_mt)
		interfacelist( "add", interface )  -- add to interfacelist
		return interface
	end
end

local handleserver
do
	function handleserver( server, addr, port, pattern, listener, sslctx, startssl )  -- creates an server interface
		debug "creating server interface..."
		local interface = {
			_connections = 0;
			
			conn = server;
			onconnect = listener.onconnect;  -- will be called when new client connected
			eventread = false;  -- read event handler
			eventclose = false; -- close event handler
			readcallback = false; -- read event callback
			fatalerror = false; -- error message
			nointerface = true;  -- lock/unlock parameter
		}
		interface.readcallback = function( event )  -- server handler, called on incoming connections
			--vdebug( "server can accept, id/addr/port:", interface, addr, port )
			if interface.fatalerror then
				--vdebug( "leaving this event because:", self.fatalerror )
				interface.eventread = nil
				return -1
			end
			local delay = cfg.ACCEPT_DELAY
			if EV_TIMEOUT == event then
				if interface._connections >= cfg.MAX_CONNECTIONS then  -- check connection count
					debug( "to many connections, seconds to wait for next accept:", delay )
					return EV_TIMEOUT, delay  -- timeout...
				else
					return EV_READ  -- accept again
				end
			end
			--vdebug("max connection check ok, accepting...")
			local client, err = server:accept()    -- try to accept; TODO: check err
			while client do
				if interface._connections >= cfg.MAX_CONNECTIONS then
					client:close( )  -- refuse connection
					debug( "maximal connections reached, refuse client connection; accept delay:", delay )
					return EV_TIMEOUT, delay  -- delay for next accept attemp
				end
				local ip, port = client:getpeername( )
				interface._connections = interface._connections + 1  -- increase connection count
				local clientinterface = handleclient( client, ip, port, interface, pattern, listener, nil, sslctx )
				--vdebug( "client id:", clientinterface, "startssl:", startssl )
				if startssl then
					clientinterface:_start_ssl( clientinterface.onconnect )
				else
					clientinterface:_start_session( clientinterface.onconnect )
				end
				debug( "accepted incoming client connection from:", ip, port )
				client, err = server:accept()    -- try to accept again
			end
			return EV_READ
		end
		
		server:settimeout( 0 )
		setmetatable(interface, interface_mt)
		interfacelist( "add", interface )
		interface:_start_session()
		return interface
	end
end

local addserver = ( function( )
	return function( addr, port, listener, pattern, backlog, sslcfg, startssl )  -- TODO: check arguments
		debug( "creating new tcp server with following parameters:", addr or "nil", port or "nil", sslcfg or "nil", startssl or "nil")
		local server, err = socket.bind( addr, port, backlog )  -- create server socket
		if not server then
			debug( "creating server socket failed because:", err )
			return nil, err
		end
		local sslctx
		if sslcfg then
			if not ssl then
				debug "fatal error: luasec not found"
				return nil, "luasec not found"
			end
			sslctx, err = ssl.newcontext( sslcfg )
			if err then
				debug( "error while creating new ssl context for server socket:", err )
				return nil, err
			end
		end      
		local interface = handleserver( server, addr, port, pattern, listener, sslctx, startssl )  -- new server handler
		debug( "new server created with id:", tostring(interface))
		return interface
	end
end )( )

local wrapclient = ( function( )
	return function( client, addr, serverport, listener, pattern, localaddr, localport, sslcfg, startssl )
		debug( "try to connect to:", addr, serverport, "with parameters:", pattern, localaddr, localport, sslcfg, startssl )
		local sslctx
		if sslcfg then  -- handle ssl/new context
			if not ssl then
				debug "need luasec, but not available" 
				return nil, "luasec not found"
			end
			sslctx, err = ssl.newcontext( sslcfg )
			if err then
				debug( "cannot create new ssl context:", err )
				return nil, err
			end
		end
	end
end )( )

local addclient = ( function( )
	return function( addr, serverport, listener, pattern, localaddr, localport, sslcfg, startssl )
		local client, err = socket.tcp()  -- creating new socket
		if not client then
			debug( "cannot create socket:", err ) 
			return nil, err
		end
		client:settimeout( 0 )  -- set nonblocking
		if localaddr then
			local res, err = client:bind( localaddr, localport, -1 )
			if not res then
				debug( "cannot bind client:", err )
				return nil, err
			end
		end
		local res, err = client:connect( addr, serverport )  -- connect
		if res or ( err == "timeout" ) then
			local ip, port = client:getsockname( )
			local server = function( )
				return nil, "this is a dummy server interface"
			end
			local interface = handleclient( client, ip, port, server, pattern, listener, sslctx )
			interface:_start_connection( startssl )
			debug( "new connection id:", interface )
			return interface, err
		else
			debug( "new connection failed:", err )
			return nil, err
		end
		return wrapclient( client, addr, serverport, listener, pattern, localaddr, localport, sslcfg, startssl )    
	end
end )( )

local loop = function( )  -- starts the event loop
	return base:loop( )
end

local newevent = ( function( )
	local add = base.addevent
	return function( ... )
		return add( base, ... )
	end
end )( )

local closeallservers = function( arg )
	for _, item in ipairs( interfacelist( ) ) do
		if item "type" == "server" then
			item( "close", arg )
		end
	end
end

return {

	cfg = cfg,
	base = base,
	loop = loop,
	event = event,
	addevent = newevent,
	addserver = addserver,
	addclient = addclient,
	wrapclient = wrapclient,
	closeallservers = closeallservers,

	__NAME = SCRIPT_NAME,
	__DATE = LAST_MODIFIED,
	__AUTHOR = SCRIPT_AUTHOR,
	__VERSION = SCRIPT_VERSION,

}
