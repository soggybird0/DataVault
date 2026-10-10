--!strict
--!native
--!optimize 2

--[=[
	@class DataVault

	Authoritative typed state layer: mutate once → dirty-track → calculated
	buffer replicate → persist.

	One metatable drives the whole data tree. The `Access<T>` type function
	gives Scribe-style autocomplete on paths like `data.Coins.Increment(50)`.

	:::danger Type solver required for typed access
	**The new Luau type solver is required for typed `Access<T>` / `State<T>`
	autocomplete and type-checking.**

	Enable it before relying on typed state:

	- **Studio:** select `Workspace` → set **UseNewLuauTypeSolver** to `Enabled`
	- **Luau LSP:** enable the new type solver in settings

	Without the new solver, runtime still works, but `State<T>` will not expand
	field/method autocomplete. Annotate loaded state explicitly:

	```lua
	type MyData = typeof(Template)
	local S: DataVault.State<MyData> = Server:State(key)
	```
	:::

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
DataVault.Version = "1.1.1"

--[=[
	Opens a DataVault instance for the current environment.

	On the server this returns a server object (`Open` → session + state API).
	On the client this returns a client replica object.

	:::danger Type solver required
	**Typed `State<T>` / `Access<T>` requires the new Luau type solver.**
	See the class docs for how to enable it.
	:::

	@within DataVault
	@param Options Config<T>
	@return table -- Server & Client instance
]=]
function DataVault:Init<T>(Options: Types.Config<T>)
	return {
		Version = "1.1.0",

		Server = (RunService:IsServer() and require(script.Server).Open(Options)) or nil,
		Client = (RunService:IsClient() and require(script.Client).Open(Options)) or nil,
	}
end

return DataVault
