# Changelog

## 1.0.3 — 2026-10-29

- Party and warband assist no longer floods chat with errors when another addon is also tracking group combat
- Allies who leave your party or warband are no longer kept as the assist target
- EZAssist will not overwrite or delete a macro you saved in its previous slot

## 1.0.2 — 2026-10-28

- Notify chat: announce each assist target once until the pick changes (no re-spam on hostile clear / wstring churn)
- Notify line no longer repeats `EZAssist:` under the `[EZAssist]` tag
- Defaults for new installs: range `65`, `clearOnHostile` off (existing saved settings unchanged)
- Slash: `/eza clearhostile` and `/eza glow` (aliases: `clear` / `hostile`, `glowon`)
- Scenario begin/end, disabling the addon, or turning notify back on clears the last announcement so the current pick can be announced again
- An open config window follows `/eza notify`, `clearhostile`, `glow`, and `range`, so Okay/Apply does not revert the slash change

## 1.0.1 — 2026-10-28

- Config window (CustomUI-style): enable, clear-on-hostile, range, notify
- Open via `/ezassist`, `/ezass`, `/eza`, or clickable yellow/orange **[EZAssist]** chat tag
- `clearOnHostile` setting (default on) — optional clear while you have a living hostile
- System-channel chat output (StockPiler / CustomUI style)
- Macro icon shown in config text (`<icon23166>`)
- Drop unused disabled-icon DDS / `EZAssist_Icons.xml` (macro always uses stock `23166`)
- Glow on new assist pick; deferred clear after macro press (flag + OnUpdate; no work in `OnLButtonUp`)
- `glowOnNewAssist` setting (default on) — toggle burn glow when a new assist is available

## 1.0.0 — 2026-10-28

- Initial standalone extract from CustomUI SmartAssist
- KD → DB → TD assist macro for scenarios and party/warband
- Sticky / hysteresis, range filter, hostile clear, ActionButton glow
- Slash: `/eza` / `/ezassist`
