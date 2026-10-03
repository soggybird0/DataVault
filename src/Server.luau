--!optimize 2

--// Services

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--// Dependencies

local ProfileStore = require(script.Parent.Libraries.ProfileStore)
local Signal = require(script.Parent.Libraries.Signal)
local Remote = require(script.Parent.Libraries.Remote)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

--// Variables

local ReplicaEvent = Remote.event("DataVault_Replicate") :: Remote.Event<Types.ReplicaPayload<any>>
local ReplicaRequest = Remote.event("DataVault_Request") :: Remote.Event<Types.ReplicaRequest>

--// Fallbacks (not recommended to change!)

local DEFAULT_KICK_FAIL = "Could not load your data. Please rejoin."
local DEFAULT_KICK_END = "Your data session ended. Please rejoin."
local DEFAULT_MAX_PATCHES = 24
local DEFAULT_COLLAPSE = 12
local DEFAULT_LOAD_TIMEOUT = 30

--// Functions

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

--// Class

local DataVaultServer = {}

function DataVaultServer.Open<T>(Options: Types.Config<T>)
	if type(Options) ~= "table" then
		error("DataVault: config must be a table", 2)
	end
	if type(Options.StoreName) ~= "string" or Options.StoreName == "" then
		error("DataVault: StoreName must be a non-empty string", 2)
	end
	if type(Options.Template) ~= "table" then
		error("DataVault: Template must be a table", 2)
	end

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
	local ChangedSignals: { [string]: Types.Signal<T> } = {}
	local FlushScheduled = false
	local PlayerBound = false
	local Destroyed = false

	local ReplicateMode: Types.ReplicateMode = Options.ReplicateMode or "Hybrid"
	local MaxPatchesBeforeFull = Options.MaxPatchesBeforeFull or DEFAULT_MAX_PATCHES
	local CollapseAt = Options.CollapsePatchesAt or DEFAULT_COLLAPSE
	local FlushImmediately = Options.FlushImmediately == true
	local ReplicateOnSave = Options.ReplicateOnSave == true
	local SchemaVersion = Options.SchemaVersion

	local Server = {
		Name = Options.StoreName :: string,
		Template = Options.Template :: T,
		Mock = UseMock :: boolean,
		OnJoin = Signal.new() :: Types.Signal<Player, T>,
		OnLeave = Signal.new() :: Types.Signal<Player>,
		OnSessionLoaded = Signal.new() :: Types.Signal<string, T>,
		OnSessionEnded = Signal.new() :: Types.Signal<string>,
		OnMutated = Signal.new() :: Types.Signal<string, T>,
	}

	local function PlayerKey(Player: Player): string
		return MakePlayerKey(Player)
	end

	local function PlayerFromKey(Key: string): Player?
		return PlayerFromUserIdKey(Key, KeyPrefix)
	end

	local function ChangedOf(Key: string): Types.Signal<T>
		local Existing = ChangedSignals[Key]
		if Existing then
			return Existing
		end
		local Created = Signal.new() :: Signal.Signal<T>
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

	local function FireFull(Key: string, Target: Player?)
		local Profile = Sessions[Key]
		if not Profile or not Profile:IsActive() then
			return
		end

		local Player = ResolvePlayer(Key, Target)
		if not Player then
			return
		end

		ReplicaEvent:FireClient(Player, {
			StoreName = Options.StoreName,
			Key = Key,
			Seq = NextSeq(Key),
			Kind = "Full",
			Data = Util.DeepCopy(Profile.Data),
		})
	end

	local function FirePatches(Key: string, Patches: { Types.ReplicaPatch }, Target: Player?)
		if #Patches == 0 then
			return
		end

		local Profile = Sessions[Key]
		if not Profile or not Profile:IsActive() then
			return
		end

		local Player = ResolvePlayer(Key, Target)
		if not Player then
			return
		end

		if ReplicateMode == "Full" or #Patches >= MaxPatchesBeforeFull then
			FireFull(Key, Player)
			return
		end

		ReplicaEvent:FireClient(Player, {
			StoreName = Options.StoreName,
			Key = Key,
			Seq = NextSeq(Key),
			Kind = "Patch",
			Patches = Patches,
		})
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

	--[=[
		Starts a ProfileStore session for an arbitrary key.
	]=]
	function Server:LoadSessionAsync(Key: string, Params: Types.SessionParams?): Types.Profile<T>?
		if Destroyed then
			return nil
		end

		local Existing = Sessions[Key]
		if Existing and Existing:IsActive() then
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
			Profile:MessageHandler(function(Message: Types.JSONAcceptable, Processed: () -> ())
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
			self.OnJoin:Fire(Player, Profile.Data)
		end

		return Profile
	end

	--[=[
		Loads the player's session and tags the profile with their UserId (GDPR).
	]=]
	function Server:LoadPlayerAsync(Player: Player, Params: Types.SessionParams?): Types.Profile<T>?
		if Player.Parent ~= Players then
			return nil
		end

		local CombinedParams: Types.SessionParams = {
			Steal = if Params then Params.Steal else nil,
			Cancel = function()
				if Player.Parent ~= Players then
					return true
				end
				if Params and Params.Cancel then
					return Params.Cancel()
				end
				return false
			end,
		}

		local Profile = self:LoadSessionAsync(PlayerKey(Player), CombinedParams)
		if not Profile then
			return nil
		end

		Profile:AddUserId(Player.UserId)

		if Options.KickOnSessionEnd ~= false then
			Profile.OnSessionEnd:Connect(function()
				if Player.Parent == Players then
					Player:Kick(Options.KickMessage or DEFAULT_KICK_END)
				end
			end)
		end

		return Profile
	end

	function Server:GetSession(Key: string): Types.Profile<T>?
		local Profile = Sessions[Key]
		if Profile and Profile:IsActive() then
			return Profile
		end
		return nil
	end

	function Server:GetPlayerSession(Player: Player): Types.Profile<T>?
		return self:GetSession(PlayerKey(Player))
	end

	function Server:GetData(Key: string): T?
		local Profile = self:GetSession(Key)
		if Profile then
			return Profile.Data
		end
		return nil
	end

	function Server:GetPlayerData(Player: Player): T?
		return self:GetData(PlayerKey(Player))
	end

	function Server:Snapshot(Key: string): T?
		local Data = self:GetData(Key)
		if Data == nil then
			return nil
		end
		return Util.DeepCopy(Data)
	end

	function Server:SnapshotPlayer(Player: Player): T?
		return self:Snapshot(PlayerKey(Player))
	end

	function Server:GetAt(Key: string, Path: Types.Path | string): any
		local Data = self:GetData(Key)
		if Data == nil then
			return nil
		end
		return Util.GetAt(Data, Util.NormalizePath(Path))
	end

	function Server:GetPlayerAt(Player: Player, Path: Types.Path | string): any
		return self:GetAt(PlayerKey(Player), Path)
	end

	function Server:HasPath(Key: string, Path: Types.Path | string): boolean
		local Data = self:GetData(Key)
		if Data == nil then
			return false
		end
		return Util.HasAt(Data, Util.NormalizePath(Path))
	end

	function Server:HasPlayerPath(Player: Player, Path: Types.Path | string): boolean
		return self:HasPath(PlayerKey(Player), Path)
	end

	function Server:IsLoaded(Key: string): boolean
		return self:GetSession(Key) ~= nil
	end

	function Server:IsPlayerLoaded(Player: Player): boolean
		return self:IsLoaded(PlayerKey(Player))
	end

	function Server:GetLoadedKeys(): { string }
		local Keys = {}
		for Key, Profile in Sessions do
			if Profile:IsActive() then
				table.insert(Keys, Key)
			end
		end
		return Keys
	end

	function Server:GetLoadedPlayers(): { Player }
		local List = {}
		for _, Player in Players:GetPlayers() do
			if self:IsPlayerLoaded(Player) then
				table.insert(List, Player)
			end
		end
		return List
	end

	function Server:ForEachSession(Visitor: (Key: string, Data: T, Profile: Types.Profile<T>) -> ())
		for Key, Profile in Sessions do
			if Profile:IsActive() then
				Visitor(Key, Profile.Data, Profile)
			end
		end
	end

	function Server:WaitForSession(Key: string, Timeout: number?): Types.Profile<T>?
		local Existing = self:GetSession(Key)
		if Existing then
			return Existing
		end

		if Timeout == nil then
			while true do
				local LoadedKey = self.OnSessionLoaded:Wait()
				if LoadedKey == Key then
					return self:GetSession(Key)
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
			task.spawn(Thread, self:GetSession(Key))
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

	function Server:WaitForPlayer(Player: Player, Timeout: number?): Types.Profile<T>?
		return self:WaitForSession(PlayerKey(Player), Timeout)
	end

	function Server:WaitForData(Player: Player, Timeout: number?): (T?, Types.LoadFailureReason?)
		local Profile = self:WaitForPlayer(Player, Timeout or Options.LoadTimeout or DEFAULT_LOAD_TIMEOUT)
		if Profile then
			return Profile.Data, nil
		end
		if Destroyed then
			return nil, "Destroyed"
		end
		if Player.Parent ~= Players then
			return nil, "PlayerLeft"
		end
		return nil, "NilProfile"
	end

	local function RunMutator(Key: string, Mutator: (Data: T) -> (), ForceFull: boolean?): T?
		local Profile = Server:GetSession(Key)
		if not Profile then
			return nil
		end

		local Player = PlayerFromKey(Key)
		local Context: Types.MutateContext<T> = {
			Key = Key,
			Player = Player,
			Data = Profile.Data,
		}

		if Options.BeforeMutate then
			Options.BeforeMutate(Context)
		end

		local Before = Util.DeepCopy(Profile.Data)
		Mutator(Profile.Data)

		if Options.AfterMutate then
			Options.AfterMutate(Context)
		end

		if ForceFull or ReplicateMode == "Full" then
			QueueFull(Key)
		else
			local Patches = Util.Diff(Before, Profile.Data, CollapseAt)
			if #Patches > 0 then
				QueuePatches(Key, Patches)
			end
		end

		ScheduleFlush()
		ChangedOf(Key):Fire(Profile.Data)
		Server.OnMutated:Fire(Key, Profile.Data)
		return Profile.Data
	end

	--[=[
		Edit Profile.Data in place. Several Mutate calls in one frame become one replica.
	]=]
	function Server:Mutate(Key: string, Mutator: (Data: T) -> ()): T?
		return RunMutator(Key, Mutator, false)
	end

	function Server:MutatePlayer(Player: Player, Mutator: (Data: T) -> ()): T?
		return self:Mutate(PlayerKey(Player), Mutator)
	end

	-- Same as Mutate, but the next replica is always a full snapshot.
	function Server:Replace(Key: string, Mutator: (Data: T) -> ()): T?
		return RunMutator(Key, Mutator, true)
	end

	function Server:ReplacePlayer(Player: Player, Mutator: (Data: T) -> ()): T?
		return self:Replace(PlayerKey(Player), Mutator)
	end

	function Server:Transaction(Key: string, Mutator: (Data: T) -> ()): T?
		return self:Mutate(Key, Mutator)
	end

	function Server:TransactionPlayer(Player: Player, Mutator: (Data: T) -> ()): T?
		return self:MutatePlayer(Player, Mutator)
	end

	function Server:SetPath(Key: string, Path: Types.Path | string, Value: any): T?
		local Normalized = Util.NormalizePath(Path)
		return self:Mutate(Key, function(Data)
			Util.SetAt(Data, Normalized, Util.DeepCopy(Value))
		end)
	end

	function Server:SetPlayerPath(Player: Player, Path: Types.Path | string, Value: any): T?
		return self:SetPath(PlayerKey(Player), Path, Value)
	end

	function Server:UpdatePath(Key: string, Path: Types.Path | string, Updater: (Current: any) -> any): T?
		local Normalized = Util.NormalizePath(Path)
		return self:Mutate(Key, function(Data)
			local Current = Util.GetAt(Data, Normalized)
			Util.SetAt(Data, Normalized, Updater(Current))
		end)
	end

	function Server:UpdatePlayerPath(Player: Player, Path: Types.Path | string, Updater: (Current: any) -> any): T?
		return self:UpdatePath(PlayerKey(Player), Path, Updater)
	end

	function Server:IncrementPath(Key: string, Path: Types.Path | string, Amount: number): T?
		return self:UpdatePath(Key, Path, function(Current)
			local Number = if type(Current) == "number" then Current else 0
			return Number + Amount
		end)
	end

	function Server:IncrementPlayerPath(Player: Player, Path: Types.Path | string, Amount: number): T?
		return self:IncrementPath(PlayerKey(Player), Path, Amount)
	end

	function Server:Merge(Key: string, Partial: any): T?
		return self:Mutate(Key, function(Data)
			Util.Merge(Data, Partial)
		end)
	end

	function Server:MergePlayer(Player: Player, Partial: any): T?
		return self:Merge(PlayerKey(Player), Partial)
	end

	function Server:Observe(Key: string, Listener: (Data: T) -> ()): Types.Connection
		local Connection = ChangedOf(Key):Connect(Listener)
		local Data = self:GetData(Key)
		if Data ~= nil then
			task.defer(Listener, Data)
		end
		return Connection
	end

	function Server:ObservePlayer(Player: Player, Listener: (Data: T) -> ()): Types.Connection
		return self:Observe(PlayerKey(Player), Listener)
	end

	function Server:ObservePath(Key: string, Path: Types.Path | string, Listener: (Value: any) -> ()): Types.Connection
		local Normalized = Util.NormalizePath(Path)
		local Last = Util.GetAt(self:GetData(Key), Normalized)
		return self:Observe(Key, function(Data)
			local Current = Util.GetAt(Data, Normalized)
			if Current ~= Last then
				Last = Current
				Listener(Current)
			end
		end)
	end

	function Server:ObservePlayerPath(Player: Player, Path: Types.Path | string, Listener: (Value: any) -> ()): Types.Connection
		return self:ObservePath(PlayerKey(Player), Path, Listener)
	end

	function Server:Save(Key: string)
		local Profile = self:GetSession(Key)
		if not Profile then
			return
		end
		Profile:Save()
		if ReplicateOnSave then
			QueueFull(Key)
			ScheduleFlush()
		end
	end

	function Server:SavePlayer(Player: Player)
		self:Save(PlayerKey(Player))
	end

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

	function Server:Replicate(Key: string, Target: Player?)
		PendingFull[Key] = nil
		PendingPatches[Key] = nil
		FireFull(Key, Target)
	end

	function Server:ReplicatePlayer(Player: Player)
		self:Replicate(PlayerKey(Player), Player)
	end

	function Server:ReplicateAll()
		for Key, Profile in Sessions do
			if Profile:IsActive() then
				self:Replicate(Key)
			end
		end
	end

	function Server:Flush(Key: string?)
		if Key then
			FlushKey(Key)
			return
		end
		FlushAll()
	end

	function Server:EndSession(Key: string)
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

	function Server:EndPlayer(Player: Player)
		self:EndSession(PlayerKey(Player))
	end

	function Server:BindPlayers()
		if PlayerBound then
			return
		end
		PlayerBound = true

		local KickOnFail = Options.KickOnFail ~= false
		local KickMessage = Options.KickMessage or DEFAULT_KICK_FAIL

		local function OnPlayerAdded(Player: Player)
			local Profile = self:LoadPlayerAsync(Player)
			if not Profile and KickOnFail and Player.Parent == Players then
				Player:Kick(KickMessage)
			end
		end

		local function OnPlayerRemoving(Player: Player)
			self:EndPlayer(Player)
		end

		for _, Player in Players:GetPlayers() do
			task.spawn(OnPlayerAdded, Player)
		end

		Players.PlayerAdded:Connect(OnPlayerAdded)
		Players.PlayerRemoving:Connect(OnPlayerRemoving)
	end

	function Server:MessageAsync(Key: string, Message: Types.JSONAcceptable): boolean
		return Backend:MessageAsync(Key, Message)
	end

	function Server:MessagePlayerAsync(Player: Player, Message: Types.JSONAcceptable): boolean
		return self:MessageAsync(PlayerKey(Player), Message)
	end

	function Server:ViewAsync(Key: string, Version: string?): Types.Profile<T>?
		return Backend:GetAsync(Key, Version) :: Types.Profile<T>?
	end

	function Server:RemoveAsync(Key: string): boolean
		Sessions[Key] = nil
		ForgetKey(Key)
		return Backend:RemoveAsync(Key)
	end

	function Server:RemovePlayerAsync(Player: Player): boolean
		return self:RemoveAsync(PlayerKey(Player))
	end

	function Server:KeyFor(Player: Player): string
		return PlayerKey(Player)
	end

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

	ReplicaRequest.OnServerEvent:Connect(function(Player: Player, Request: Types.ReplicaRequest)
		if type(Request) ~= "table" then
			return
		end
		if Request.StoreName ~= Options.StoreName then
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

	-- Heartbeat is a fallback if defer is skipped on a closing frame.
	RunService.Heartbeat:Connect(function()
		if FlushScheduled then
			FlushAll()
		end
	end)

	return Server
end

return DataVaultServer
