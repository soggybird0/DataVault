---
sidebar_position: 3
---

# Getting Started

## 1. Create a Shared Module

Create a ModuleScript (e.g. `SharedVault`) that both server and client can require:

```lua
-- SharedVault.luau
local DataVault = require(path.to.DataVault)

return DataVault:Init({
	StoreName = "PlayerData_v1",
	Template = {
		Coins = 0,
		Level = 1,
		Inventory = {},
		-- your full data shape here
	},

	-- Optional (see Configuration page)
	-- KeyPrefix = "Player_",
	-- UseMock = true,
	-- KickOnFail = true,
	-- AutoSaveSeconds = 30,
})
```

## 2. Server Usage

```lua
-- Server.luau
local SharedVault = require(path.to.SharedVault)
local Vault = SharedVault.Server

Vault:OnPlayerJoin(function(session)
	print(session.Data.Coins)

	-- Simple set
	session:Set("Coins", session.Data.Coins + 100)

	-- Path-based set
	session:Set({"Inventory", "Sword"}, true)

	-- Full mutate
	session:Mutate(function(data)
		data.Level += 1
		return data
	end)
end)
```

## 3. Client Usage

```lua
-- Client.luau
local SharedVault = require(path.to.SharedVault)
local Vault = SharedVault.Client

-- Get the current session (or wait for it)
local session = Vault:Get()          -- non-yielding
-- or
local session = Vault:Wait()         -- yields until ready

print(session.Data.Coins)

session.Changed:Connect(function(path, value)
	print(`Changed: {path}, {value}`)
end)
```

:::caution
Client data is **read-only**.  
All mutations must happen on the server.
:::

## Next Steps

- See [Configuration](./configuration) for all available options
- Check the generated [API Reference](/api/DataVault) for full method lists
