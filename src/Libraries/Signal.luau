--!optimize 2
--[=[
	Tiny yield-safe signal.
	Same idea/form as stravant/sleitnick, fewer extras.
]=]

--// Types

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Fire: (self: Signal<T...>, T...) -> (),
	Connect: (self: Signal<T...>, Listener: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, Listener: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

--// Variables

local freeRunnerThread: thread? = nil

--// Functions

local function acquireRunnerAndCall(fn: (...any) -> (), ...: any)
	local acquired = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquired
end

local function runner(...: any)
	acquireRunnerAndCall(...)
	while true do
		acquireRunnerAndCall(coroutine.yield())
	end
end

--// Class

local Connection = {}
Connection.__index = Connection

function Connection.new(signal: any, listener: (...any) -> ()): Connection
	local self = setmetatable({
		Connected = true,
		_signal = signal,
		_listener = listener,
		_next = nil :: any,
	}, Connection)
	return self :: any
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

function Connection:Destroy()
	self:Disconnect()
end

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_head = nil :: any,
	}, Signal)
	return self :: any
end

function Signal:Connect(listener)
	local connection = Connection.new(self, listener)
	connection._next = self._head
	self._head = connection
	return connection
end

function Signal:Once(listener)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		listener(...)
	end)
	return connection
end

function Signal:Fire(...)
	local item = self._head
	while item do
		if item.Connected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runner)
			end
			task.spawn(freeRunnerThread :: thread, item._listener, ...)
		end
		item = item._next
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	local item = self._head
	self._head = nil
	while item do
		item.Connected = false
		item = item._next
	end
end

function Signal:Destroy()
	self:DisconnectAll()
end

return Signal
