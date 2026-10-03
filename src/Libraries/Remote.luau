--!optimize 2
--[=[
	These are thin-typed wrappers around RemoteEvents
	This provides the same usage as RBXScriptSignals without bloat
]=]

--// Types

export type Event<T...> = {
	FireClient: (self: Event<T...>, Player: Player, T...) -> (),
	FireAllClients: (self: Event<T...>, T...) -> (),
	FireServer: (self: Event<T...>, T...) -> (),
	OnClientEvent: RBXScriptSignal,
	OnServerEvent: RBXScriptSignal,
}

--// Services

local RunService = game:GetService("RunService")

--// Variables

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "DataVaultRemotes"

--// Functions

local function Folder(): Folder
	local Parent = script.Parent
	local Existing = Parent:FindFirstChild(FOLDER_NAME)
	if Existing and Existing:IsA("Folder") then
		return Existing
	end

	if IS_SERVER then
		local Created = Instance.new("Folder")
		Created.Name = FOLDER_NAME
		Created.Parent = Parent
		return Created
	end

	return Parent:WaitForChild(FOLDER_NAME) :: Folder
end

local function Event(Name: string): RemoteEvent
	local Parent = Folder()
	local Existing = Parent:FindFirstChild(Name)
	if Existing and Existing:IsA("RemoteEvent") then
		return Existing
	end

	if IS_SERVER then
		local Created = Instance.new("RemoteEvent")
		Created.Name = Name
		Created.Parent = Parent
		return Created
	end

	return Parent:WaitForChild(Name) :: RemoteEvent
end

--// Class

local Remote = {}

function Remote.event<T...>(Name: string): Event<T...>
	return Event(Name) :: any
end

return Remote
