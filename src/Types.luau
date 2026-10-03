--!strict

-- Shared contracts for DataVault.
-- This module contains type definitions only and has no runtime behavior.

--// Types

--[=[
	Represents values that can be serialized by DataVault/ProfileStore.

	@type JSONAcceptable { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer
	@within DataVault
]=]
export type JSONAcceptable =
	{ JSONAcceptable }
	| { [string]: JSONAcceptable }
	| number
	| string
	| boolean
	| buffer

--[=[
	A generic callback function.

	@type Fn<T...> (T...) -> ()
	@within DataVault
]=]
export type Fn<T...> = (T...) -> ()

--[=[
	Represents a path into a DataVault data object.

	Paths are accepted by path-based operations such as `GetAt`
	and `ObservePath`.

	@type Path { any }
	@within DataVault
]=]
export type Path = { any }

--[=[
	Describes the kind of replica payload being sent.

	- `"Full"` contains the complete data.
	- `"Patch"` contains incremental changes.

	@type ReplicaKind "Full" | "Patch"
	@within DataVault
]=]
export type ReplicaKind = "Full" | "Patch"

--[=[
	Represents a single change applied to replicated data.

	@type ReplicaPatch { Path: Path, Value: any }
	@within DataVault
]=]
export type ReplicaPatch = {
	Path: Path,
	Value: any,
}

--[=[
	Represents data replicated from the server to a client.

	Full payloads contain `Data`, while patch payloads contain `Patches`.

	@type ReplicaPayload<T> { StoreName: string, Key: string, Seq: number, Kind: ReplicaKind, Data: T?, Patches: { ReplicaPatch }? }
	@within DataVault
]=]
export type ReplicaPayload<T> = {
	StoreName: string,
	Key: string,
	Seq: number,
	Kind: ReplicaKind,
	Data: T?,
	Patches: { ReplicaPatch }?,
}

--[=[
	Represents a client's request for a full replica synchronization.

	@type ReplicaRequest { StoreName: string }
	@within DataVault
]=]
export type ReplicaRequest = {
	StoreName: string,
}

--[=[
	Parameters controlling how a ProfileStore session is loaded.

	@type SessionParams { Steal: boolean?, Cancel: (() -> boolean)? }
	@within DataVault
]=]
export type SessionParams = {
	Steal: boolean?,
	Cancel: (() -> boolean)?,
}

--[=[
	Context passed to mutation hooks.

	@type MutateContext<T> { Key: string, Player: Player?, Data: T }
	@within DataVault
]=]
export type MutateContext<T> = {
	Key: string,
	Player: Player?,
	Data: T,
}

--[=[
	Reason why a profile load operation failed or was interrupted.

	@type LoadFailureReason "Destroyed" | "Cancelled" | "NilProfile" | "PlayerLeft"
	@within DataVault
]=]
export type LoadFailureReason =
	"Destroyed"
	| "Cancelled"
	| "NilProfile"
	| "PlayerLeft"

--[=[
	Represents a connection to a DataVault signal.

	@type Connection { Disconnect: (self: Connection) -> (), Connected: boolean }
	@within DataVault
]=]
export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

--[=[
	Typed signal interface used throughout DataVault.

	Signals support connecting listeners, firing events, waiting for
	emissions, and disconnecting listeners.

	@type Signal<T...> { Connect: (self: Signal<T...>, Listener: Fn<T...>) -> Connection, Once: (self: Signal<T...>, Listener: Fn<T...>) -> Connection, Wait: (self: Signal<T...>) -> T..., Fire: (self: Signal<T...>, T...) -> (), DisconnectAll: (self: Signal<T...>) -> () }
	@within DataVault
]=]
export type Signal<T...> = {
	Connect: (self: Signal<T...>, Listener: Fn<T...>) -> Connection,
	Once: (self: Signal<T...>, Listener: Fn<T...>) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

--[=[
	Controls how server data is replicated to clients.

	- `"Diff"` replicates individual changes.
	- `"Full"` replicates the complete data.
	- `"Hybrid"` combines full and patch replication.

	@type ReplicateMode "Diff" | "Full" | "Hybrid"
	@within DataVault
]=]
export type ReplicateMode = "Diff" | "Full" | "Hybrid"

--[=[
	Controls whether replicated client data is protected from writes.

	- `"Proxy"` exposes a read-only proxy.
	- `"Off"` exposes the replicated table directly.

	@type ClientGuard "Proxy" | "Off"
	@within DataVault
]=]
export type ClientGuard = "Proxy" | "Off"

--[=[
	Configuration used to initialize a DataVault instance.

	Controls storage, player binding, saving, schema migration,
	replication, and lifecycle hooks.

	@type Config<T> { StoreName: string, Template: T, KeyPrefix: string?, PlayerKey: ((Player) -> string)?, Mock: boolean?, BindPlayers: boolean?, KickOnFail: boolean?, KickOnSessionEnd: boolean?, KickMessage: string?, LoadTimeout: number?, SchemaVersion: number?, Migrate: ((Data: T, FromVersion: number, ToVersion: number) -> ())?, AutoSaveSeconds: number?, ReplicateMode: ReplicateMode?, MaxPatchesBeforeFull: number?, CollapsePatchesAt: number?, FlushImmediately: boolean?, ReplicateOnSave: boolean?, ClientGuard: ClientGuard?, BeforeMutate: ((Context: MutateContext<T>) -> ())?, AfterMutate: ((Context: MutateContext<T>) -> ())?, OnMessage: ((Key: string, Message: JSONAcceptable, Processed: () -> ()) -> ())? }
	@within DataVault
]=]
export type Config<T> = {
	-- Mandatory

	StoreName: string,
	Template: T,

	-- Optional keying

	KeyPrefix: string?,
	PlayerKey: ((Player) -> string)?,

	-- Studio / testing

	Mock: boolean?,

	-- Player handlers

	BindPlayers: boolean?,
	KickOnFail: boolean?,
	KickOnSessionEnd: boolean?,
	KickMessage: string?,
	LoadTimeout: number?,

	-- Schema

	SchemaVersion: number?,
	Migrate: ((Data: T, FromVersion: number, ToVersion: number) -> ())?,

	-- Saving

	AutoSaveSeconds: number?,

	-- Replication

	ReplicateMode: ReplicateMode?,
	MaxPatchesBeforeFull: number?,
	CollapsePatchesAt: number?,
	FlushImmediately: boolean?,
	ReplicateOnSave: boolean?,
	ClientGuard: ClientGuard?,

	-- Hooks

	BeforeMutate: ((Context: MutateContext<T>) -> ())?,
	AfterMutate: ((Context: MutateContext<T>) -> ())?,
	OnMessage: ((Key: string, Message: JSONAcceptable, Processed: () -> ()) -> ())?,
}

--[=[
	The ProfileStore session surface used by DataVault.

	This exposes only the profile fields and operations that DataVault
	interacts with.

	@type Profile<T> { Data: T, LastSavedData: T, FirstSessionTime: number, SessionLoadCount: number, Session: { PlaceId: number, JobId: string }?, RobloxMetaData: JSONAcceptable, UserIds: { number }, KeyInfo: DataStoreKeyInfo, Key: string, OnSave: Signal<>, OnLastSave: Signal<"Manual" | "External" | "Shutdown">, OnSessionEnd: Signal<>, OnAfterSave: Signal<T>, IsActive: (self: Profile<T>) -> boolean, Reconcile: Fn<any>, EndSession: Fn<any>, AddUserId: (self: Profile<T>, UserId: number) -> (), RemoveUserId: (self: Profile<T>, UserId: number) -> (), MessageHandler: (self: Profile<T>, Fn: (Message: JSONAcceptable, Processed: () -> ()) -> ()) -> (), Save: Fn<any>, SetAsync: Fn<any> }
	@within DataVault
]=]
export type Profile<T> = {
	Data: T,
	LastSavedData: T,
	FirstSessionTime: number,
	SessionLoadCount: number,
	Session: { PlaceId: number, JobId: string }?,
	RobloxMetaData: JSONAcceptable,
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo,
	Key: string,

	OnSave: Signal<>,
	OnLastSave: Signal<"Manual" | "External" | "Shutdown">,
	OnSessionEnd: Signal<>,
	OnAfterSave: Signal<T>,

	IsActive: (self: Profile<T>) -> boolean,
	Reconcile: Fn<any>,
	EndSession: Fn<any>,
	AddUserId: (self: Profile<T>, UserId: number) -> (),
	RemoveUserId: (self: Profile<T>, UserId: number) -> (),
	MessageHandler: (
		self: Profile<T>,
		Fn: (Message: JSONAcceptable, Processed: () -> ()) -> ()
	) -> (),
	Save: Fn<any>,
	SetAsync: Fn<any>,
}

return nil