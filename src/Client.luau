--!optimize 2

--[=[
	@class DataVaultClient

	Client replica of a DataVault store. Same State surface as the server, but
	writes error (mutate on the server only).

	:::danger Type solver required for typed State
	**Typed `State<T>` / `Access<T>` requires the new Luau type solver.**

	```lua
	type MyData = typeof(Template)
	
	local Client = SharedVault.Client
	Client:Wait()

	local S = Client:Explicit()
	print(S.Coins.Get())
	```

	Enable `Workspace.UseNewLuauTypeSolver = Enabled` or typed fields will not autocomplete.
	:::
]=]


local Remote = require(script.Parent.Libraries.Remote)
local Signal = require(script.Parent.Libraries.Signal)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local State = require(script.Parent.State)

type PathObserver = { Path: Types.Path, Signal: any }

local ReplicaEvent = Remote.event("DataVault_Replicate")
local ReplicaRequest = Remote.event("DataVault_Request")

local Clients: { [string]: any } = {}
local Listening = false

local function Publish(Client: any, Raw: any)
	Client.Raw = Raw
	if Client.Guard then
		Client.Data = Util.ReadOnly(Raw, "DataVault: client data is read-only. Change it on the server.")
	else
		Client.Data = Raw
	end
end

local function ApplyPatches(Root: any, Patches: { Types.ReplicaPatch }): any
	local Working = Util.Unwrap(Root)
	if type(Working) ~= "table" then
		Working = {}
	end
	for _, Patch in Patches do
		if type(Patch) ~= "table" or type(Patch.Path) ~= "table" then
			continue
		end
		if #Patch.Path == 0 then
			Working = if type(Patch.Value) == "table" then Util.DeepCopy(Patch.Value) else Patch.Value
			if type(Working) ~= "table" then
				Working = {}
			end
		else
			Util.SetAt(Working, Patch.Path, if type(Patch.Value) == "table" then Util.DeepCopy(Patch.Value) else Patch.Value)
		end
	end
	return Working
end

local function NotifyPathObservers(Client: any, Patches: any?, Full: boolean)
	if not Client.PathObservers then
		return
	end
	local Source = Client.Raw
	if Source == nil then
		return
	end
	for _, Entry in Client.PathObservers do
		local ShouldFire = Full
		if not ShouldFire and Patches then
			for _, Patch in Patches do
				if Util.PathStartsWith(Patch.Path, Entry.Path) or Util.PathStartsWith(Entry.Path, Patch.Path) then
					ShouldFire = true
					break
				end
			end
		end
		if ShouldFire then
			Entry.Signal:Fire(Util.GetAt(Source, Entry.Path))
		end
	end
end

local function HandlePayload(Client: any, Payload: any)
	local Decoded = Payload
	if typeof(Payload.Buffer) == "buffer" then
		Decoded = Util.DecodeReplica(Payload.Buffer)
	end
	if type(Decoded.Seq) ~= "number" then
		return
	end
	if Decoded.Seq <= Client.Seq then
		return
	end

	if Decoded.Kind == "Patch" then
		if Client.Raw == nil or Decoded.Seq ~= Client.Seq + 1 then
			Client:RequestSync()
			return
		end
		if type(Decoded.Patches) ~= "table" then
			return
		end
		Client.Key = Decoded.Key
		Client.Seq = Decoded.Seq
		Publish(Client, ApplyPatches(Client.Raw, Decoded.Patches))
		Client.Changed:Fire(Client.Data)
		NotifyPathObservers(Client, Decoded.Patches, false)
		return
	end

	if Decoded.Kind ~= "Full" or Decoded.Data == nil then
		return
	end
	Client.Key = Decoded.Key
	Client.Seq = Decoded.Seq
	Publish(Client, Util.DeepCopy(Decoded.Data))
	Client.Changed:Fire(Client.Data)
	NotifyPathObservers(Client, nil, true)
end

local function EnsureListener()
	if Listening then
		return
	end
	Listening = true
	ReplicaEvent.OnClientEvent:Connect(function(Payload)
		if type(Payload) ~= "table" or type(Payload.StoreName) ~= "string" then
			return
		end
		local Client = Clients[Payload.StoreName]
		if Client then
			HandlePayload(Client, Payload)
		end
	end)
end

local DataVaultClient = {}

