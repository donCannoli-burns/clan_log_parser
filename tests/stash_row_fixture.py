import re

# Mirrors the ASH action patterns and verifies the real clan-log shape that
# originally failed: plural names and no trailing period.
took = re.compile(r"^took\\s+([0-9,]+)\\s+(.+?)[.]?$")
added = re.compile(r"^added\\s+([0-9,]+)\\s+(.+?)[.]?$")
contrib = re.compile(r"^contributed\\s+([0-9,]+)\\s+Meat[.]?$")

cases = [
    (took, "took 12 yams", 12, "yams"),
    (took, "took 492 stanky hi meins", 492, "stanky hi meins"),
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
