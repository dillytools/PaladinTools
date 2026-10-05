# Paladin Tools

Paladin quality-of-life helpers: seal expiry flash, Exorcism highlight vs Undead/Demons, Purify glow, markers on buffs you cast, blessing rows on friendly nameplates, and a one-key smart blessing.

- TOC: `## Interface: 16001` (WoW Forever), version 0.1.0
- SavedVariables: `PaladinToolsDB`
- Slash: `/ptools` or `/paladintools` (no argument opens Options > AddOns > Paladin Tools; `help` lists subcommands)
- Keybind: `Bindings.xml` exposes the smart-blessing button.
- Load the `wow-forever-ui` skill before touching frames, auras or nameplates here.

## Files (TOC load order)
| File | Purpose |
|---|---|
| `Core.lua` | Namespace, single event frame with per-owner subscriptions, feature registry, `/ptools` subcommand registry (`ns.RegisterSlashCommand`). |
| `ButtonEffects.lua` | Glow / grey-out overlays on Blizzard action buttons by spell name, keyed by owner; avoids Blizzard's proc glow to prevent taint. |
| `SealTimer.lua` | Flashes the seal button near expiry in combat; tracks seals from your casts because aura data is secret in combat. |
| `ExorcismAlert.lua` | Glows Exorcism vs living Undead/Demon targets in combat, greys it out otherwise. |
| `AuraContainerUtil.lua` | Shared helpers for native `AuraContainer` frames (filter-string groups, button initializers). |
| `OwnBuffHighlight.lua` | Borders on buffs you cast, on the player buff frame and legacy target/focus frames (target frame buttons are forbidden on this client). |
| `NameplateBlessings.lua` | Friendly player nameplates: blessing row (yours first, pink border), name, optional hidden health bar. |
| `MinimapButton.lua` | Self-contained minimap button: left-click toggles nameplate customization, right-click opens settings. |
| `PurifyAlert.lua` | Glows Purify when you or a party member has a Poison or Disease. |
| `BlessingPriorities.lua` | Data only: blessing priority per role. Edit here to retune. |
| `RoleDetection.lua` | Resolves a unit to a role: manual override (`/ptools role`), auras, talents/inspect, group role, class default. |
| `BlessingPlanner.lua` | Picks the blessing and closest player needing one (out of combat only). |
| `SmartBlessing.lua` | Secure action button the keybind clicks; sets spell/unit in PreClick. |
| `Settings.lua` | Builds the settings panel: one toggle per feature with indented options. |

## Slash subcommands
`role`, `bless`, `blesstrace`, `platedebug`, `auradebug`, `framedebug`, `help`.
