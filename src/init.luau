--!strict
--!native
--!optimize 2

--[=[
	@class DataVault

	Typed, Replicated, Batched data management over ProfileStore.

	version: 1.1.0
	by: [@soggybird0]

	@server
	@client
]=]

local RunService = game:GetService("RunService")
local Types = require(script.Types)

export type JSONAcceptable = Types.JSONAcceptable
export type Config<T> = Types.Config<T>
export type SessionParams = Types.SessionParams
export type Path = Types.Path
export type Profile<T> = Types.Profile<T>
export type Signal<T...> = Types.Signal<T...>
export type Connection = Types.Connection
export type MutateOptions = Types.MutateOptions
export type LoadFailureReason = Types.LoadFailureReason
export type Explicit<T> = Types.State<T>
export type NumberNode = Types.NumberNode
export type BooleanNode = Types.BooleanNode
export type StringNode = Types.StringNode

local DataVault = {}

--[=[
	@prop Version string
	@within DataVault
	@readonly
]=]
DataVault.Version = "1.1.0"

--[=[
	Opens a DataVault instance for the current environment.

	On the server this returns a server object (`Open` → session + state API).
	On the client this returns a client replica object.

	:::danger Type solver required
	**Typed `State<T>` / `Access<T>` requires the new Luau type solver.**
	:::

	@within DataVault
	@param Options Config<T>
	@return table -- Server & Client instances
]=]
function DataVault:Init<T>(Options: Types.Config<T>)
	return {
		Server = (RunService:IsServer() and require(script.Server).Open(Options)) or nil,
		Client = (RunService:IsClient() and require(script.Client).Open(Options)) or nil,
	}
end

return DataVault
