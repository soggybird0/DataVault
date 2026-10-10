--!optimize 2

--[=[
	@class State

	Typed state node for one path under a session.

	Obtained from DataVaultServer:State /  or DataVaultClient:State.

	:::danger Type solver required
	**The new Luau type solver is required for typed `State<T>` / `Access<T>`.**

	Enable `Workspace.UseNewLuauTypeSolver = Enabled`, then annotate:

	```lua
	local S: DataVault.State<MyData> = Server:State(key)
	S.Coins.Get()
	S.Coins.Increment(50)
	S.Inventory.OnInsert(function(id, item) end)
	```

	Without the new solver, methods still run, but autocomplete will not expand
	fields or type-specific methods from your template.
	:::

	**All nodes:** Get, Set, Update, Observe, Raw, Snapshot, call sugar  
	**Numbers:** Increment, Decrement, Clamp  
	**Tables:** Has, Keys, Values, Size, Clear, Insert, Remove, OnInsert, OnRemove  
	**Arrays:** Push, Pop, InsertAt, RemoveAt, Length  
	**Root:** Mutate, Save, End, Replicate
]=]


local Util = require(script.Parent.Util)
local Types = require(script.Parent.Types)

export type Bridge = {
	GetRoot: (Key: string) -> any?,
	IsLoaded: (Key: string) -> boolean,
	WritePath: ((Key: string, Path: { any }, Value: any) -> ())?,
	MutateRoot: ((Key: string, Mutator: (Data: any) -> (), Full: boolean?) -> any?)?,
	ObservePath: (Key: string, Path: { any }, Listener: (Value: any) -> ()) -> Types.Connection,
	ObserveRoot: ((Key: string, Listener: (Data: any) -> ()) -> Types.Connection)?,
	Save: ((Key: string) -> ())?,
	End: ((Key: string) -> ())?,
	Replicate: ((Key: string, Target: Player?) -> ())?,
	ReadOnly: boolean?,
}

local METHODS: { [string]: boolean } = {
	Key = true,
	Path = true,
	Raw = true,
	Snapshot = true,
	IsLoaded = true,
	Get = true,
	Set = true,
	Update = true,
	Observe = true,
	Mutate = true,
	Increment = true,
	Decrement = true,
	Clamp = true,
	Has = true,
	Keys = true,
	Values = true,
	Size = true,
	Length = true,
	Clear = true,
	Insert = true,
	Remove = true,
	OnInsert = true,
	OnRemove = true,
	Push = true,
	Pop = true,
	InsertAt = true,
	RemoveAt = true,
	Save = true,
	End = true,
	Replicate = true,
}

local StateMT = {}
StateMT.__index = StateMT

local function node(Bridge: Bridge, Key: string, Path: { any })
	return setmetatable({
		_bridge = Bridge,
		_key = Key,
		_path = Path,
	}, StateMT)
end

local function assertWritable(self)
	if self._bridge.ReadOnly then
		error("DataVault: client state is read-only. Mutate on the server.", 3)
	end
	if not self._bridge.WritePath then
		error("DataVault: writes are not available", 3)
	end
end

local function isArrayTable(T: any): boolean
	if type(T) ~= "table" then
		return false
	end
	local N = #T
	if N == 0 then
		for K in T do
			if type(K) ~= "number" then
				return false
			end
		end
		return true
	end
	for K in T do
		if type(K) ~= "number" then
			return false
		end
	end
	return true
end

----------------------------------------------------------------
-- Core
----------------------------------------------------------------

function StateMT:Key(): string?
	return self._key
end

function StateMT:Path(): { any }
	return Util.ClonePath(self._path)
end

function StateMT:IsLoaded(): boolean
	return self._bridge.IsLoaded(self._key)
end

function StateMT:Raw(): any
	local Root = self._bridge.GetRoot(self._key)
	if Root == nil then
		return nil
	end
	if #self._path == 0 then
		return Root
	end
	return Util.GetAt(Root, self._path)
end

function StateMT:Snapshot(): any
	local Value = self:Raw()
	if Value == nil then
		return nil
	end
	return Util.DeepCopy(Value)
end

function StateMT:Get(): any
	return self:Raw()
end

