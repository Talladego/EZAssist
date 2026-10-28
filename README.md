# EZAssist

Standalone Return of Reckoning addon: one managed hotbar macro `/assist <player>` for the best nearby ally by **KillDamage → Deathblows → Total Damage**.

Extracted from [CustomUI](https://github.com/Talladego/CustomUIv3) SmartAssist. Do **not** run both at once.

## Features

- Scenarios (scoreboard) and party/warband (`GRP_STATS`; no RoRGroupScoreboard)
- Range filter, sticky pick, optional clear while you have a living hostile
- Always-active icon (`23166`); burn glow on a new unacked pick, cleared after you press the macro (deferred, safe for `/assist`)
- Config window: `/ezassist`, `/ezass`, `/eza`, or click the yellow/orange **[EZAssist]** System chat tag
- You must bind and press the macro yourself (RoR ignores `/assist` from addon Lua)

## Install

1. Copy into `Interface\AddOns\EZAssist\` (or `.\tools\deploy.ps1` from this repo)
2. Enable **EZAssist** (optional: **LibSlash** for slash commands)
3. `/reload`

## Slash (LibSlash)

| Command | Effect |
| :--- | :--- |
| `/ezassist` `/ezass` `/eza` | Open config |
| `/eza help` | Help |
| `/eza on` / `off` | Enable / disable |
| `/eza range <1-500>` | Assist range (ft) |
| `/eza notify on\|off` | Chat when pick changes |
| `/eza status` | Diagnostics |

Settings (`EZAssist.Settings`): `enabled`, `clearOnHostile`, `glowOnNewAssist`, `range`, `notify`.

## Deploy

```powershell
.\tools\deploy.ps1
```

See [CHANGELOG.md](CHANGELOG.md).
