// clan_log.ash
// KoLmafia relay override for clan_log.php
// Clan Log Parser v0.1.0
//
// Goals:
//   - Render the clan activity log as a player-indexed audit dashboard.
//   - Estimate stash activity from KoLmafia's local mall price history only.
//   - Preserve per-player records under data/clan_logs/.
//   - Surface review candidates without making accusations.
//   - Offer a human-click KMail composer link; never send KMail automatically.
//
// Install path after KoLmafia `git checkout`:
//   relay/clan_log.ash
//
// Data files:
//   data/clan_logs/player-<id>.tsv
//   data/clan_logs/index.tsv
//
// Price source:
//   historical_price(item), backed by KoLmafia's mallprices.txt cache.
//   No live mall search is performed by this script.

string CLAN_LOG_PARSER_VERSION = "0.1.0";
string AUDIT_DIR = "clan_logs/";
string FLOOR_PREF = "clanLogAuditFloor";
int DEFAULT_FLOOR = 500000;

record audit_event {
    string timestamp;
    string section;
    string player_name;
    int player_id;
    string action;
    string item_name;
    int quantity;
    int unit_price;
    float estimated_meat;
    boolean priced;
    int occurrence;
    string raw;
};

record player_summary {
    string name;
    int id;
    int events;
    int stash_takes;
    int stash_adds;
    int unpriced_takes;
    int unpriced_adds;
    float taken_value;
    float added_value;
    float meat_contributed;
};

player_summary[int] players;
audit_event[int, int] events;
int[int] event_count;
int[string] identical_line_count;
int parsed_player_lines = 0;
int unmatched_candidate_lines = 0;

string trim_ws(string s) {
    matcher m = create_matcher("^\\s+|\\s+$", s);
    return replace_all(m, "");
}

string html_to_text(string html) {
    buffer b = html;

    b = replace_string(b, "\r", "");
    b = replace_string(b, "<br>", "\n");
    b = replace_string(b, "<br/>", "\n");
    b = replace_string(b, "<br />", "\n");
    b = replace_string(b, "</tr>", "\n");
    b = replace_string(b, "</p>", "\n");
    b = replace_string(b, "</div>", "\n");
    b = replace_string(b, "</li>", "\n");
    b = replace_string(b, "</h1>", "\n");
    b = replace_string(b, "</h2>", "\n");
    b = replace_string(b, "</h3>", "\n");

    matcher tags = create_matcher("<[^>]*>", b.to_string());
    return entity_decode(replace_all(tags, ""));
}

string meat(float n) {
    return to_string(round(n), "%,d");
}

string safe(string s) {
    return entity_encode(s);
}

string normalize_quantity(string s) {
    buffer b = s;
    b = replace_string(b, ",", "");
    return b.to_string();
}

int parse_quantity(string s) {
    return to_int(normalize_quantity(s));
}

void ensure_player(int id, string name) {
    if (!(players contains id)) {
        players[id].id = id;
        players[id].name = name;
    } else if (players[id].name == "") {
        players[id].name = name;
    }
}

void add_event(audit_event e) {
    ensure_player(e.player_id, e.player_name);
    int n = event_count[e.player_id];
    events[e.player_id, n] = e;
    event_count[e.player_id] = n + 1;
    players[e.player_id].events += 1;
}

audit_event price_stash_event(audit_event e) {
    // Keep item resolution conservative. If KoLmafia cannot resolve the clan-log
    // item text, retain the event but exclude it from the Meat estimate.
    item it = to_item(e.item_name);
    if (it == $item[none]) {
        e.priced = false;
        e.unit_price = 0;
        e.estimated_meat = 0.0;
        return e;
    }

    int p = historical_price(it);
    e.unit_price = p;
    e.priced = (p > 0);

    if (e.priced) {
        e.estimated_meat = p * e.quantity;
    } else {
        e.estimated_meat = 0.0;
    }

    return e;
}

