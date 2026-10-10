--!strict

--[=[
	@class Types
	@ignore

	Shared type contracts for DataVault.

	:::danger Type solver required for Access / State
	**The new Luau type solver is required for typed `Access<T>` and `State<T>`.**

	Enable `Workspace.UseNewLuauTypeSolver = Enabled` (Studio) or the Luau LSP
	equivalent. Then annotate loaded state:

	```lua
	type MyData = typeof(Template)
	local S: DataVault.State<MyData> = Server:Explicit(key)
	```

	Without it, runtime is fine; field/method autocomplete will not expand from the template.
	:::
]=]


export type JSONAcceptable =
	{ JSONAcceptable }
	| { [string]: JSONAcceptable }
	| number
	| string
	| boolean
	| buffer

export type Fn<T...> = (T...) -> ()
export type Path = { any }

export type SessionParams = {
	Steal: boolean?,
	Cancel: (() -> boolean)?,
}

export type MutateContext<T> = {
	Key: string,
	Player: Player?,
	Data: T,
}

export type LoadFailureReason =
	"Destroyed"
	| "Cancelled"
	| "NilProfile"
	| "PlayerLeft"

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, Listener: Fn<T...>) -> Connection,
	Once: (self: Signal<T...>, Listener: Fn<T...>) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

export type ReplicateMode = "Diff" | "Full" | "Hybrid"
export type ClientGuard = "Proxy" | "Off"

export type MutateOptions = {
	Full: boolean?,
}

export type Config<T> = {
	StoreName: string,
	Template: T,

	KeyPrefix: string?,
	PlayerKey: ((Player) -> string)?,

	Mock: boolean?,

	BindPlayers: boolean?,
	KickOnFail: boolean?,
	KickOnSessionEnd: boolean?,
	KickMessage: string?,
	LoadTimeout: number?,

	SchemaVersion: number?,
	Migrate: ((Data: T, FromVersion: number, ToVersion: number) -> ())?,

	AutoSaveSeconds: number?,

	ReplicateMode: ReplicateMode?,
	MaxPatchesBeforeFull: number?,
	CollapsePatchesAt: number?,
	FlushImmediately: boolean?,
	ReplicateOnSave: boolean?,
	ClientGuard: ClientGuard?,

	BeforeMutate: ((Context: MutateContext<T>) -> ())?,
	AfterMutate: ((Context: MutateContext<T>) -> ())?,
	OnMessage: ((Key: string, Message: JSONAcceptable, Processed: () -> ()) -> ())?,
}

export type Profile<T> = {
	Data: T,
	RobloxMetaData: JSONAcceptable,
	UserIds: { number },
	Key: string,
	OnSessionEnd: Signal<>,
	IsActive: (self: Profile<T>) -> boolean,
	Reconcile: Fn<any>,
	EndSession: Fn<any>,
	AddUserId: (self: Profile<T>, UserId: number) -> (),
	MessageHandler: (
		self: Profile<T>,
		Fn: (Message: JSONAcceptable, Processed: () -> ()) -> ()
	) -> (),
	Save: Fn<any>,
}

export type ReplicaPatch = {
	Path: Path,
	Value: any,
}

----------------------------------------------------------------
-- Access<T>: recursive type function (Scribe-style autocomplete)
-- types.newfunction params/returns use { head = {type}, tail = type? }
----------------------------------------------------------------

