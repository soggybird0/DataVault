--!optimize 2

--// Dependencies

local Remote = require(script.Parent.Libraries.Remote)
local Signal = require(script.Parent.Libraries.Signal)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

--// Types

type PathObserver<T> = {
	Path: Types.Path,
	Signal: Types.Signal<T>,
}

--// Variables

local ReplicaEvent = Remote.event("DataVault_Replicate") :: Remote.Event<Types.ReplicaPayload<any>>
local ReplicaRequest = Remote.event("DataVault_Request") :: Remote.Event<Types.ReplicaRequest>

local CLIENT_WRITE_ERROR = "DataVault: client data is read-only. Change it on the server."

local Clients: { [string]: any } = {}
local Listening = false

--// Functions

local function IsReplicaPayload(Value: any): boolean
	if type(Value) ~= "table" then
		return false
	end
	if type(Value.StoreName) ~= "string" or type(Value.Key) ~= "string" then
		return false
	end
	if type(Value.Seq) ~= "number" then
		return false
	end
	if Value.Kind ~= "Full" and Value.Kind ~= "Patch" then
		return false
	end
	return true
end

local function Publish(Client: any, Raw: any)
	Client.Raw = Raw
	if Client.Guard then
		Client.Data = Util.ReadOnly(Raw, CLIENT_WRITE_ERROR)
	else
		Client.Data = Raw
	end
end

local function GuardedValue(Client: any, Value: any): any
	if Client.Guard and type(Value) == "table" then
		return Util.ReadOnly(Util.Unwrap(Value), CLIENT_WRITE_ERROR)
	end
	return Value
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
			local Copied = if type(Patch.Value) == "table" then Util.DeepCopy(Patch.Value) else Patch.Value
			Util.SetAt(Working, Patch.Path, Copied)
		end
	end

	return Working
end

local function NotifyPathObservers(Client: any, Patches: { Types.ReplicaPatch }?, Full: boolean)
	if not Client.PathObservers then
		return
	end

	local Source = Client.Raw or Client.Data
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
			Entry.Signal:Fire(GuardedValue(Client, Util.GetAt(Source, Entry.Path)))
		end
	end
end

local function EnsureListener()
	if Listening then
		return
	end
	Listening = true

	ReplicaEvent.OnClientEvent:Connect(function(Payload)
		if not IsReplicaPayload(Payload) then
			return
		end

		local Client = Clients[Payload.StoreName]
		if not Client then
			return
		end

		if Payload.Seq <= Client.Seq then
			return
		end

		if Payload.Kind == "Patch" then
			if Client.Raw == nil or Payload.Seq ~= Client.Seq + 1 then
				Client:RequestSync()
				return
			end
			if type(Payload.Patches) ~= "table" then
				return
			end

			Client.Key = Payload.Key
			Client.Seq = Payload.Seq
			Publish(Client, ApplyPatches(Client.Raw, Payload.Patches))
			Client.Changed:Fire(Client.Data)
			NotifyPathObservers(Client, Payload.Patches, false)
			return
		end

		if Payload.Data == nil then
			return
		end

		Client.Key = Payload.Key
		Client.Seq = Payload.Seq
		Publish(Client, Util.DeepCopy(Payload.Data))
		Client.Changed:Fire(Client.Data)
		NotifyPathObservers(Client, nil, true)
	end)
end

--// Class

local DataVaultClient = {}

function DataVaultClient.Open<T>(Options: Types.Config<T>):
	{
		Data: T?,
		Key: string?,
		Seq: number,
		Changed: Signal.Signal<T>,
		Ready: Signal.Signal<T>,
	} & {
		PathObservers: { [string]: PathObserver<T> },
		HasFiredReady: boolean,
		Raw: T?,
		Guard: boolean,
	} & {
		Get: (self: any) -> T?,
		GetKey: (self: any) -> string?,
		GetAt: (self: any, Path: { any } ) -> any,
		IsReady: (self: any) -> boolean,
		Observe: (self: any, Listener: (Data: T) -> ()) -> any,
		ObservePath: (self: any, Path: { any }, Listener: (Value: any) -> ()) -> any,
		Wait: (self: any, Timeout: number?) -> T?,
		RequestSync: (self: any) -> (),
	}
	
	local Existing = Clients[Options.StoreName]
	if Existing then
		return Existing
	end

	EnsureListener()

	local Client = {
		Data = nil :: T?,
		Key = nil :: string?,
		Seq = 0,
		Changed = Signal.new() :: Signal.Signal<T>,
		Ready = Signal.new() :: Signal.Signal<T>,
		PathObservers = {} :: { [string]: PathObserver<T> },
		HasFiredReady = false,
		Raw = nil :: T?,
		Guard = Options.ClientGuard ~= "Off",
	}

	function Client:Get(): T?
		return self.Data
	end

	function Client:GetKey(): string?
		return self.Key
	end

	function Client:Snapshot(): T?
		if self.Raw == nil then
			return nil
		end
		return Util.DeepCopy(self.Raw)
	end

	function Client:GetAt(Path: Types.Path | string): any
		if self.Raw == nil then
			return nil
		end
		return GuardedValue(self, Util.GetAt(self.Raw, Util.NormalizePath(Path)))
	end

	function Client:HasPath(Path: Types.Path | string): boolean
		if self.Raw == nil then
			return false
		end
		return Util.HasAt(self.Raw, Util.NormalizePath(Path))
	end

	function Client:IsReady(): boolean
		return self.Raw ~= nil
	end

	function Client:Observe(Listener: (Data: T) -> ())
		local Connection = self.Changed:Connect(Listener)
		if self.Data ~= nil then
			local Snapshot = self.Data
			task.defer(Listener, Snapshot)
		end
		return Connection
	end

	function Client:ObservePath(Path: Types.Path | string, Listener: (Value: any) -> ())
		local Normalized = Util.NormalizePath(Path)
		local Key = Util.PathKey(Normalized)
		local Entry = self.PathObservers[Key]
		if not Entry then
			Entry = {
				Path = Util.ClonePath(Normalized),
				Signal = Signal.new(),
			}
			self.PathObservers[Key] = Entry
		end

		local Connection = Entry.Signal:Connect(Listener)
		if self.Raw ~= nil then
			local Snapshot = GuardedValue(self, Util.GetAt(self.Raw, Normalized))
			task.defer(Listener, Snapshot)
		end
		return Connection
	end

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

	function Client:RequestSync()
		ReplicaRequest:FireServer({
			StoreName = Options.StoreName,
		})
	end

	Client.Changed:Connect(function(Data)
		if Client.HasFiredReady then
			return
		end
		Client.HasFiredReady = true
		Client.Ready:Fire(Data)
	end)

	Clients[Options.StoreName] = Client :: any

	task.defer(function()
		if Client.Raw == nil then
			Client:RequestSync()
		end
	end)

	return Client
end

return DataVaultClient
