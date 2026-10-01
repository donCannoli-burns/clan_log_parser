# Reference comparison: StDoodle's Dungeon Parser v1.6

The implementation was reviewed against the supplied `dungeon_parser.ash` (StDoodle's Dungeon Parser v1.6) as an established KoLmafia clan-page parsing example.

## Patterns intentionally retained

- Typed ASH records for player-centric state.
- Regex parsing of clan-page content into structured player activity.
- `file_to_map()` / `map_to_file()` persistence under KoLmafia `data/`.
- Player-focused HTML table/dashboard presentation.
- Conservative handling of rows that cannot be attributed confidently.

## Deliberate differences

- `clan_log_parser` is standalone and does not import `relay_Clan_Management.ash` or other helper libraries.
- Players are keyed by numeric player ID rather than normalized player name, reducing rename/case ambiguity.
- The parser reads `clan_log.php` exactly once through the relay-override `visit_url()` pattern.
- Mall valuation uses `historical_price()` only; there is no live Mall request.
- Persistence is append/merge-by-stable-key and preserves repeated identical same-minute actions with an occurrence ordinal.
- A zero-row parse is fail-closed for persistence; existing audit files are left untouched.
- KMail is composer-only. No message is generated or sent by the script.
- The review threshold is an accounting heuristic, not a loot-distribution or disciplinary rule.

## Packaging difference

The repository uses KoLmafia's Git-sync layout directly:

```text
relay/clan_log.ash
data/clan_logs/.gitkeep
```

Current KoLmafia source lists `relay` and `data` among the permissible repository-root directories copied during Git checkout.
