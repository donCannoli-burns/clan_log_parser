import re

# Mirrors the ASH action patterns and verifies the real clan-log shape that
# originally failed: plural names and no trailing period.
took = re.compile(r"^took\\s+([0-9,]+)\\s+(.+?)[.]?$")
added = re.compile(r"^added\\s+([0-9,]+)\\s+(.+?)[.]?$")
contrib = re.compile(r"^contributed\\s+([0-9,]+)\\s+Meat[.]?$")

cases = [
    (took, "took 12 yams", 12, "yams"),
    (took, "took 7 bottles of vodka", 7, "bottles of vodka"),
    (took, "took 100 Vegetables of Jarlsberg", 100, "Vegetables of Jarlsberg"),
    (took, "took 100 cans of voodoo snuff", 100, "cans of voodoo snuff"),
    (took, "took 99 handfuls of the Yeast of Boris", 99, "handfuls of the Yeast of Boris"),
    (took, "took 30 tubs of St. Sneaky Pete's Whey", 30, "tubs of St. Sneaky Pete's Whey"),
    (took, "took 492 stanky hi meins", 492, "stanky hi meins"),
    (took, "took 496 spooky hi meins", 496, "spooky hi meins"),
    (took, "took 436 hi, hi meins (too cold, too cold)", 436, "hi, hi meins (too cold, too cold)"),
    (took, "took 485 hot hi meins", 485, "hot hi meins"),
    (took, "took 496 sleazy hi meins", 496, "sleazy hi meins"),
    (took, "took 100 extra times", 100, "extra times"),
    (took, "took 12,726 dense meat stacks", 12726, "dense meat stacks"),
    (added, "added 3 Jekyllin hide belts.", 3, "Jekyllin hide belts"),
]

for rx, text, qty, item in cases:
    m = rx.match(text)
    assert m, text
    assert int(m.group(1).replace(",", "")) == qty
    assert m.group(2) == item

for text, qty in [("contributed 50,000 Meat", 50000), ("contributed 1 Meat.", 1)]:
    m = contrib.match(text)
    assert m, text
    assert int(m.group(1).replace(",", "")) == qty

print("stash_row_fixture=true")

# pStash-inspired raw HTML row boundary. Our relay uses this shape as the
# primary parser instead of depending on reconstructed section headings.
raw_row = re.compile(
    r"(\d\d/\d\d/\d\d,\s*\d\d:\d\d(?:AM|PM))\s*:\s*<a\s+[^>]*>([^<]+)</a>\s*([^<]*?)(?:<br\s*/?>|\r?\n)"
)
meat_in = re.compile(r"^(?:contributed|added|deposited|put)\s+([0-9,]+)\s+Meat(?:\s+.*)?[.]?$")

raw_cases = [
    ('10/01/26, 06:10PM: <a href="showplayer.php?who=1">Don (#1)</a> added 12 yams.<br>', "added 12 yams."),
    ('10/01/26, 06:11PM: <a href="showplayer.php?who=1">Don (#1)</a> contributed 50,000 Meat.<br>', "contributed 50,000 Meat."),
    ('10/01/26, 06:12PM: <a href="showplayer.php?who=1">Don (#1)</a> added 25,000 Meat to the clan coffers.<br>', "added 25,000 Meat to the clan coffers."),
]
for html, expected_action in raw_cases:
    m = raw_row.search(html)
    assert m, html
    assert m.group(2) == "Don (#1)"
    assert m.group(3) == expected_action

for action, qty in [
    ("contributed 50,000 Meat.", 50000),
    ("added 25,000 Meat", 25000),
    ("deposited 1,234 Meat into the stash.", 1234),
    ("put 777 Meat in the clan coffers.", 777),
]:
    m = meat_in.match(action)
    assert m, action
    assert int(m.group(1).replace(",", "")) == qty

print("raw_clan_log_fixture=true")
