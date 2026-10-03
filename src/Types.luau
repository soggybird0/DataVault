--!strict
--[=[
	Shared contracts for the vault.
	Meaning nothing here runs at runtime.
]=]

--// Types

export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer
export type Fn<T...> = (T...) -> ()

export type Path = { any }

export type ReplicaKind = "Full" | "Patch"

export type ReplicaPatch = {
	Path: Path,
	Value: any,
}

export type ReplicaPayload<T> = {
	StoreName: string,
	Key: string,
	Seq: number,
	Kind: ReplicaKind,
	Data: T?,
	Patches: { ReplicaPatch }?,
}

export type ReplicaRequest = {
	StoreName: string,
}

export type SessionParams = {
	Steal: boolean?,
	Cancel: (() -> boolean)?,
}

export type MutateContext<T> = {
	Key: string,
	Player: Player?,
	Data: T,
}

export type LoadFailureReason = "Destroyed" | "Cancelled" | "NilProfile" | "PlayerLeft"

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

-- This is the ProfileStore session surface we actually USE.
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
	MessageHandler: (self: Profile<T>, Fn: (Message: JSONAcceptable, Processed: () -> ()) -> ()) -> (),
	Save: Fn<any>,
	SetAsync: Fn<any>,
}

return nil