--[=[
	Opens (or returns) the client replica for Options.StoreName.

	:::danger Type solver required
	**Typed State requires the new Luau type solver.** Annotate after load:

	```lua
	local S: DataVault.State<MyData> = Client:Explicit()
	```
	:::

	@within DataVaultClient
	@param Options Types.Config<T>
	@return DataVaultClient
]=]
function DataVaultClient.Open<T>(Options: Types.Config<T>)
	local Existing = Clients[Options.StoreName]
	if Existing then
		return Existing :: DataVaultClient
	end

	EnsureListener()

	local Client = {
		Data = nil :: T?,
		Key = nil :: string?,
		Seq = 0,
		Changed = Signal.new(),
		Ready = Signal.new(),
		PathObservers = {} :: { [string]: PathObserver },
		HasFiredReady = false,
		Raw = nil :: T?,
		Guard = Options.ClientGuard ~= "Off",
		StoreName = Options.StoreName,
	}

	local function ObservePath(Key: string, Path: { any }, Listener: (Value: any) -> ())
		local PK = Util.PathKey(Path)
		local Entry = Client.PathObservers[PK]
		if not Entry then
			Entry = { Path = Util.ClonePath(Path), Signal = Signal.new() }
			Client.PathObservers[PK] = Entry
		end
		local Connection = Entry.Signal:Connect(Listener)
		if Client.Raw ~= nil then
			task.defer(Listener, Util.GetAt(Client.Raw, Path))
		end
		return Connection
	end

	local function ObserveRoot(_Key: string, Listener: (Data: any) -> ())
		local Connection = Client.Changed:Connect(Listener)
		if Client.Data ~= nil then
			task.defer(Listener, Client.Data)
		end
		return Connection
	end

	local Bridge = {
		GetRoot = function(_K: string)
			return Client.Raw
		end,
		IsLoaded = function(_K: string)
			return Client.Raw ~= nil
		end,
		WritePath = nil,
		MutateRoot = nil,
		ObservePath = ObservePath,
		ObserveRoot = ObserveRoot,
		Save = nil,
		End = nil,
		Replicate = nil,
		ReadOnly = true,
	}

--[=[
	Typed state tree for the local replica.

	:::danger Type solver required
	**Annotate:** `local S: DataVault.State<MyData> = Client:Explicit()`
	:::

	@within DataVaultClient
	@return State<T>
]=]
	function Client:Explicit(): Types.State<T>
		-- Client has a single replica; key is whatever server sent
		return State.new(Bridge, Client.Key or Options.StoreName, {}) :: any
	end

--[=[
	Current replicated data (read-only when ClientGuard is on).

	@within DataVaultClient
	@return T?
]=]
	function Client:Get(): T?
		return self.Data
	end

	--[=[
		Whether the initial full replica has arrived.

		@within DataVaultClient
		@return boolean
	]=]
	function Client:IsReady(): boolean
		return self.Raw ~= nil
	end

--[=[
	Yields until data is ready (or timeout → nil).

	@within DataVaultClient
	@param Timeout number?
	@return T?
]=]
	function Client:Wait(Timeout: number?): T?
		if self.Data ~= nil then
			return self.Data
		end
		if Timeout == nil then
			return self.Changed:Wait()
		end
		local Thread = coroutine.running()
		local Settled = false
		local Connection = self.Changed:Once(function(Data)
			if Settled then
				return
			end
			Settled = true
			task.spawn(Thread, Data)
		end)
		task.delay(Timeout, function()
			if Settled then
				return
			end
			Settled = true
			Connection:Disconnect()
			task.spawn(Thread, nil)
		end)
		return coroutine.yield()
	end

--[=[
	Requests a full sync from the server (usually automatic).

	@within DataVaultClient
]=]
	function Client:RequestSync()
		ReplicaRequest:FireServer({ StoreName = Options.StoreName })
	end

--[=[
	Observes the full replica root.

	@within DataVaultClient
	@param Listener (Data: T) -> ()
	@return Connection
]=]
	function Client:Observe(Listener: (Data: T) -> ())
		return ObserveRoot("", Listener)
	end

	Client.Changed:Connect(function(Data)
		if Client.HasFiredReady then
			return
		end
		Client.HasFiredReady = true
		Client.Ready:Fire(Data)
	end)

	Clients[Options.StoreName] = Client
	task.defer(function()
		if Client.Raw == nil then
			Client:RequestSync()
		end
	end)

	export type DataVaultClient = typeof(Client)

	return Client
end

return DataVaultClient
