from pathlib import Path

p = Path(__file__).parents[1] / "relay" / "clan_log.ash"
s = p.read_text(encoding="utf-8")

checks = {
    "relay_override_fetches_original": "string raw_html = visit_url();" in s,
    "raw_html_primary_parser": "boolean parse_raw_log(string html)" in s and "if (!parse_raw_log(raw_html))" in s,
    "pstash_style_row_boundary": "<a\\\\s+[^>]*>" in s and "(?:<br\\\\s*/?>|\\\\r?\\\\n)" in s,
    "loose_meat_deposit_verbs": "(?:contributed|added|deposited|put)" in s,
    "stash_classified_by_action_shape": 'e.section = "Stash Activity";' in s,
    "uses_cached_historical_price": "historical_price(it)" in s,
    "uses_live_mall_fallback": "mall_price(it)" in s,
    "uses_autosell_floor": "autosell_price(it)" in s and 'source = "autosell-floor"' in s,
    "caches_page_prices": "page_price_cache" in s and "page_price_source_cache" in s,
    "persists_resolution_diagnostics": "resolved_item_id=" in s and "resolved_item=" in s,
    "plural_aware_item_resolution": "to_item(candidate, quantity)" in s,
    "bounded_fuzzy_resolver": "resolve_stash_item" in s and '"quantity-fuzzy"' in s and '"name-fuzzy"' in s,
    "normalizes_presentation_noise": "normalize_item_candidate" in s and 'replace_string(b, "’", "\'")' in s,
    "tracks_item_quantities": "items_taken" in s and "items_added" in s,
    "two_column_player_grid": "player-card-grid" in s and "grid-template-columns:repeat(2,minmax(0,1fr))" in s,
    "responsive_single_column_player_grid": ".player-card-grid{grid-template-columns:1fr}" in s,
    "no_send_kmail": "send_kmail(" not in s and 'cli_execute("send' not in s,
    "composer_only": "sendmessage.php?toid=" in s,
    "per_player_audit": '"player-" + id + ".tsv"' in s,
    "fail_closed_empty_parse": "if (parsed_player_lines > 0)" in s,
    "preserves_duplicate_occurrence": "occurrence=" in s,
    "accepts_optional_timestamp_colon": "\\\\s*:?\\\\s+" in s,
}

for name, ok in checks.items():
    print(f"{name}={str(ok).lower()}")

if not all(checks.values()):
    raise SystemExit(1)