int next_occurrence(string timestamp, string section, int id, string action) {
    string signature = timestamp + " | " + section + " | " + id + " | " + action;
    int n = identical_line_count[signature] + 1;
    identical_line_count[signature] = n;
    return n;
}

void classify_and_add(string timestamp, string section, string name, int id, string action, string raw) {
    ensure_player(id, name);

    audit_event e;
    e.timestamp = timestamp;
    e.section = section;
    e.player_name = name;
    e.player_id = id;
    e.action = action;
    e.raw = raw;
    e.item_name = "";
    e.quantity = 0;
    e.unit_price = 0;
    e.estimated_meat = 0.0;
    e.priced = false;
    e.occurrence = next_occurrence(timestamp, section, id, action);

    if (section == "Stash Activity") {
        matcher took = create_matcher("^took ([0-9,]+) (.+)\\.$", action);
        matcher added = create_matcher("^added ([0-9,]+) (.+)\\.$", action);
        matcher contrib = create_matcher("^contributed ([0-9,]+) Meat\\.$", action);

        if (find(took)) {
            e.quantity = parse_quantity(group(took, 1));
            e.item_name = group(took, 2);
            e = price_stash_event(e);

            players[id].stash_takes += 1;
            if (e.priced) {
                players[id].taken_value += e.estimated_meat;
            } else {
                players[id].unpriced_takes += 1;
            }
        } else if (find(added)) {
            e.quantity = parse_quantity(group(added, 1));
            e.item_name = group(added, 2);
            e = price_stash_event(e);

            players[id].stash_adds += 1;
            if (e.priced) {
                players[id].added_value += e.estimated_meat;
            } else {
                players[id].unpriced_adds += 1;
            }
        } else if (find(contrib)) {
            players[id].meat_contributed += parse_quantity(group(contrib, 1));
        }
    }

    add_event(e);
}

boolean section_heading(string s) {
    return s == "Clan Activity Log:" || s == "Clan Activity Log" ||
           s == "Comings and Goings:" || s == "Comings and Goings" ||
           s == "Stash Activity:" || s == "Stash Activity" ||
           s == "Miscellaneous:" || s == "Miscellaneous" ||
           s == "Basement Stuff:" || s == "Basement Stuff" ||
           s == "Lounge Activity:" || s == "Lounge Activity";
}

string normalized_section(string s) {
    if (starts_with(s, "Comings and Goings")) return "Comings and Goings";
    if (starts_with(s, "Stash Activity")) return "Stash Activity";
    if (starts_with(s, "Miscellaneous")) return "Miscellaneous";
    if (starts_with(s, "Basement Stuff")) return "Basement Stuff";
    if (starts_with(s, "Lounge Activity")) return "Lounge Activity";
    return "Clan Activity Log";
}

void parse_log(string text) {
    string section = "Clan Activity Log";
    string[int] lines = split_string(text);

    foreach i, line in lines {
        string s = trim_ws(line);
        if (s == "") continue;

        if (section_heading(s)) {
            section = normalized_section(s);
            continue;
        }

        // Accept both observed renderings:
        //   09/27/26, 09:27PM Bob Who (#3729003) took ...
        //   09/27/26, 09:27PM: Bob Who (#3729003) took ...
        matcher line_match = create_matcher(
            "^(\\d\\d/\\d\\d/\\d\\d,\\s+\\d\\d:\\d\\d(?:AM|PM))\\s*:?\\s+(.+?)\\s+\\(#(\\d+)\\)\\s+(.+)$",
            s
        );

        if (find(line_match)) {
            string timestamp = group(line_match, 1);
            string name = group(line_match, 2);
            int id = to_int(group(line_match, 3));
            string action = group(line_match, 4);
            parsed_player_lines += 1;
            classify_and_add(timestamp, section, name, id, action, s);
            continue;
        }

        // Track date-looking rows we could not parse. This is diagnostic only and
        // deliberately does not guess attribution.
        matcher looks_like_log = create_matcher("^\\d\\d/\\d\\d/\\d\\d,", s);
        if (find(looks_like_log)) unmatched_candidate_lines += 1;
    }
}

