---
sidebar_position: 4
---

# Configuration

All options are passed to `DataVault:Init({ ... })`.

## Required

| Option | Type | Description |
|--------|------|-------------|
| `StoreName` | `string` | Name of the underlying DataStore. |
| `Template` | `T` | Your player data shape. Used as the template for newly created profiles. |

## Optional

### Storage & Keys

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `KeyPrefix` | `string` | `""` | Prefix added to every profile key. |
| `PlayerKey` | `(Player) -> string` | — | Custom function used to generate a player's profile key. |
| `Mock` | `boolean` | `false` | Uses ProfileStore's mock store. Useful for Studio testing. |

### Player Lifecycle

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `BindPlayers` | `boolean` | `false` | Automatically load and manage profiles when players join and leave. |
| `KickOnFail` | `boolean` | `false` | Kick the player when their profile fails to load. |
| `KickOnSessionEnd` | `boolean` | `false` | Kick the player when their active profile session ends unexpectedly. |
| `KickMessage` | `string` | — | Message displayed when a player is kicked because of a data failure or session ending. |
| `LoadTimeout` | `number` | — | Maximum amount of time, in seconds, to wait for a profile to load. |

### Schema & Migrations

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `SchemaVersion` | `number` | — | Current schema version of your player data. |
| `Migrate` | `(Data: T, FromVersion: number, ToVersion: number) -> ()` | — | Called when data needs to be migrated between schema versions. |

### Saving

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `AutoSaveSeconds` | `number` | — | Custom interval, in seconds, between automatic saves. |
| `FlushImmediately` | `boolean` | — | Immediately flushes pending changes instead of waiting for the normal save cycle. |
| `ReplicateOnSave` | `boolean` | — | Replicates the latest data when a save occurs. |

### Replication

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ReplicateMode` | `"Diff" \| "Full" \| "Hybrid"` | — | Controls how server data is replicated to clients. |
| `MaxPatchesBeforeFull` | `number` | `24` | Forces a full snapshot after this many pending patches. |
| `CollapsePatchesAt` | `number` | `12` | Collapses accumulated patches once this threshold is reached. |
| `ClientGuard` | `"Proxy" \| "Off"` | `"Proxy"` | Controls whether replicated client data is protected by a read-only proxy. |

#### Replication Modes

| Mode | Description |
|------|-------------|
| `"Diff"` | Replicates individual changes as patches. |
| `"Full"` | Replicates the complete data snapshot. |
| `"Hybrid"` | Uses patches normally and falls back to full snapshots when appropriate. |

### Mutation Hooks

| Option | Type | Description |
|--------|------|-------------|
| `BeforeMutate` | `(Context: MutateContext<T>) -> ()` | Called immediately before a mutation is applied. |
| `AfterMutate` | `(Context: MutateContext<T>) -> ()` | Called immediately after a mutation is applied. |

The mutation context contains:

```lua
{
    Key = string,
    Player = Player?,
    Data = T,
}