StateMT.__call = function(self, ...: any): any
	local N = select("#", ...)
	if N == 0 then
		return self:Raw()
	end
	return self:Set(...)
end

function StateMT:Set(Value: any): any
	assertWritable(self)
	if #self._path == 0 then
		if self._bridge.MutateRoot then
			self._bridge.MutateRoot(self._key, function(Data)
				if type(Value) == "table" and type(Data) == "table" then
					table.clear(Data)
					for K, V in Value do
						Data[K] = if type(V) == "table" then Util.DeepCopy(V) else V
					end
				end
			end, true)
		end
		return self:Raw()
	end
	self._bridge.WritePath(self._key, self._path, Value)
	return self:Raw()
end

function StateMT:Update(Updater: (Current: any) -> any): any
	return self:Set(Updater(self:Raw()))
end

function StateMT:Observe(Listener: (Value: any) -> ()): Types.Connection
	if #self._path == 0 and self._bridge.ObserveRoot then
		return self._bridge.ObserveRoot(self._key, Listener)
	end
	return self._bridge.ObservePath(self._key, self._path, Listener)
end

function StateMT:Mutate(Mutator: (Data: any) -> (), Opts: Types.MutateOptions?): any
	assertWritable(self)
	if not self._bridge.MutateRoot then
		error("DataVault: mutate is not available", 2)
	end
	if #self._path == 0 then
		return self._bridge.MutateRoot(self._key, Mutator, Opts ~= nil and Opts.Full == true)
	end
	return self._bridge.MutateRoot(self._key, function(Root)
		local Target = Util.GetAt(Root, self._path)
		if type(Target) ~= "table" then
			error("DataVault: Mutate on a non-table path", 2)
		end
		Mutator(Target)
	end, Opts ~= nil and Opts.Full == true)
end

----------------------------------------------------------------
-- Numbers
----------------------------------------------------------------

function StateMT:Increment(Amount: number): number?
	local Current = self:Raw()
	local Number = if type(Current) == "number" then Current else 0
	self:Set(Number + Amount)
	local After = self:Raw()
	return if type(After) == "number" then After else nil
end

function StateMT:Decrement(Amount: number): number?
	return self:Increment(-(Amount or 1))
end

function StateMT:Clamp(Min: number, Max: number): number?
	local Current = self:Raw()
	local Number = if type(Current) == "number" then Current else 0
	self:Set(math.clamp(Number, Min, Max))
	local After = self:Raw()
	return if type(After) == "number" then After else nil
end

----------------------------------------------------------------
-- Tables
----------------------------------------------------------------

function StateMT:Has(ChildKey: any): boolean
	local Value = self:Raw()
	if type(Value) ~= "table" then
		return false
	end
	return Value[ChildKey] ~= nil
end

function StateMT:Keys(): { any }
	local Value = self:Raw()
	if type(Value) ~= "table" then
		return {}
	end
	local Out = {}
	for K in Value do
		table.insert(Out, K)
	end
	return Out
end

function StateMT:Values(): { any }
	local Value = self:Raw()
	if type(Value) ~= "table" then
		return {}
	end
	local Out = {}
	for _, V in Value do
		table.insert(Out, V)
	end
	return Out
end

function StateMT:Size(): number
	local Value = self:Raw()
	if type(Value) ~= "table" then
		return 0
	end
	local N = 0
	for _ in Value do
		N += 1
	end
	return N
end

function StateMT:Length(): number
	local Value = self:Raw()
	if type(Value) ~= "table" then
		return 0
	end
	return #Value
end

function StateMT:Clear()
	assertWritable(self)
	local Value = self:Raw()
	if type(Value) ~= "table" then
		self:Set({})
		return
	end
	self:Mutate(function(T)
		table.clear(T)
	end)
end

function StateMT:Insert(ChildKey: any, ChildValue: any)
	assertWritable(self)
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: Insert on non-table", 2)
		end
		T[ChildKey] = if type(ChildValue) == "table" then Util.DeepCopy(ChildValue) else ChildValue
	end)
end

function StateMT:Remove(ChildKey: any): any
	assertWritable(self)
	local Removed = nil
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: Remove on non-table", 2)
		end
		Removed = T[ChildKey]
		T[ChildKey] = nil
	end)
	return Removed
end