float configured_floor(string[string] fields) {
    if (get_property(FLOOR_PREF) == "") {
        set_property(FLOOR_PREF, DEFAULT_FLOOR.to_string());
    }

    if (fields contains "floor") {
        int requested = parse_quantity(fields["floor"]);
        if (requested >= 0) {
            set_property(FLOOR_PREF, requested.to_string());
        }
    }

    return to_int(get_property(FLOOR_PREF));
}

float automatic_threshold(float floor_value) {
    float[int] totals;
    foreach id, p in players {
        if (p.taken_value > 0.0) {
            totals[count(totals)] = p.taken_value;
        }
    }

    if (count(totals) < 3) return floor_value;

    sort totals by value;

    int n = count(totals);
    float median;
    if (n % 2 == 1) {
        median = totals[n / 2];
    } else {
        median = (totals[(n / 2) - 1] + totals[n / 2]) / 2.0;
    }

    float adaptive = median * 4.0;
    if (adaptive < floor_value) return floor_value;
    return adaptive;
}

float max_taken_value() {
    float result = 0.0;
    foreach id, p in players {
        if (p.taken_value > result) result = p.taken_value;
    }
    return result;
}

void persist_player_history(int id) {
    string[string] history;
    string filename = AUDIT_DIR + "player-" + id + ".tsv";

    file_to_map(filename, history);

    int n = event_count[id];
    if (n <= 0) return;

    for i from 0 to n - 1 {
        audit_event e = events[id, i];

        // occurrence preserves genuinely duplicated identical actions within the
        // same minute while remaining stable across normal page refreshes.
        string key = e.timestamp + " | " + e.section + " | " + e.action +
                     " | occurrence=" + e.occurrence;

        string value = e.player_name + " (#" + e.player_id + ") | " + e.action;

        if (e.item_name != "") {
            value += " | qty=" + e.quantity +
                     " | item=" + e.item_name +
                     " | unit_price=" + e.unit_price +
                     " | estimated_meat=" + meat(e.estimated_meat) +
                     " | priced=" + e.priced;
        }

        history[key] = value;
    }

    if (!map_to_file(history, filename)) {
        print("Clan Log Parser: could not write data/" + filename, "red");
    }
}

void persist_index(float threshold) {
    string[string] index_rows;

    foreach id, p in players {
        string key = p.name + " (#" + id + ")";
        index_rows[key] =
            "events=" + p.events +
            " | stash_takes=" + p.stash_takes +
            " | taken_value=" + meat(p.taken_value) +
            " | stash_adds=" + p.stash_adds +
            " | added_value=" + meat(p.added_value) +
            " | meat_contributed=" + meat(p.meat_contributed) +
            " | review=" + (p.taken_value >= threshold && p.taken_value > 0.0);
    }

    if (!map_to_file(index_rows, AUDIT_DIR + "index.tsv")) {
        print("Clan Log Parser: could not write data/" + AUDIT_DIR + "index.tsv", "red");
    }
}

void write_style() {
    write("<style>");
    write("body{font-family:Arial,sans-serif;background:#111;color:#eee;margin:0;padding:16px}");
    write("a{color:#7dd3fc}.wrap{max-width:1200px;margin:auto}");
    write(".top{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-bottom:14px}");
    write(".card{background:#191919;border:1px solid #333;border-radius:10px;padding:12px;margin:10px 0}");
    write(".warn{border-color:#f59e0b}.bad{border-color:#ef4444}");
    write(".muted{color:#aaa}.num{font-variant-numeric:tabular-nums}");
    write(".barbg{height:14px;background:#2a2a2a;border-radius:999px;overflow:hidden;margin:6px 0}");
    write(".bar{height:100%;background:#60a5fa}.bar.warnbar{background:#f59e0b}");
    write(".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px}");
    write(".stat{background:#141414;border:1px solid #2c2c2c;border-radius:8px;padding:8px}");
    write("details{margin-top:8px}summary{cursor:pointer}.event{padding:6px 0;border-top:1px solid #292929}");
    write(".take{color:#fca5a5}.add{color:#86efac}.pill{display:inline-block;border:1px solid #444;border-radius:999px;padding:2px 7px;margin-left:6px}");
    write("input{background:#0d0d0d;color:#eee;border:1px solid #444;border-radius:6px;padding:5px}");
    write("button,.button{display:inline-block;background:#222;color:#fff;border:1px solid #555;border-radius:7px;padding:6px 10px;text-decoration:none}");
    write("code{color:#d8b4fe}");
    write("</style>");
}

