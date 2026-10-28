# EZAssist

Standalone Return of Reckoning addon: one managed hotbar macro (`EZAssist`) that becomes `/assist <player>` for the best nearby ally by **KillDamage → Deathblows → Total Damage**.

Extracted from [CustomUI](https://github.com/Talladego/CustomUIv3) SmartAssist.

## Features

- **Scenarios / sieges** — uses live scenario scoreboard stats
- **Party / warband** — uses `GRP_STATS` chat packets (own cache; does not require RoRGroupScoreboard)
- **Range** — map-pip distance filter (default 100 ft)
- **Sticky / hysteresis** — dampens flicker when rankings shuffle
- Clears the macro while you have a **living hostile** target; dead corpses count as no target
- Never assists yourself
- Bind and press the macro yourself — RoR ignores `/assist` sent from addon Lua

## Install

1. Copy the addon into `Interface\AddOns\EZAssist\` (or run `.\tools\deploy.ps1` from this repo)
2. Enable **EZAssist** in the addon list (optional: **LibSlash** for `/eza`)
3. `/reload`

Do **not** run CustomUI SmartAssist and EZAssist at the same time — both manage an assist macro.

## Slash commands

Requires LibSlash.

| Command | Effect |
| :--- | :--- |
| `/eza` / `/ezassist` | Help |
| `/eza on` / `off` | Enable / disable (creates or deletes the macro) |
| `/eza range <1-500>` | Assist range in feet |
| `/eza notify on\|off` | Chat line when the assist target changes |
| `/eza status` | Diagnostic snapshot |

## Settings

Saved in `EZAssist.Settings`:

- `enabled` (default `true`)
- `range` (default `100`)
- `notify` (default `false`)

## Deploy (dev)

```powershell
.\tools\deploy.ps1
```

Copies runtime files into `C:\Users\talla\Games\Return of Reckoning\Interface\AddOns\EZAssist` and prunes extras.