-- Membership observers: fire when keys appear / disappear under this table path
function StateMT:OnInsert(Listener: (Key: any, Value: any) -> ()): Types.Connection
	local LastKeys: { [any]: any } = {}
	local Current = self:Raw()
	if type(Current) == "table" then
		for K, V in Current do
			LastKeys[K] = true
		end
	end

	return self:Observe(function(Value)
		if type(Value) ~= "table" then
			return
		end
		local Seen: { [any]: boolean } = {}
		for K, V in Value do
			Seen[K] = true
			if not LastKeys[K] then
				Listener(K, V)
			end
		end
		table.clear(LastKeys)
		for K in Seen do
			LastKeys[K] = true
		end
	end)
end

function StateMT:OnRemove(Listener: (Key: any, OldValue: any?) -> ()): Types.Connection
	local Last: { [any]: any } = {}
	local Current = self:Raw()
	if type(Current) == "table" then
		for K, V in Current do
			Last[K] = if type(V) == "table" then Util.DeepCopy(V) else V
		end
	end

	return self:Observe(function(Value)
		if type(Value) ~= "table" then
			-- entire table replaced with non-table → everything removed
			for K, Old in Last do
				Listener(K, Old)
			end
			table.clear(Last)
			return
		end
		for K, Old in Last do
			if Value[K] == nil then
				Listener(K, Old)
			end
		end
		table.clear(Last)
		for K, V in Value do
			Last[K] = if type(V) == "table" then Util.DeepCopy(V) else V
		end
	end)
end

----------------------------------------------------------------
-- Arrays
----------------------------------------------------------------

function StateMT:Push(...: any): number?
	assertWritable(self)
	local Args = { ... }
	local NewLen = nil
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: Push on non-table", 2)
		end
		for _, V in Args do
			table.insert(T, if type(V) == "table" then Util.DeepCopy(V) else V)
		end
		NewLen = #T
	end)
	return NewLen
end

function StateMT:Pop(): any
	assertWritable(self)
	local Removed = nil
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: Pop on non-table", 2)
		end
		Removed = table.remove(T)
	end)
	return Removed
end

function StateMT:InsertAt(Index: number, Value: any)
	assertWritable(self)
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: InsertAt on non-table", 2)
		end
		table.insert(T, Index, if type(Value) == "table" then Util.DeepCopy(Value) else Value)
	end)
end

function StateMT:RemoveAt(Index: number): any
	assertWritable(self)
	local Removed = nil
	self:Mutate(function(T)
		if type(T) ~= "table" then
			error("DataVault: RemoveAt on non-table", 2)
		end
		Removed = table.remove(T, Index)
	end)
	return Removed
end

----------------------------------------------------------------
-- Session (root)
----------------------------------------------------------------

function StateMT:Save()
	if self._bridge.Save then
		self._bridge.Save(self._key)
	end
end

function StateMT:End()
	if self._bridge.End then
		self._bridge.End(self._key)
	end
end

function StateMT:Replicate(Target: Player?)
	if self._bridge.Replicate then
		self._bridge.Replicate(self._key, Target)
	end
end

----------------------------------------------------------------
-- Index / newindex
----------------------------------------------------------------

function StateMT:__index(Key: any)
	local Method = rawget(StateMT, Key)
	if Method ~= nil then
		return Method
	end
	if METHODS[Key] then
		return rawget(StateMT, Key)
	end
	local ChildPath = Util.ClonePath(self._path)
	table.insert(ChildPath, Key)
	return node(self._bridge, self._key, ChildPath)
end

function StateMT:__newindex(Key: any, Value: any)
	assertWritable(self)
	local ChildPath = Util.ClonePath(self._path)
	table.insert(ChildPath, Key)
	self._bridge.WritePath(self._key, ChildPath, Value)
end

function StateMT:__tostring()
	local Parts = {}
	for I, S in self._path do
		Parts[I] = tostring(S)
	end
	local Suffix = if #Parts == 0 then "" else "." .. table.concat(Parts, ".")
	return ("DataVaultState<%s>%s"):format(tostring(self._key), Suffix)
end

local State = {}

function State.new(Bridge: Bridge, Key: string, Path: { any }?): Types.State<any>
	return node(Bridge, Key, Path or {}) :: any
end

return State