void write_player_card(int id, player_summary p, float threshold, float max_taken) {
    boolean flagged = p.taken_value >= threshold && p.taken_value > 0.0;
    float pct = 0.0;
    if (max_taken > 0.0) pct = (p.taken_value / max_taken) * 100.0;

    write("<section class='card");
    if (flagged) write(" warn");
    write("' id='player-" + id + "'>");

    write("<h2>");
    write("<a href='showplayer.php?who=" + id + "'>" + safe(p.name) + "</a>");
    write(" <span class='muted'>(#" + id + ")</span>");
    if (flagged) write(" <span class='pill'>REVIEW</span>");
    write("</h2>");

    write("<div class='barbg'><div class='bar");
    if (flagged) write(" warnbar");
    write("' style='width:" + round(pct) + "%'></div></div>");

    write("<div class='grid'>");
    write("<div class='stat'><b>Estimated taken</b><br><span class='num'>" + meat(p.taken_value) + " Meat</span></div>");
    write("<div class='stat'><b>Estimated added</b><br><span class='num'>" + meat(p.added_value) + " Meat</span></div>");
    write("<div class='stat'><b>Direct Meat contributed</b><br><span class='num'>" + meat(p.meat_contributed) + " Meat</span></div>");
    write("<div class='stat'><b>Stash actions</b><br>" + p.stash_takes + " took / " + p.stash_adds + " added</div>");
    write("</div>");

    if (p.unpriced_takes > 0 || p.unpriced_adds > 0) {
        write("<p class='muted'>Unpriced from local mall cache: " +
              p.unpriced_takes + " withdrawal(s), " +
              p.unpriced_adds + " addition(s). These are not counted in totals.</p>");
    }

    if (flagged) {
        write("<p><a class='button' href='sendmessage.php?toid=" + id + "'>Open KMail to " + safe(p.name) + "</a>");
        write(" <span class='muted'>Composer only; this script never sends.</span></p>");
    }

    write("<details><summary>Activity timeline (" + p.events + ")</summary>");

    int n = event_count[id];
    if (n > 0) {
        for i from 0 to n - 1 {
            audit_event e = events[id, i];
            write("<div class='event'>");
            write("<b>" + safe(e.timestamp) + "</b> ");
            write("<span class='muted'>" + safe(e.section) + "</span><br>");
            string css = "";
            if (starts_with(e.action, "took ")) css = " class='take'";
            else if (starts_with(e.action, "added ")) css = " class='add'";
            write("<span" + css + ">" + safe(e.action) + "</span>");

            if (e.item_name != "") {
                if (e.priced) {
                    write("<br><span class='muted'>Local cached price: " +
                          meat(e.unit_price) + " x " + e.quantity +
                          " = <b>" + meat(e.estimated_meat) + " Meat</b></span>");
                } else {
                    write("<br><span class='muted'>No usable local mall price; excluded from total.</span>");
                }
            }
            write("</div>");
        }
    }

    write("</details>");
    write("</section>");
}

