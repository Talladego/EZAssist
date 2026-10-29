# Changelog

## 1.0.3 - 2026-10-29

- Party and warband assist no longer floods chat with errors when another addon is also tracking group combat
- Allies who leave your party or warband are no longer kept as the assist target
- EZAssist will not overwrite or delete a macro you saved in its previous slot
- The "all macro slots are full" note only appears when every macro slot is actually taken
- If the EZAssist macro is missing, it is created again, including while you are not in a group
- Press the assist macro on an ally to lock them. Press it while targeting yourself to clear the lock and return to automatic assist
- You can lock an ally outside a party, warband, or scenario. EZAssist warns you that assist will not work there
- Turning EZAssist off keeps its macro and clears the assist target
- You can only lock another player. Clear on hostile only happens when you target an enemy player, not a monster or pet
- The config window explains how to lock an ally and how automatic assist picks a target
- The assist macro glows whenever it has a target. The glow checkbox was removed from the config window; /eza glow still turns the glow on or off
- Macro glow is gold while you've locked an ally and green while Auto KD picks the target.
- A locked ally is cleared when they leave your party or warband
- Performance improvements.

## 1.0.2 - 2026-10-28

- Notify chat: announce each assist target once until the pick changes (no re-spam on hostile clear / wstring churn)
- Notify line no longer repeats `EZAssist:` under the `[EZAssist]` tag
- Defaults for new installs: range `65`, `clearOnHostile` off (existing saved settings unchanged)
- Slash: `/eza clearhostile` and `/eza glow` (aliases: `clear` / `hostile`, `glowon`)
- Scenario begin/end, disabling the addon, or turning notify back on clears the last announcement so the current pick can be announced again
- An open config window follows `/eza notify`, `clearhostile`, `glow`, and `range`, so Okay/Apply does not revert the slash change

## 1.0.1 - 2026-10-28

- Config window (CustomUI-style): enable, clear-on-hostile, range, notify
- Open via `/ezassist`, `/ezass`, `/eza`, or clickable yellow/orange **[EZAssist]** chat tag
- `clearOnHostile` setting (default on) - optional clear while you have a living hostile
- System-channel chat output (StockPiler / CustomUI style)
- Macro icon shown in config text (`<icon23166>`)
- Drop unused disabled-icon DDS / `EZAssist_Icons.xml` (macro always uses stock `23166`)
- Glow on new assist pick; deferred clear after macro press (flag + OnUpdate; no work in `OnLButtonUp`)
- `glowOnNewAssist` setting (default on) - toggle burn glow when a new assist is available

## 1.0.0 - 2026-10-28

- Initial standalone extract from CustomUI SmartAssist
- KD -> DB -> TD assist macro for scenarios and party/warband
- Sticky / hysteresis, range filter, hostile clear, ActionButton glow
- Slash: `/eza` / `/ezassist`
