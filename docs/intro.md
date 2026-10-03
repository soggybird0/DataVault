# Introduction

**DataVault** is a lightweight, fully typed wrapper around [ProfileStore](https://devforum.roblox.com/t/profilestore-save-your-player-data-easy-datastore-module/3190543) that gives you:

- Strong Luau types for your entire data template
- Automatic client replication (Diff / Hybrid / Full)
- Clean server + client API surface with signals
- Schema migrations, auto-save, and Studio mock mode

It is also the successor of [ProfileStoreTyped](https://devforum.roblox.com/t/profilestoretyped/4870183/3).

:::tip
The New Luau Type Solver is **not required**.  
Data remains fully typed even if the solver is disabled.
:::

## Why DataVault?

| Feature | Benefit |
|---------|---------|
| Fully typed | Autocomplete + type safety for your entire data shape |
| Automatic replication | Clients stay in sync with minimal network traffic |
| Session signals | Easy `OnJoin`, `Changed`, load/end events |
| ProfileStore under the hood | Session locking, auto-save, and battle-tested reliability |

## Quick Links

- [Installation](./installation)
- [Getting Started](./getting-started)
- [Configuration](./configuration)
- [API Reference](/api/DataVault)
