---
sidebar_position: 2
---

# Installation

## Creator Store (Recommended)

Get the latest model here:  
[https://create.roblox.com/store/asset/138095696448114](https://create.roblox.com/store/asset/138095696448114)

## From DevForum / Releases

1. Download the latest `.rbxm` from the [DevForum post](https://devforum.roblox.com/t/datavault-typed-replicated-player-data-on-top-of-profilestore/4912795) or GitHub Releases.
2. Place the `DataVault` folder into `ReplicatedStorage` (or any shared location).
3. Enable **API Services** in your game settings (Game Settings → Security → Enable Studio Access to API Services).

## Wally

```toml
[dependencies]
DataVault = "soggybird0/datavault@0.1.0"
```

## Folder Structure

After installing you should see something like:

```
ReplicatedStorage
└── DataVault.luau
    ├── Types.luau
    ├── Server.luau
    ├── Client.luau
    ├── Util.luau
    └── Libraries
        ├── ProfileStore.luau
        ├── Signal.luau
        └── Remote.luau
```

:::info
DataVault includes its own copy of ProfileStore, Signal, and Remote for convenience.  
You do **not** need to install ProfileStore separately unless you want to use it elsewhere.
:::