void write_parse_diagnostics() {
    if (parsed_player_lines > 0 && unmatched_candidate_lines == 0) return;

    write("<section class='card bad'><h2>Parser diagnostics</h2>");
    write("<p>Parsed player-attributed lines: <b>" + parsed_player_lines + "</b>. ");
    write("Date-looking lines not attributed: <b>" + unmatched_candidate_lines + "</b>.</p>");

    if (parsed_player_lines == 0) {
        write("<p><b>No audit files were updated.</b> The page format may have changed, the account may not have access, or the page may not be a clan log.</p>");
    } else if (unmatched_candidate_lines > 0) {
        write("<p class='muted'>Unmatched rows remain visible in the Raw clan log. The parser does not guess player identity.</p>");
    }
    write("</section>");
}

void main() {
    // For relay/clan_log.ash, no-argument visit_url() retrieves the original
    // clan_log.php response rather than recursively invoking this override.
    string raw_html = visit_url();
    string[string] fields = form_fields();

    if ((fields contains "raw") && fields["raw"] == "1") {
        write(raw_html);
        return;
    }

    parse_log(html_to_text(raw_html));

    float floor_value = configured_floor(fields);
    float threshold = automatic_threshold(floor_value);
    float max_taken = max_taken_value();

    // Fail closed for persistence: a broken/changed clan page must not erase the
    // previous index or replace it with an empty parse.
    if (parsed_player_lines > 0) {
        foreach id, p in players {
            persist_player_history(id);
        }
        persist_index(threshold);
    }

    int[int] ranked_ids;
    foreach id, p in players {
        ranked_ids[count(ranked_ids)] = id;
    }
    sort ranked_ids by -players[value].taken_value;

    write("<!doctype html><html><head><meta charset='utf-8'>");
    write("<title>Clan Activity Audit</title>");
    write_style();
    write("</head><body><div class='wrap'>");

    write("<h1>Clan Activity Audit</h1>");
    write("<div class='top'>");
    write("<a class='button' href='clan_log.php?raw=1'>Raw clan log</a>");
    write("<a class='button' href='clan_log.php'>Refresh</a>");
    write("<span class='muted'>v" + CLAN_LOG_PARSER_VERSION + " | prices: local KoLmafia historical cache only</span>");
    write("</div>");

    write_parse_diagnostics();

    write("<section class='card'>");
    write("<h2>Review threshold</h2>");
    write("<p><b>" + meat(threshold) + " Meat</b> - the larger of your configured floor and 4x the median nonzero player withdrawal total. ");
    write("If fewer than three players have priced withdrawals, the configured floor is used.</p>");

    write("<form method='GET' action='clan_log.php'>");
    write("Configured floor: <input name='floor' value='" + meat(floor_value) + "' size='14'> ");
    write("<button type='submit'>Update floor</button>");
    write("</form>");

    write("<p class='muted'>A REVIEW badge is an accounting flag, not an accusation. ");
    write("Unresolved or missing-cache items remain visible but are excluded from the Meat estimate.</p>");
    write("</section>");

    write("<section class='card'>");
    write("<h2>Player index</h2>");
    if (count(ranked_ids) == 0) {
        write("<p class='muted'>No player-attributed rows were parsed.</p>");
    } else {
        write("<div class='grid'>");
        foreach i, id in ranked_ids {
            player_summary p = players[id];
            write("<div class='stat'><a href='#player-" + id + "'>" + safe(p.name) + "</a>");
            write("<br><span class='num'>" + meat(p.taken_value) + " Meat taken</span>");
            if (p.taken_value >= threshold && p.taken_value > 0.0) write(" <span class='pill'>REVIEW</span>");
            write("</div>");
        }
        write("</div>");
    }
    write("</section>");

    foreach i, id in ranked_ids {
        write_player_card(id, players[id], threshold, max_taken);
    }

    write("<section class='card'>");
    write("<h2>Audit files</h2>");
    write("<p>Per-player records: <code>data/clan_logs/player-&lt;id&gt;.tsv</code><br>");
    write("Current rollup: <code>data/clan_logs/index.tsv</code></p>");
    write("<p class='muted'>Git checkout installs an empty <code>data/clan_logs/</code> directory marker so the record path exists before first render.</p>");
    write("</section>");

    write("</div></body></html>");
}
