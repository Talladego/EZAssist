# Changelog

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
