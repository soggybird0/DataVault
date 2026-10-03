--!strict
--!native
--!optimize 2
--[[
	DataVault - 1.0.0
	Typed & Replicated player data on top of ProfileStore

	The New Luau Type Solver is not required, data is typed regardless!
	The module still runs if the solver is off.

	by @[soggybird0]
]]

--// Services

local RunService = game:GetService("RunService")

--// Dependencies

local Types = require(script.Types)

export type JSONAcceptable = Types.JSONAcceptable
export type Config<T> = Types.Config<T>
export type SessionParams = Types.SessionParams
export type ReplicaPayload<T> = Types.ReplicaPayload<T>
export type ReplicaPatch = Types.ReplicaPatch
export type Profile<T> = Types.Profile<T>
export type Path = Types.Path

export type Signal<T...> = Types.Signal<T...>
export type Connection = Types.Connection

--// Class

local DataVault = {}

function DataVault:Init<T>(Options: Types.Config<T>)
	return {
		Version = "1.0.0",

		Server = (RunService:IsServer() and require(script.Server).Open(Options)) or nil,
		Client = (RunService:IsClient() and require(script.Client).Open(Options)) or nil,
	}
end

return DataVault
