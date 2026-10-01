from pathlib import Path

p = Path(__file__).parents[1] / "relay" / "clan_log.ash"
s = p.read_text(encoding="utf-8")

checks = {
    "relay_override_fetches_original": "string raw_html = visit_url();" in s,
    "uses_cached_historical_price": "historical_price(it)" in s,
    "no_live_mall_price": "mall_price(" not in s,
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
