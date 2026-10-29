# EZAssist

Standalone Return of Reckoning addon: one managed hotbar macro `/assist <player>`.

**Friendly lock** (default): press the macro while targeting an ally to lock them; target yourself and press to clear. **Auto KD** (fallback): with no lock, scenarios / party / warband pick by KillDamage → Deathblows → Total Damage.

Extracted from [CustomUI](https://github.com/Talladego/CustomUIv3) SmartAssist. Do **not** run both at once.

## Features

- Friendly lock + Auto KD fallback (scenarios / party / warband via scoreboard / `GRP_STATS`)
- Range filter, sticky pick, optional clear while you have a living hostile
- Always-active icon (`23166`); burn glow on a new unacked pick, cleared after you press the macro
- Config: `/ezassist`, `/ezass`, `/eza`, or click the yellow/orange **[EZAssist]** System chat tag
- Bind and press the macro yourself (RoR ignores `/assist` from addon Lua)

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
| `/eza clearhostile on\|off` | Clear macro while hostile targeted |
| `/eza glow on\|off` | Glow on new assist available |
| `/eza notify on\|off` | Chat when pick changes |
| `/eza status` | Diagnostics |

Settings (`EZAssist.Settings`): `enabled`, `clearOnHostile`, `glowOnNewAssist`, `range`, `notify`.

## Deploy

```powershell
.\tools\deploy.ps1
```

See [CHANGELOG.md](CHANGELOG.md).
