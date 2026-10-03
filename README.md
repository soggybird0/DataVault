# DataVault

**Typed & Replicated player data on top of ProfileStore**

→ Also the successor of [ProfileStoreTyped](https://devforum.roblox.com/t/profilestoretyped/4870183/3), including all changes noted.

Version `1.0.0` · by [@soggybird0](https://www.roblox.com/users/profile?username=soggybird0)

DataVault is a lightweight, fully typed wrapper around [ProfileStore]([soggybird0.github.io/DataVault/](https://devforum.roblox.com/t/profilestore-save-your-player-data-easy-datastore-module/3190543)) that gives you strong Luau types, automatic client replication, and a clean session API — without forcing the new type solver.

---

## Features

- **Fully typed** data templates (works with or without the New Luau Type Solver)
- **Automatic replication** — Diff, Hybrid, or Full modes with configurable patch collapsing
- Clean **server + client** surface
- Session signals (`Changed`, `OnJoin`, load events, etc.)
- Schema migrations, auto-save, mock mode for Studio
- Graceful load-failure handling with optional kick messages
- Strict + native + optimize 2

---

## Installation

1. Get the latest `.rbxm` from the [DevForum post](https://devforum.roblox.com/t/datavault-typed-replicated-data-on-top-of-profilestore/4910665) or Releases.
2. Place the `DataVault` folder into `ReplicatedStorage` (or wherever you prefer).
3. Make sure you also have API Services enabled in your game.