type function Access(t: type)
	local function fn(paramHead: { type }?, returnHead: { type }?): type
		local f = types.newfunction()
		if paramHead then
			f:setparameters(paramHead)
		end
		if returnHead then
			f:setreturns(returnHead)
		end
		return f
	end

	local function leaf(valueType: type, withNumber: boolean?): type
		local node = types.newtable()
		node:setproperty(types.singleton("Get"), fn({}, { valueType }))
		node:setproperty(types.singleton("Set"), fn({ valueType }, { valueType }))
		node:setproperty(
			types.singleton("Update"),
			fn({ fn({ valueType }, { valueType }) }, { valueType })
		)
		node:setproperty(
			types.singleton("Observe"),
			fn({ fn({ valueType }, nil) }, { types.any })
		)
		if withNumber then
			node:setproperty(types.singleton("Increment"), fn({ types.number }, { valueType }))
			node:setproperty(types.singleton("Decrement"), fn({ types.number }, { valueType }))
			node:setproperty(
				types.singleton("Clamp"),
				fn({ types.number, types.number }, { valueType })
			)
		end
		return node
	end

	if t:is("number") then
		return leaf(types.number, true)
	elseif t:is("boolean") then
		return leaf(types.boolean, false)
	elseif t:is("string") then
		return leaf(types.string, false)
	elseif t:is("buffer") then
		return leaf(types.buffer, false)
	end

	if t:is("singleton") then
		local v = (t :: any):value()
		if type(v) == "boolean" then
			return leaf(types.boolean, false)
		elseif type(v) == "string" then
			return leaf(types.string, false)
		end
	end

	if t:is("table") then
		local node = types.newtable()
		local optT = types.optional(types.copy(t))
		local T = types.copy(t)
		local anyT = types.any

		for key, prop in t:properties() do
			local valueType = prop.read or prop.write
			if valueType then
				node:setproperty(key, Access(valueType))
			end
		end

		node:setproperty(types.singleton("Get"), fn({}, { optT }))
		node:setproperty(types.singleton("Set"), fn({ T }, { T }))
		node:setproperty(types.singleton("Update"), fn({ fn({ T }, { T }) }, { T }))
		node:setproperty(types.singleton("Observe"), fn({ fn({ T }, nil) }, { anyT }))
		node:setproperty(types.singleton("Mutate"), fn({ fn({ T }, nil) }, { optT }))
		node:setproperty(types.singleton("Raw"), fn({}, { optT }))
		node:setproperty(types.singleton("Snapshot"), fn({}, { optT }))
		node:setproperty(types.singleton("IsLoaded"), fn({}, { types.boolean }))
		node:setproperty(types.singleton("Key"), fn({}, { types.optional(types.string) }))
		node:setproperty(types.singleton("Save"), fn(nil, nil))
		node:setproperty(types.singleton("End"), fn(nil, nil))
		node:setproperty(types.singleton("Replicate"), fn({ types.optional(anyT) }, nil))

		-- table membership
		node:setproperty(types.singleton("Has"), fn({ anyT }, { types.boolean }))
		node:setproperty(types.singleton("Keys"), fn({}, { types.any }))
		node:setproperty(types.singleton("Values"), fn({}, { types.any }))
		node:setproperty(types.singleton("Size"), fn({}, { types.number }))
		node:setproperty(types.singleton("Length"), fn({}, { types.number }))
		node:setproperty(types.singleton("Clear"), fn(nil, nil))
		node:setproperty(types.singleton("Insert"), fn({ anyT, anyT }, nil))
		node:setproperty(types.singleton("Remove"), fn({ anyT }, { anyT }))
		node:setproperty(types.singleton("OnInsert"), fn({ fn({ anyT, anyT }, nil) }, { anyT }))
		node:setproperty(types.singleton("OnRemove"), fn({ fn({ anyT, anyT }, nil) }, { anyT }))

		-- array helpers
		node:setproperty(types.singleton("Push"), fn(nil, { types.optional(types.number) }))
		node:setproperty(types.singleton("Pop"), fn({}, { anyT }))
		node:setproperty(types.singleton("InsertAt"), fn({ types.number, anyT }, nil))
		node:setproperty(types.singleton("RemoveAt"), fn({ types.number }, { anyT }))

		local indexer = t:indexer()
		if indexer then
			local indexType = indexer.index
			local resultType = indexer.readresult or indexer.writeresult
			if indexType and resultType then
				node:setindexer(indexType, Access(resultType))
			end
		end

		return node
	end

	if t:is("union") then
		for _, component in (t :: any):components() do
			if not component:is("nil") then
				return Access(component)
			end
		end
	end

	return leaf(types.any, false)
end

export type Access<T> = Access<T>
export type State<T> = Access<T>

export type NumberNode = Access<number>
export type BooleanNode = Access<boolean>
export type StringNode = Access<string>

return nil
