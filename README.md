# clan_log_parser

A standalone KoLmafia relay override for `clan_log.php` that turns the clan activity log into a player-indexed audit dashboard.

## What it does

- Groups player-attributed clan activity by player ID.
- Prices stash additions and withdrawals with KoLmafia's **local historical mall-price cache** via `historical_price(item)`; it does not perform live Mall searches.
- Computes an accounting review threshold as `max(configured floor, 4 x median nonzero player withdrawal total)`; the default floor is 500,000 Meat.
- Keeps per-player records in `data/clan_logs/player-<id>.tsv` and a current `data/clan_logs/index.tsv` rollup.
- Preserves repeated identical actions in the same minute using an occurrence ordinal instead of collapsing them.
- Shows a **REVIEW** badge as an accounting flag, not an accusation.
- For a flagged player, offers an **Open KMail** link to the normal KoL composer. The script never sends KMail automatically.
- Refuses to overwrite audit files when zero player-attributed log rows parse, so a page-format/access failure does not erase the previous index.

## Install with KoLmafia Git

In the KoLmafia gCLI:

```text
git checkout https://github.com/donCannoli-burns/clan_log_parser.git main
```

KoLmafia's Git installer syncs repository-root `relay/` and `data/` content into the corresponding KoLmafia directories. The installed relay override is therefore:

```text
relay/clan_log.ash
```

The repository also carries `data/clan_logs/.gitkeep` so KoLmafia creates the audit directory during checkout.

Enable relay override scripts, then open:

```text
http://127.0.0.1:60080/clan_log.php
```

## First KoLmafia check

Run a syntax check in your local KoLmafia build before relying on the page:

```text
verify relay/clan_log.ash
```

If your build resolves relay scripts by basename, `verify clan_log.ash` is also worth trying. The real acceptance check is a render of `clan_log.php` against your account because KoLmafia's ASH parser and KoL's live clan-log markup are the authorities.

## Safety / authority boundary

This tool is an audit UI. It reads the clan log, reads cached prices, writes local audit files/preferences, and opens ordinary KoL links. It does **not** withdraw from the stash, distribute clan loot, alter clan membership, or send messages.

The KMail action intentionally stops at the human-operated composer.

## Pricing caveat

`historical_price(item)` uses KoLmafia's locally cached mall-price history. Missing or unresolved prices remain visible as unpriced events and are excluded from Meat totals. The result is an estimate, not a valuation guarantee.

## Updating / removing

```text
git update
git delete donCannoli-burns-clan_log_parser-main
```

Use `git list` as the authority for the installed project identifier on your KoLmafia build.
