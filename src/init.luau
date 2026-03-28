--!optimize 2
--!strict

--[[

           +++                                                                                      
       ++++++++   ===                                                                               
    ++++++++++   ====                                                  ====                         
     ++++++                                                            ====                         
       +++++     ====     ====== =====  ==== =======      ========     ====        ====             
        +++++    ====    =============  =============    ===========   ====        ====             
         ++++    ====   ====     =====  =====    ====           ====   ====        ====             
         ++++    ====   ====     =====  =====    ====     ==========   ====    =============        
         ++++    ====   ====     =====  =====    ====   ======  ====   ====    =============        
       ++++++    ====   =====   ======  =====    ====  ====     ====   ====        ====    +++++++++
   ++++++++++    ====    =============  =====    ====   ============   ====   ++++ ==== ++++++++++++
  +++++++        ====            =====  ====     ====   + ====  ====   ==== ++++++++  ++++++++      
 +++++                  ==== +++ ==== +++++++++++++++++++++++++++++++++++++++++++++++++++++         
 ++++        +++++++++++ =========== +++++++++++++++++++++++++++++++++++++++      ++++++            
+++++++++++++++++++++++++++                                                         +               
 +++++++++++++++++++++++++                                                                          
      +++++                                                                                         

v3.7.2

An exceptionally fast, lightweight, and elegant open-source signal
library for Luau - with generic types and detailed documentation.


GitHub (repository):
https://github.com/AlexanderLindholt/SignalPlus

GitBook (documentation):
https://alexxander.gitbook.io/SignalPlus

DevForum (topic):
https://devforum.roblox.com/t/3552231


--------------------------------------------------------------------------------
MIT License

Copyright (c) 2025 Alexander Lindholt

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--------------------------------------------------------------------------------

]]
--

-- Types.
export type Connection = {
	Signal: Signal,
	Previous: Connection?,
	Next: Connection?,
	Callback: (...any) -> (),
	Connected: boolean,
	Disconnect: (connection: Connection) -> (),
}
export type Signal = {
	Connect: (signal: Signal, callback: (...any) -> ()) -> Connection,
	Once: (signal: Signal, callback: (...any) -> ()) -> Connection,
	Wait: (signal: Signal) -> ...any,
	Fire: (signal: Signal, ...any) -> (),
	DisconnectAll: (signal: Signal) -> (),
	Destroy: (signal: Signal) -> (),
	Head: Connection?,
	Tail: Connection?,
	__index: Signal,
}

type CreateSignal = () -> Signal

-- Spawn function.
local spawnThread
if script:GetAttribute("Deferred") then
	spawnThread = task.defer
else
	spawnThread = task.spawn
end

-- Setup reusable callback threads.
local threads = {}

local function reusableThreadCall(callback, thread, ...)
	callback(...)
	table.insert(threads, thread)
end
local function reusableThread()
	while true do
		reusableThreadCall(coroutine.yield())
	end
end

local function sendToThread(thread, callback, ...)
	local args = table.pack(...)
	spawnThread(function()
		coroutine.resume(thread, callback, thread, table.unpack(args, 1, args.n))
	end)
end

-- Connection methods.
local function disconnect(connection)
	-- Verify connection.
	if not connection.Connected then
		return
	end

	-- Remove connection.
	connection.Connected = false

	local signal = connection.Signal
	local previous = connection.Previous
	local next = connection.Next
	if previous then
		previous.Next = next
	else
		signal.Tail = next
	end
	if next then
		next.Previous = previous
	else
		signal.Head = previous
	end
end

-- Signal methods.
local Signal = {} :: Signal
Signal.__index = Signal

Signal.Connect = function(signal, callback)
	-- Linked list head.
	local head = signal.Head

	-- Create connection.
	local connection: Connection = {
		Signal = signal,
		Previous = head,
		Next = nil,

		Callback = callback,

		Connected = true,
		Disconnect = disconnect,
	}

	-- Add connection.
	if head then
		head.Next = connection
	else
		signal.Tail = connection
	end
	signal.Head = connection

	-- Return connection.
	return connection
end
Signal.Once = function(signal, callback)
	-- Linked list head.
	local head = signal.Head

	-- Create connection.
	local connection: Connection
	connection = {
		Signal = signal,
		Previous = head,
		Next = nil,

		Callback = function(...)
			-- Verify connection.
			if not connection.Connected then
				return
			end

			-- Remove connection.
			connection.Connected = false

			local previous = connection.Previous
			local next = connection.Next
			if previous then
				previous.Next = next
			else
				signal.Tail = next
			end
			if next then
				next.Previous = previous
			else
				signal.Head = previous
			end

			-- Fire callback.
			callback(...)
		end,

		Connected = true,
		Disconnect = disconnect,
	}

	-- Add connection.
	if head then
		head.Next = connection
	else
		signal.Tail = connection
	end
	signal.Head = connection

	-- Return connection.
	return connection
end
Signal.Wait = function(signal)
	-- Save this thread to resume later.
	local thread = coroutine.running()

	-- Linked list head.
	local head = signal.Head

	-- Create connection.
	local connection: Connection
	connection = {
		Signal = signal,
		Previous = head,
		Next = nil,
		Connected = true,
		Disconnect = disconnect,

		Callback = function(...)
			-- Remove connection.
			connection.Connected = false

			local previous = connection.Previous
			local next = connection.Next
			if previous then
				previous.Next = next
			else
				signal.Tail = next
			end
			if next then
				next.Previous = previous
			else
				signal.Head = previous
			end

			-- Resume the thread.
			if coroutine.status(thread) == "suspended" then -- To avoid creating new threads.
				task.spawn(thread, ...)
			end
		end,
	}

	-- Add connection.
	if head then
		head.Next = connection
	else
		signal.Tail = connection
	end
	signal.Head = connection

	-- Yield until the next fire, then return the arguments on resume.
	return coroutine.yield()
end

Signal.Fire = function(signal, ...)
	local connection: Connection? = signal.Tail -- Start from the tail (back) of the list.
	while connection do
		-- Find or create a thread, then run the callback in it.
		local length = #threads
		if length == 0 then
			local thread = coroutine.create(reusableThread)
			coroutine.resume(thread) -- Initialize.
			sendToThread(thread, connection.Callback, ...)
		else
			local thread = threads[length]
			threads[length] = nil -- Remove from free threads list.
			sendToThread(thread, connection.Callback, ...)
		end
		-- Traverse.
		connection = connection.Next
	end
end

Signal.DisconnectAll = function(signal)
	-- Remove all connections.
	local connection: Connection? = signal.Tail
	while connection do
		-- Save next connection.
		local nextConnection = connection.Next
		-- Remove data and pointers.
		connection.Connected = false
		connection.Next = nil
		connection.Previous = nil
		-- Traverse.
		connection = nextConnection
	end
	-- Remove signal's references.
	signal.Tail = nil
	signal.Head = nil
end
Signal.Destroy = function(signal)
	-- Remove all connections.
	local connection: Connection? = signal.Tail
	while connection do
		-- Save next connection.
		local nextConnection = connection.Next
		-- Remove data and pointers.
		connection.Connected = false
		connection.Next = nil
		connection.Previous = nil
		-- Traverse.
		connection = nextConnection
	end
	-- Remove signal's references.
	signal.Tail = nil
	signal.Head = nil

	-- Unlink signal methods.
	setmetatable(signal, nil)
end

-- Signal creation function.
return function()
	return setmetatable({}, Signal) -- New blank table linked to the signal methods.
end
