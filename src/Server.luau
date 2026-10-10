--!optimize 2

--[=[
	@class DataVaultServer

	Server-side session manager and state factory returned by
	[DataVault.Open](/api/DataVault#Open) on the server.

	Key-first API. Prefer [State](/api/DataVaultServer#State) / [Player](/api/DataVaultServer#Player)
	for gameplay reads and writes.for typed State
	**Typed `State<T>` / `Access<T>` requires the new Luau type solver.**
	Without the new solver, runtime works but field/method autocomplete will not expand.
	:::

	:::danger Type solver required 
]=]


local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ProfileStore = require(script.Parent.Libraries.ProfileStore)
local Signal = require(script.Parent.Libraries.Signal)
local Remote = require(script.Parent.Libraries.Remote)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)
local State = require(script.Parent.State)

local ReplicaEvent = Remote.event("DataVault_Replicate")
local ReplicaRequest = Remote.event("DataVault_Request")

local DEFAULT_KICK_FAIL = "Could not load your data. Please rejoin."
local DEFAULT_KICK_END = "Your data session ended. Please rejoin."
local DEFAULT_MAX_PATCHES = 24
local DEFAULT_COLLAPSE = 12
local DEFAULT_LOAD_TIMEOUT = 30

local function PlayerFromUserIdKey(Key: string, Prefix: string): Player?
	local Raw = Key
	if Prefix ~= "" and string.sub(Key, 1, #Prefix) == Prefix then
		Raw = string.sub(Key, #Prefix + 1)
	end
	local UserId = tonumber(Raw)
	if not UserId then
		return nil
	end
	return Players:GetPlayerByUserId(UserId)
end

local DataVaultServer = {}

--[=[
	Opens a server DataVault bound to `Options.StoreName`.

	:::danger Type solver required
	**Typed access via `:Explicit` / `:Player` requires the new Luau type solver.**
	:::

	@within DataVaultServer
	@param Options Types.Config<T>
	@return DataVaultServer
]=]
function DataVaultServer.Open<T>(Options: Types.Config<T>)
	assert(type(Options) == "table", "DataVault: config must be a table")
	assert(type(Options.StoreName) == "string" and Options.StoreName ~= "", "DataVault: StoreName required")
	assert(type(Options.Template) == "table", "DataVault: Template required")

	local LiveStore = ProfileStore.New(Options.StoreName, Options.Template)
	local UseMock = Options.Mock == true
	local Backend = if UseMock then LiveStore.Mock else LiveStore

	local KeyPrefix = Options.KeyPrefix or ""
	local MakePlayerKey = Options.PlayerKey or function(Player: Player): string
		return KeyPrefix .. tostring(Player.UserId)
	end

	local Sessions: { [string]: Types.Profile<T> } = {}
	local Seq: { [string]: number } = {}
	local PendingPatches: { [string]: { Types.ReplicaPatch } } = {}
	local PendingFull: { [string]: boolean } = {}
	local ChangedSignals: { [string]: any } = {}
	local FlushScheduled = false
	local PlayerBound = false
	local Destroyed = false

	local ReplicateMode = Options.ReplicateMode or "Hybrid"
	local MaxPatchesBeforeFull = Options.MaxPatchesBeforeFull or DEFAULT_MAX_PATCHES
	local CollapseAt = Options.CollapsePatchesAt or DEFAULT_COLLAPSE
	local FlushImmediately = Options.FlushImmediately == true
	local ReplicateOnSave = Options.ReplicateOnSave == true
	local SchemaVersion = Options.SchemaVersion

	local Server = {
		Name = Options.StoreName,
		Template = Options.Template,
		Mock = UseMock,
		OnJoin = Signal.new(),
		OnLeave = Signal.new(),
		OnSessionLoaded = Signal.new(),
		OnSessionEnded = Signal.new(),
		OnMutated = Signal.new(),
	}

	local function PlayerKey(Player: Player): string
		return MakePlayerKey(Player)
	end

	local function PlayerFromKey(Key: string): Player?
		return PlayerFromUserIdKey(Key, KeyPrefix)
	end

	local function ChangedOf(Key: string)
		local Existing = ChangedSignals[Key]
		if Existing then
			return Existing
		end
		local Created = Signal.new()
		ChangedSignals[Key] = Created
		return Created
	end

	local function NextSeq(Key: string): number
		local Current = (Seq[Key] or 0) + 1
		Seq[Key] = Current
		return Current
	end

	local function ResolvePlayer(Key: string, Target: Player?): Player?
		return Target or PlayerFromKey(Key)
	end

	local function FireEncoded(Key: string, Kind: string, Data: any?, Patches: any?, Target: Player?)
		local Profile = Sessions[Key]
		if not Profile or not Profile:IsActive() then
			return
		end
		local Player = ResolvePlayer(Key, Target)
		if not Player then
			return
		end
		local SeqN = NextSeq(Key)
		local Buf = Util.EncodeReplica(Kind, Options.StoreName, Key, SeqN, Data, Patches)
		ReplicaEvent:FireClient(Player, {
			StoreName = Options.StoreName,
			Key = Key,
			Seq = SeqN,
			Kind = Kind,
			Buffer = Buf,
		})
	end

	local function FireFull(Key: string, Target: Player?)
		local Profile = Sessions[Key]
		if not Profile or not Profile:IsActive() then
			return
		end
		FireEncoded(Key, "Full", Util.DeepCopy(Profile.Data), nil, Target)
	end

	local function FirePatches(Key: string, Patches: { Types.ReplicaPatch }, Target: Player?)
		if #Patches == 0 then
			return
		end
		if ReplicateMode == "Full" or #Patches >= MaxPatchesBeforeFull then
			FireFull(Key, Target)
			return
		end
		FireEncoded(Key, "Patch", nil, Patches, Target)
	end

	local function QueueFull(Key: string)
		PendingFull[Key] = true
		PendingPatches[Key] = nil
	end

	local function QueuePatches(Key: string, Patches: { Types.ReplicaPatch })
		if PendingFull[Key] then
			return
		end
		if ReplicateMode == "Full" then
			QueueFull(Key)
			return
		end
		local Bucket = PendingPatches[Key]
		if not Bucket then
			Bucket = {}
			PendingPatches[Key] = Bucket
		end
		for _, Patch in Patches do
			table.insert(Bucket, Patch)
		end
		if #Bucket >= MaxPatchesBeforeFull then
			QueueFull(Key)
		end
	end

	local function QueuePathDirty(Key: string, Path: { any }, Value: any)
		QueuePatches(Key, {
			{
				Path = Util.ClonePath(Path),
				Value = if type(Value) == "table" then Util.DeepCopy(Value) else Value,
			},
		})
	end

	local function FlushKey(Key: string)
		if PendingFull[Key] then
			PendingFull[Key] = nil
			PendingPatches[Key] = nil
			FireFull(Key)
			return
		end
		local Bucket = PendingPatches[Key]
		if not Bucket or #Bucket == 0 then
			return
		end
		PendingPatches[Key] = nil
		FirePatches(Key, Bucket)
	end

	local function FlushAll()
		FlushScheduled = false
		local Seen: { [string]: boolean } = {}
		for Key in PendingFull do
			Seen[Key] = true
			FlushKey(Key)
		end
		for Key in PendingPatches do
			if not Seen[Key] then
				FlushKey(Key)
			end
		end
	end

	local function ScheduleFlush()
		if FlushImmediately then
			FlushAll()
			return
		end
		if FlushScheduled then
			return
		end
		FlushScheduled = true
		task.defer(FlushAll)
	end

	local function ApplyMigration(Profile: Types.Profile<T>)
		if SchemaVersion == nil then
			return
		end
		local Meta = Profile.RobloxMetaData :: any
		if type(Meta) ~= "table" then
			return
		end
		local FromVersion = Meta.SchemaVersion
		if type(FromVersion) ~= "number" then
			FromVersion = 0
		end
		if FromVersion < SchemaVersion and Options.Migrate then
			Options.Migrate(Profile.Data, FromVersion, SchemaVersion)
		end
		Meta.SchemaVersion = SchemaVersion
	end

	local function ForgetKey(Key: string)
		PendingPatches[Key] = nil
		PendingFull[Key] = nil
		local Changed = ChangedSignals[Key]
		if Changed then
			Changed:DisconnectAll()
			ChangedSignals[Key] = nil
		end
	end

	local function GetSession(Key: string): Types.Profile<T>?
		local Profile = Sessions[Key]
		if Profile and Profile:IsActive() then
			return Profile
		end
		return nil
	end

	local function Notify(Key: string, Data: T)
		ChangedOf(Key):Fire(Data)
		Server.OnMutated:Fire(Key, Data)
	end

	local function WritePath(Key: string, Path: { any }, Value: any)
		local Profile = GetSession(Key)
		if not Profile then
			return
		end
		local Player = PlayerFromKey(Key)
		local Context: Types.MutateContext<T> = { Key = Key, Player = Player, Data = Profile.Data }
		if Options.BeforeMutate then
			Options.BeforeMutate(Context)
		end
		local Copied = Util.DeepCopy(Value)
		if #Path == 0 then
			-- should not happen for path writes
		else
			Util.SetAt(Profile.Data, Path, Copied)
		end
		if Options.AfterMutate then
			Options.AfterMutate(Context)
		end
		if ReplicateMode == "Full" then
			QueueFull(Key)
		else
			QueuePathDirty(Key, Path, Copied)
		end
		ScheduleFlush()
		Notify(Key, Profile.Data)
	end

	local function MutateRoot(Key: string, Mutator: (Data: any) -> (), Full: boolean?): any?
		local Profile = GetSession(Key)
		if not Profile then
			return nil
		end
		local Player = PlayerFromKey(Key)
		local Context: Types.MutateContext<T> = { Key = Key, Player = Player, Data = Profile.Data }
		if Options.BeforeMutate then
			Options.BeforeMutate(Context)
		end
		local Before = Util.DeepCopy(Profile.Data)
		Mutator(Profile.Data)
		if Options.AfterMutate then
			Options.AfterMutate(Context)
		end
		if Full or ReplicateMode == "Full" then
			QueueFull(Key)
		else
			local Patches = Util.Diff(Before, Profile.Data, CollapseAt)
			if #Patches > 0 then
				QueuePatches(Key, Patches)
			end
		end
		ScheduleFlush()
		Notify(Key, Profile.Data)
		return Profile.Data
	end

	local function ObserveRoot(Key: string, Listener: (Data: any) -> ())
		local Connection = ChangedOf(Key):Connect(Listener)
		local Profile = GetSession(Key)
		if Profile then
			task.defer(Listener, Profile.Data)
		end
		return Connection
	end

	local function ObservePath(Key: string, Path: { any }, Listener: (Value: any) -> ())
		local Last = Util.GetAt(if GetSession(Key) then GetSession(Key).Data else nil, Path)
		return ObserveRoot(Key, function(Data)
			local Current = Util.GetAt(Data, Path)
			if Current ~= Last then
				Last = Current
				Listener(Current)
			end
		end)
	end

	-- Bridge shared by all State nodes for this server
	local function BridgeFor(Key: string): any
		return {
			GetRoot = function(K: string)
				local P = GetSession(K)
				return if P then P.Data else nil
			end,
			IsLoaded = function(K: string)
				return GetSession(K) ~= nil
			end,
			WritePath = WritePath,
			MutateRoot = MutateRoot,
			ObservePath = ObservePath,
			ObserveRoot = ObserveRoot,
			Save = function(K: string)
				local P = GetSession(K)
				if P then
					P:Save()
					if ReplicateOnSave then
						QueueFull(K)
						ScheduleFlush()
					end
				end
			end,
			End = function(K: string)
				Server:End(K)
			end,
			Replicate = function(K: string, Target: Player?)
				PendingFull[K] = nil
				PendingPatches[K] = nil
				FireFull(K, Target)
			end,
			ReadOnly = false,
		}
	end

	----------------------------------------------------------------
	-- Public API
	----------------------------------------------------------------

	--[=[
		Builds the session key for a player (`KeyPrefix` + UserId by default).

		@within DataVaultServer
		@param Player Player
		@return string
	]=]
	function Server:KeyFor(Player: Player): string
		return PlayerKey(Player)
	end

	--[=[
		Returns the typed state tree for a session key.

		:::danger Type solver required
		**Annotate the result for autocomplete:**

		```lua
		local S: DataVault.State<MyData> = Server:Explicit(key)
		```

		The new Luau type solver **must** be enabled or fields will not expand.
		:::

		@within DataVaultServer
		@param Key string
		@return State<T>
	]=]
	function Server:Explicit(Key: string): Types.State<T>
		return State.new(BridgeFor(Key), Key, {}) :: Types.State<T>
	end

	--[=[
		Starts (or returns) an active ProfileStore session for `Key`.

		@within DataVaultServer
		@param Key string
		@param Params Types.SessionParams?
		@return Profile<T>?
	]=]
	function Server:Load(Key: string, Params: Types.SessionParams?): Types.Profile<T>?
		if Destroyed then
			return nil
		end
		local Existing = GetSession(Key)
		if Existing then
			return Existing
		end
		local Profile = Backend:StartSessionAsync(Key, Params :: any) :: Types.Profile<T>?
		if not Profile then
			return nil
		end
		Profile:Reconcile()
		Util.Reconcile(Profile.Data, Options.Template)
		ApplyMigration(Profile)
		Sessions[Key] = Profile
		Seq[Key] = Seq[Key] or 0
		if Options.OnMessage then
			Profile:MessageHandler(function(Message, Processed)
				(Options.OnMessage :: any)(Key, Message, Processed)
			end)
		end
		Profile.OnSessionEnd:Connect(function()
			if Sessions[Key] == Profile then
				Sessions[Key] = nil
			end
			ForgetKey(Key)
			self.OnSessionEnded:Fire(Key)
			local Player = PlayerFromKey(Key)
			if Player then
				self.OnLeave:Fire(Player)
			end
		end)
		self:Replicate(Key)
		self.OnSessionLoaded:Fire(Key, Profile.Data)
		local Player = PlayerFromKey(Key)
		if Player then
			Profile:AddUserId(Player.UserId)
			if Options.KickOnSessionEnd ~= false then
				Profile.OnSessionEnd:Connect(function()
					if Player.Parent == Players then
						Player:Kick(Options.KickMessage or DEFAULT_KICK_END)
					end
				end)
			end
			self.OnJoin:Fire(Player, Profile.Data)
		end
		return Profile
	end

	--[=[
		Ends the session for `Key` and clears pending replication.

		@within DataVaultServer
		@param Key string
	]=]
	function Server:End(Key: string)
		local Profile = Sessions[Key]
		PendingPatches[Key] = nil
		PendingFull[Key] = nil
		if Profile and Profile:IsActive() then
			Profile:EndSession()
			return
		end
		if Sessions[Key] == nil then
			return
		end
		Sessions[Key] = nil
		ForgetKey(Key)
		self.OnSessionEnded:Fire(Key)
		local Player = PlayerFromKey(Key)
		if Player then
			self.OnLeave:Fire(Player)
		end
	end

	--[=[
		Binds `Players.PlayerAdded` / `PlayerRemoving` to Load/End using `KeyFor`.

		@within DataVaultServer
	]=]
	function Server:BindPlayers()
		if PlayerBound then
			return
		end
		PlayerBound = true
		local KickOnFail = Options.KickOnFail ~= false
		local KickMessage = Options.KickMessage or DEFAULT_KICK_FAIL
		local function OnPlayerAdded(Player: Player)
			local Profile = self:Load(PlayerKey(Player), {
				Cancel = function()
					return Player.Parent ~= Players
				end,
			})
			if not Profile and KickOnFail and Player.Parent == Players then
				Player:Kick(KickMessage)
			end
		end
		local function OnPlayerRemoving(Player: Player)
			self:End(PlayerKey(Player))
		end
		for _, Player in Players:GetPlayers() do
			task.spawn(OnPlayerAdded, Player)
		end
		Players.PlayerAdded:Connect(OnPlayerAdded)
		Players.PlayerRemoving:Connect(OnPlayerRemoving)
	end

	--[=[
		Returns live profile data for an active session, or nil.

		@within DataVaultServer
		@param Key string
		@return T?
	]=]
	function Server:Get(Key: string): T?
		local P = GetSession(Key)
		return if P then P.Data else nil
	end

	--[=[
		Whether an active session exists for `Key`.

		@within DataVaultServer
		@param Key string
		@return boolean
	]=]
	function Server:IsLoaded(Key: string): boolean
		return GetSession(Key) ~= nil
	end

	--[=[
		Yields until the session for `Key` is loaded (or timeout).

		@within DataVaultServer
		@param Key string
		@param Timeout number?
		@return Profile<T>?
	]=]
	function Server:Wait(Key: string, Timeout: number?): Types.Profile<T>?
		local Existing = GetSession(Key)
		if Existing then
			return Existing
		end
		if Timeout == nil then
			while true do
				local LoadedKey = self.OnSessionLoaded:Wait()
				if LoadedKey == Key then
					return GetSession(Key)
				end
			end
		end
		local Thread = coroutine.running()
		local Settled = false
		local Connection = self.OnSessionLoaded:Connect(function(LoadedKey)
			if Settled or LoadedKey ~= Key then
				return
			end
			Settled = true
			task.spawn(Thread, GetSession(Key))
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
		Yields for data only. Returns `(nil, reason)` on failure.

		@within DataVaultServer
		@param Key string
		@param Timeout number?
		@return T?
		@return LoadFailureReason?
	]=]
	function Server:WaitData(Key: string, Timeout: number?): (T?, Types.LoadFailureReason?)
		local Profile = self:Wait(Key, Timeout or Options.LoadTimeout or DEFAULT_LOAD_TIMEOUT)
		if Profile then
			return Profile.Data, nil
		end
		if Destroyed then
			return nil, "Destroyed"
		end
		local Player = PlayerFromKey(Key)
		if Player and Player.Parent ~= Players then
			return nil, "PlayerLeft"
		end
		return nil, "NilProfile"
	end

	--[=[
		Active session keys.

		@within DataVaultServer
		@return { string }
	]=]
	function Server:Keys(): { string }
		local List = {}
		for Key, Profile in Sessions do
			if Profile:IsActive() then
				table.insert(List, Key)
			end
		end
		return List
	end

	--[=[
		Saves one active session.

		@within DataVaultServer
		@param Key string
	]=]
	function Server:Save(Key: string)
		local P = GetSession(Key)
		if P then
			P:Save()
			if ReplicateOnSave then
				QueueFull(Key)
				ScheduleFlush()
			end
		end
	end

	--[=[
		Saves every active session.

		@within DataVaultServer
	]=]
	function Server:SaveAll()
		for Key, Profile in Sessions do
			if Profile:IsActive() then
				Profile:Save()
			end
		end
		if ReplicateOnSave then
			for Key in Sessions do
				QueueFull(Key)
			end
			ScheduleFlush()
		end
	end

	--[=[
		Forces a full buffer replica for `Key` (optionally to one player).

		@within DataVaultServer
		@param Key string
		@param Target Player?
	]=]
	function Server:Replicate(Key: string, Target: Player?)
		PendingFull[Key] = nil
		PendingPatches[Key] = nil
		FireFull(Key, Target)
	end

	--[=[
		Flushes pending patches/full replicas now.

		@within DataVaultServer
		@param Key string?
	]=]
	function Server:Flush(Key: string?)
		if Key then
			FlushKey(Key)
			return
		end
		FlushAll()
	end

	--[=[
		Sends a ProfileStore cross-server message for `Key`.

		@within DataVaultServer
		@param Key string
		@param Message Types.JSONAcceptable
		@return boolean
	]=]
	function Server:Message(Key: string, Message: Types.JSONAcceptable): boolean
		return Backend:MessageAsync(Key, Message)
	end

	--[=[
		Reads a profile without taking a session lock (view-only).

		@within DataVaultServer
		@param Key string
		@param Version string?
		@return Profile<T>?
	]=]
	function Server:View(Key: string, Version: string?): Types.Profile<T>?
		return Backend:GetAsync(Key, Version) :: any
	end

	--[=[
		Removes stored data and ends any local session for `Key`.

		@within DataVaultServer
		@param Key string
		@return boolean
	]=]
	function Server:Remove(Key: string): boolean
		Sessions[Key] = nil
		ForgetKey(Key)
		return Backend:RemoveAsync(Key)
	end

	--[=[
		Flushes, ends all sessions, and tears down internal state.

		@within DataVaultServer
	]=]
	function Server:Destroy()
		Destroyed = true
		self:Flush()
		for _, Profile in Sessions do
			if Profile:IsActive() then
				Profile:EndSession()
			end
		end
		table.clear(Sessions)
		table.clear(PendingPatches)
		table.clear(PendingFull)
		for _, Changed in ChangedSignals do
			Changed:DisconnectAll()
		end
		table.clear(ChangedSignals)
	end

	ReplicaRequest.OnServerEvent:Connect(function(Player: Player, Request: any)
		if type(Request) ~= "table" or Request.StoreName ~= Options.StoreName then
			return
		end
		local Key = PlayerKey(Player)
		if Sessions[Key] then
			Server:Replicate(Key, Player)
		end
	end)

	if Options.BindPlayers == true then
		(Server :: any):BindPlayers()
	end

	local AutoSaveSeconds = Options.AutoSaveSeconds
	if type(AutoSaveSeconds) == "number" and AutoSaveSeconds > 0 then
		task.spawn(function()
			while not Destroyed do
				task.wait(AutoSaveSeconds)
				if Destroyed then
					break
				end
				for _, Profile in Sessions do
					if Profile:IsActive() then
						Profile:Save()
					end
				end
			end
		end)
	end

	RunService.Heartbeat:Connect(function()
		if FlushScheduled then
			FlushAll()
		end
	end)

	export type DataVaultServer = typeof(Server)

	return Server :: DataVaultServer
end

return DataVaultServer
