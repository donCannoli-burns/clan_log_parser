// clan_log.ash
// KoLmafia relay override for clan_log.php
// Clan Log Parser v0.2.2
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
//   historical_price(item) first; mall_price(item) when no usable cached quote;
//   autosell_price(item) is the final non-market floor when the Mall has no quote.
//   Results are cached per item for the page render.

string CLAN_LOG_PARSER_VERSION = "0.2.2";
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
    string price_source;
    int resolved_item_id;
    string resolved_item_name;
    int occurrence;
    string raw;
};

record player_summary {
    string name;
    int id;
    int events;
    int stash_takes;
    int stash_adds;
    int items_taken;
    int items_added;
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
int[item] page_price_cache;
string[item] page_price_source_cache;

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

string js_safe(string s) {
    buffer b = s;
    b = replace_string(b, "\\", "\\\\");
    b = replace_string(b, "\"", "\\\"");
    b = replace_string(b, "\n", "\\n");
    b = replace_string(b, "\r", "");
    b = replace_string(b, "<", "\\u003c");
    b = replace_string(b, ">", "\\u003e");
    return b.to_string();
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
    // Clan logs render plural item names for quantities > 1. The two-argument
    // to_item(string, int) form is the same quantity-aware resolution strategy
    // KoLmafia uses for plural result text.
    item it = to_item(e.item_name, e.quantity);
    if (it == $item[none]) {
        e.priced = false;
        e.price_source = "unresolved";
        e.unit_price = 0;
        e.estimated_meat = 0.0;
        return e;
    }

    e.resolved_item_id = to_int(it);
    e.resolved_item_name = to_string(it);

    if (page_price_cache contains it) {
        e.unit_price = page_price_cache[it];
        e.price_source = page_price_source_cache[it];
        e.priced = (e.unit_price > 0);
        e.estimated_meat = e.priced ? e.unit_price * 1.0 * e.quantity : 0.0;
        return e;
    }

    int p = historical_price(it);
    string source = "historical";

    if (p <= 0 && is_tradeable(it)) {
        // Current KoLmafia can return -1 when a Mall search finds no usable
        // listings, not merely 0. Treat every non-positive result as no quote.
        p = mall_price(it);
        source = "mall";
    }

    if (p <= 0) {
        // A missing Mall quote does not mean the item has no Meat value. Use the
        // built-in autosell value as a clearly labelled floor rather than
        // collapsing the dashboard total to zero.
        p = autosell_price(it);
        source = "autosell-floor";
    }

    if (p <= 0) {
        p = 0;
        source = "none";
    }

    page_price_cache[it] = p;
    page_price_source_cache[it] = source;

    e.unit_price = p;
    e.price_source = source;
    e.priced = (p > 0);
    e.estimated_meat = e.priced ? p * 1.0 * e.quantity : 0.0;
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
    e.price_source = "none";
    e.resolved_item_id = 0;
    e.resolved_item_name = "";
    e.occurrence = next_occurrence(timestamp, section, id, action);

    if (section == "Stash Activity") {
        // Current KoL clan-log rows do not consistently end in punctuation.
        // Accept both:
        //   took 12 yams
        //   took 12 yams.
        matcher took = create_matcher("^took\\s+([0-9,]+)\\s+(.+?)[.]?$", action);
        matcher added = create_matcher("^added\\s+([0-9,]+)\\s+(.+?)[.]?$", action);
        matcher contrib = create_matcher("^contributed\\s+([0-9,]+)\\s+Meat[.]?$", action);

        if (find(took)) {
            e.quantity = parse_quantity(group(took, 1));
            e.item_name = group(took, 2);
            e = price_stash_event(e);

            players[id].stash_takes += 1;
            players[id].items_taken += e.quantity;
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
            players[id].items_added += e.quantity;
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
                     " | priced=" + e.priced +
                     " | price_source=" + e.price_source +
                     " | resolved_item_id=" + e.resolved_item_id +
                     " | resolved_item=" + e.resolved_item_name;
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
            " | items_taken=" + p.items_taken +
            " | taken_value=" + meat(p.taken_value) +
            " | stash_adds=" + p.stash_adds +
            " | items_added=" + p.items_added +
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
    write(":root{--paper:#eee9da;--paper2:#e4decc;--ink:#171914;--muted:#66685d;--line:#a7a693;--accent:#6d5bd0;--accent2:#5547ab;--warn:#8b433b;--add:#43634c;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace;--serif:Georgia,'Times New Roman',serif}");
    write("*{box-sizing:border-box}");
    write("html{background:var(--paper);color:var(--ink);scroll-behavior:smooth}");
    write("body{margin:0;background:linear-gradient(rgba(23,25,20,.04) 1px,transparent 1px),var(--paper);background-size:100% 30px,auto;color:var(--ink);font-family:var(--serif);line-height:1.5}");
    write("a{color:var(--accent2)}.wrap{width:min(1380px,calc(100% - 34px));margin:0 auto;padding:28px 0 70px}");
    write(".masthead{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:24px;align-items:end;padding:14px 0 22px;border-bottom:3px double #777969}");
    write(".kicker,.eyebrow,.micro,.meta,.button,select,label,.pill,summary,code{font-family:var(--mono)}");
    write(".kicker{font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent2);margin-bottom:8px}");
    write("h1{font-size:clamp(42px,7vw,86px);line-height:.9;letter-spacing:-.055em;font-weight:500;margin:0}h2{font-size:clamp(25px,3vw,38px);font-weight:500;letter-spacing:-.035em;margin:0 0 12px}");
    write(".top{display:flex;gap:14px;flex-wrap:wrap;align-items:center;justify-content:flex-end}.button{display:inline-block;border:0;border-bottom:2px solid var(--accent);background:transparent;color:#302969;padding:7px 2px 5px;text-decoration:none;font-size:10px;letter-spacing:.08em;text-transform:uppercase;cursor:pointer}.button:hover,.button:focus-visible{padding-left:7px;padding-right:7px;outline:1px dotted var(--accent)}");
    write(".muted{color:var(--muted)}.num{font-variant-numeric:tabular-nums}.meta{font-size:10px;letter-spacing:.05em;color:var(--muted)}");
    write(".card,.chart-section{background:transparent;border:0;border-top:1px solid var(--line);padding:22px 0;margin:0}.card.warn{border-top:3px double var(--warn)}.card.bad{border-top:3px double var(--warn)}");
    write(".section-head{display:grid;grid-template-columns:160px minmax(0,1fr);gap:22px;align-items:start;margin-bottom:16px}.eyebrow{font-size:9px;letter-spacing:.14em;text-transform:uppercase;color:#74766d;padding-top:7px}");
    write(".ledger-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border-top:1px solid var(--line);border-bottom:1px solid var(--line)}");
    write(".stat{padding:13px 14px;background:rgba(255,255,255,.18);border-right:1px solid var(--line);min-height:78px}.stat:last-child{border-right:0}.stat b{font-weight:500}.stat .num{font-size:21px;color:#302969}");
    write(".barbg{height:5px;background:rgba(23,25,20,.10);overflow:hidden;margin:12px 0 16px}.bar{height:100%;background:var(--accent)}.bar.warnbar{background:var(--warn)}");
    write("details{margin-top:14px;border-top:1px dotted var(--line);padding-top:10px}summary{cursor:pointer;font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:#4f514a}");
    write(".event{padding:10px 0;border-top:1px dotted rgba(23,25,20,.18)}.event:first-of-type{margin-top:8px}.take{color:#7e342e}.add{color:#35563e}.pill{display:inline-block;border-bottom:1px solid currentColor;padding:1px 0;margin-left:7px;font-size:9px;letter-spacing:.09em;text-transform:uppercase;color:var(--warn)}");
    write("input,select{background:rgba(255,255,255,.22);color:var(--ink);border:1px solid #999988;border-radius:0;padding:8px 9px}input:focus,select:focus{outline:2px solid rgba(109,91,208,.25);border-color:var(--accent)}");
    write("code{color:#302969;font-size:.92em}");
    write(".threshold-form{display:flex;gap:9px;align-items:center;flex-wrap:wrap}.threshold-form label{font-size:9px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}");
    write(".chart-shell{position:relative;background:rgba(255,255,255,.20);border-top:3px double #777969;border-bottom:1px solid rgba(23,25,20,.28);padding:15px 16px 12px}.chart-toolbar{display:grid;grid-template-columns:minmax(0,1fr) minmax(260px,420px);gap:18px;align-items:end;margin-bottom:12px}.chart-toolbar p{margin:4px 0 0;color:#51544b;max-width:760px}.chart-controls{display:grid;grid-template-columns:1fr auto;gap:8px;align-items:end}.chart-controls label{display:block;font-size:9px;letter-spacing:.13em;text-transform:uppercase;color:#74766d;margin-bottom:5px}.chart-controls select{width:100%;min-width:0}.index-link{align-self:end;white-space:nowrap}.chart-wrap{position:relative;height:330px}.chart-wrap canvas{display:block;width:100%;height:100%}.chart-empty{position:absolute;inset:0;display:none;place-items:center;color:var(--muted);font-style:italic}.chart-note{display:flex;justify-content:space-between;gap:18px;flex-wrap:wrap;border-top:1px dotted var(--line);padding-top:9px;margin-top:8px;font:10px/1.5 var(--mono);color:var(--muted)}");
    write(".player-ledgers-head{display:grid;grid-template-columns:160px minmax(0,1fr);gap:22px;align-items:end;padding:28px 0 12px;border-top:3px double #777969}.player-ledgers-head p{margin:0;color:var(--muted)}.player-card-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;align-items:start}.player-card-grid>.card{margin:0;padding:18px 0}.player-card-grid .ledger-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.player-card-grid .stat:nth-child(2n){border-right:0}.player-card-grid .stat:nth-child(-n+2){border-bottom:1px solid var(--line)}");
    write("@media(max-width:880px){.masthead,.section-head,.player-ledgers-head,.chart-toolbar{grid-template-columns:1fr}.top{justify-content:flex-start}.player-card-grid{grid-template-columns:1fr}.ledger-grid{grid-template-columns:repeat(2,1fr)}.stat:nth-child(2){border-right:0}.stat:nth-child(-n+2){border-bottom:1px solid var(--line)}.chart-controls{grid-template-columns:1fr}.chart-wrap{height:285px}}");
    write("@media(max-width:560px){.wrap{width:min(100% - 18px,1380px);padding-top:16px}.ledger-grid,.player-card-grid .ledger-grid{grid-template-columns:1fr}.stat,.player-card-grid .stat{border-right:0;border-bottom:1px solid var(--line)}.stat:last-child,.player-card-grid .stat:last-child{border-bottom:0}.chart-wrap{height:250px}h1{font-size:46px}}");
    write("@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}.button{transition:none}}");
    write("</style>");
}


void write_withdrawal_chart(int[int] ranked_ids, float threshold) {
    float total_taken = 0.0;
    int total_items_taken = 0;
    foreach id, p in players {
        total_taken += p.taken_value;
        total_items_taken += p.items_taken;
    }

    write("<section class='chart-section' id='withdrawal-signal'>");
    write("<div class='chart-shell'>");
    write("<div class='chart-toolbar'>");
    write("<div><div class='eyebrow'>Withdrawal signal / priced item flow</div>");
    write("<h2>Stash withdrawal line</h2>");
    write("<p>Daily estimated Meat removed from the stash. Use the player index to isolate one member; sharp peaks stay visually obvious instead of being buried in a ranked card list.</p></div>");
    write("<div class='chart-controls'><div><label for='playerSelect'>Player index</label><select id='playerSelect'>");
    write("<option value='0'>All players — " + meat(total_taken) + " Meat / " + total_items_taken + " item(s)</option>");
    foreach i, id in ranked_ids {
        player_summary p = players[id];
        write("<option value='" + id + "'>" + safe(p.name) + " (#" + id + ") — " + meat(p.taken_value) + " Meat / " + p.items_taken + " item(s)</option>");
    }
    write("</select></div><a class='button index-link' id='playerJump' href='#player-ledgers'>Browse ledgers ↓</a></div>");
    write("</div>");

    write("<div class='chart-wrap'><canvas id='withdrawalChart' aria-label='Estimated stash withdrawals over time'></canvas><div id='chartEmpty' class='chart-empty'>No priced withdrawal points for this selection.</div></div>");
    write("<div class='chart-note'><span id='chartMeta'>Building withdrawal signal…</span><span>Review threshold: " + meat(threshold) + " Meat · valuation: historical → Mall → autosell floor</span></div>");
    write("</div>");
    write("</section>");

    write("<script>");
    write("(function(){");
    write("const events=[");
    boolean first = true;
    foreach id, p in players {
        int n = event_count[id];
        if (n > 0) {
            for i from 0 to n - 1 {
                audit_event e = events[id, i];
                if (starts_with(e.action, "took ") && e.item_name != "") {
                    if (!first) write(",");
                    first = false;
                    write("{t:\"" + js_safe(e.timestamp) + "\",playerId:" + id +
                          ",player:\"" + js_safe(e.player_name) + "\",value:" + round(e.estimated_meat) +
                          ",priced:" + e.priced + ",item:\"" + js_safe(e.item_name) + "\",qty:" + e.quantity + "}");
                }
            }
        }
    }
    write("];");
    write("const threshold=" + round(threshold) + ";");
    write("const canvas=document.getElementById('withdrawalChart'),select=document.getElementById('playerSelect'),meta=document.getElementById('chartMeta'),empty=document.getElementById('chartEmpty'),jump=document.getElementById('playerJump');");
    write("if(!canvas||!select)return;const ctx=canvas.getContext('2d');");
    write("function money(n){if(n>=1e9)return (n/1e9).toFixed(n>=1e10?0:1)+'B';if(n>=1e6)return (n/1e6).toFixed(n>=1e7?0:1)+'M';if(n>=1e3)return (n/1e3).toFixed(n>=1e4?0:1)+'K';return Math.round(n).toLocaleString();}");
    write("function dayNum(k){const a=k.split('/');return Date.UTC(2000+Number(a[2]),Number(a[0])-1,Number(a[1]));}");
    write("function keyFromMs(ms){const d=new Date(ms),m=String(d.getUTCMonth()+1).padStart(2,'0'),day=String(d.getUTCDate()).padStart(2,'0'),y=String(d.getUTCFullYear()).slice(-2);return m+'/'+day+'/'+y;}");
    write("function labelDay(k){const a=k.split('/'),d=new Date(Date.UTC(2000+Number(a[2]),Number(a[0])-1,Number(a[1])));return d.toLocaleDateString(undefined,{month:'short',day:'numeric',timeZone:'UTC'});}");
    write("function niceMax(v){if(v<=0)return 1;const p=Math.pow(10,Math.floor(Math.log10(v))),n=v/p;const step=n<=1?1:n<=2?2:n<=5?5:10;return step*p;}");
    write("function series(){const id=Number(select.value)||0,scoped=events.filter(e=>!id||e.playerId===id),priced=scoped.filter(e=>e.priced&&e.value>0),unpriced=scoped.filter(e=>!e.priced),map=new Map();priced.forEach(e=>{const k=e.t.slice(0,8);map.set(k,(map.get(k)||0)+e.value);});const keys=[...map.keys()].sort((a,b)=>dayNum(a)-dayNum(b));if(!keys.length)return {rows:[],priced:priced.length,unpriced:unpriced.length};const rows=[];for(let ms=dayNum(keys[0]);ms<=dayNum(keys[keys.length-1]);ms+=86400000){const k=keyFromMs(ms);rows.push({k,value:map.get(k)||0});}return {rows,priced:priced.length,unpriced:unpriced.length};}");
    write("function draw(){const s=series(),rows=s.rows,box=canvas.getBoundingClientRect(),w=Math.max(320,box.width),h=Math.max(220,box.height),dpr=Math.max(1,window.devicePixelRatio||1);canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);empty.style.display=rows.length?'none':'grid';const id=Number(select.value)||0,option=select.options[select.selectedIndex],name=id?option.text.split(' (#')[0]:'All players';jump.href=id?'#player-'+id:'#player-ledgers';jump.textContent=id?'Open '+name+' ledger ↓':'Browse player ledgers ↓';if(!rows.length){meta.textContent=name+' · 0 priced withdrawals · '+s.unpriced+' unpriced';return;}");
    write("const pad={l:66,r:18,t:24,b:44},pw=w-pad.l-pad.r,ph=h-pad.t-pad.b,maxData=Math.max(...rows.map(r=>r.value)),yMax=niceMax(maxData*1.08||1);ctx.font='10px ui-monospace,SFMono-Regular,Menlo,monospace';ctx.textBaseline='middle';");
    write("for(let i=0;i<=4;i++){const y=pad.t+ph*(i/4),v=yMax*(1-i/4);ctx.beginPath();ctx.strokeStyle='rgba(23,25,20,.16)';ctx.lineWidth=1;ctx.moveTo(pad.l,y);ctx.lineTo(w-pad.r,y);ctx.stroke();ctx.fillStyle='#66685d';ctx.textAlign='right';ctx.fillText(money(v),pad.l-9,y);}");
    write("const count=rows.length,x=(i)=>pad.l+(count===1?pw/2:(i/(count-1))*pw),y=(v)=>pad.t+ph-(v/yMax)*ph;");
    write("const tickCount=Math.min(6,count);for(let j=0;j<tickCount;j++){const i=tickCount===1?0:Math.round(j*(count-1)/(tickCount-1));ctx.fillStyle='#66685d';ctx.textAlign='center';ctx.textBaseline='top';ctx.fillText(labelDay(rows[i].k),x(i),h-pad.b+10);}");
    write("if(threshold>0&&threshold<=yMax){const ty=y(threshold);ctx.save();ctx.setLineDash([5,5]);ctx.strokeStyle='rgba(139,67,59,.75)';ctx.beginPath();ctx.moveTo(pad.l,ty);ctx.lineTo(w-pad.r,ty);ctx.stroke();ctx.restore();ctx.fillStyle='#8b433b';ctx.textAlign='left';ctx.textBaseline='bottom';ctx.fillText('review '+money(threshold),pad.l+5,ty-3);}");
    write("ctx.beginPath();rows.forEach((r,i)=>{const xx=x(i),yy=y(r.value);if(i===0)ctx.moveTo(xx,yy);else ctx.lineTo(xx,yy);});ctx.strokeStyle='#6d5bd0';ctx.lineWidth=2;ctx.stroke();");
    write("rows.forEach((r,i)=>{if(r.value<=0)return;ctx.beginPath();ctx.fillStyle='#eee9da';ctx.strokeStyle='#6d5bd0';ctx.lineWidth=1.5;ctx.arc(x(i),y(r.value),3.2,0,Math.PI*2);ctx.fill();ctx.stroke();});");
    write("let peak=rows[0],peakIndex=0;rows.forEach((r,i)=>{if(r.value>peak.value){peak=r;peakIndex=i;}});if(peak.value>0){const px=x(peakIndex),py=y(peak.value);ctx.beginPath();ctx.fillStyle='#6d5bd0';ctx.arc(px,py,4.8,0,Math.PI*2);ctx.fill();ctx.fillStyle='#302969';ctx.textAlign=px>w*.72?'right':'left';ctx.textBaseline='bottom';ctx.fillText(money(peak.value)+' · '+labelDay(peak.k),px+(px>w*.72?-8:8),Math.max(14,py-7));}");
    write("const thresholdNote=threshold>yMax?' · review threshold off-scale':'';meta.textContent=name+' · peak '+money(peak.value)+' Meat on '+labelDay(peak.k)+' · '+s.priced+' priced withdrawal action(s) · '+s.unpriced+' unpriced'+thresholdNote;");
    write("}");
    write("select.addEventListener('change',draw);window.addEventListener('resize',draw);draw();");
    write("})();");
    write("</script>");
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

    write("<div class='ledger-grid'>");
    write("<div class='stat'><b>Estimated taken</b><br><span class='num'>" + meat(p.taken_value) + " Meat</span><br><span class='meta'>" + p.items_taken + " item(s) / " + p.stash_takes + " withdrawal action(s)</span></div>");
    write("<div class='stat'><b>Estimated added</b><br><span class='num'>" + meat(p.added_value) + " Meat</span><br><span class='meta'>" + p.items_added + " item(s) / " + p.stash_adds + " addition action(s)</span></div>");
    write("<div class='stat'><b>Direct Meat contributed</b><br><span class='num'>" + meat(p.meat_contributed) + " Meat</span></div>");
    write("<div class='stat'><b>Unpriced item actions</b><br><span class='num'>" + (p.unpriced_takes + p.unpriced_adds) + "</span><br><span class='meta'>" + p.unpriced_takes + " took / " + p.unpriced_adds + " added</span></div>");
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
                    write("<br><span class='muted'>Resolved <b>" +
                          safe(e.resolved_item_name) + "</b> (#" + e.resolved_item_id + ") · " +
                          meat(e.unit_price) + " x " + e.quantity +
                          " = <b>" + meat(e.estimated_meat) + " Meat</b> · " +
                          safe(e.price_source) + "</span>");
                } else {
                    write("<br><span class='muted'>Parsed item: <b>" + e.quantity + " " + safe(e.item_name) + "</b>. " +
                          (e.resolved_item_id > 0 ? "Resolved as #" + e.resolved_item_id + " " + safe(e.resolved_item_name) + ", but no historical, Mall, or autosell value was available." : "KoLmafia could not resolve this display name to an item.") +
                          "</span>");
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

    write("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>");
    write("<title>Clan Activity Audit</title>");
    write_style();
    write("</head><body><div class='wrap'>");

    write("<header class='masthead'><div>");
    write("<div class='kicker'>04C / Archival editorial · canonical guardrails</div>");
    write("<h1>Clan Activity Audit</h1></div>");
    write("<div class='top'>");
    write("<a class='button' href='clan_log.php?raw=1'>Raw clan log</a>");
    write("<a class='button' href='clan_log.php'>Refresh</a>");
    write("<span class='meta'>v" + CLAN_LOG_PARSER_VERSION + " · valuation: historical → Mall → autosell floor</span>");
    write("</div></header>");

    write_parse_diagnostics();

    if (count(ranked_ids) == 0) {
        write("<section class='chart-section'><div class='chart-shell'><h2>Stash withdrawal line</h2><p class='muted'>No player-attributed rows were parsed.</p></div></section>");
    } else {
        write_withdrawal_chart(ranked_ids, threshold);
    }

    write("<section class='card'>");
    write("<div class='section-head'><div class='eyebrow'>Review threshold</div><div>");
    write("<h2>" + meat(threshold) + " Meat</h2>");
    write("<p>The larger of your configured floor and 4x the median nonzero player withdrawal total. If fewer than three players have priced withdrawals, the configured floor is used.</p>");
    write("<form class='threshold-form' method='GET' action='clan_log.php'>");
    write("<label for='floor'>Configured floor</label><input id='floor' name='floor' value='" + meat(floor_value) + "' size='14'> ");
    write("<button class='button' type='submit'>Update floor</button>");
    write("</form>");
    write("<p class='muted'>A REVIEW marker is an accounting flag, not an accusation. Unresolved or missing-cache items stay visible but are excluded from the Meat estimate.</p>");
    write("</div></div></section>");

    write("<div class='player-ledgers-head' id='player-ledgers'><div class='eyebrow'>Player ledgers</div><div><h2>Per-player activity</h2><p>The dropdown above is the player index; use it to filter the line, then jump directly to that member's ledger.</p></div></div>");

    write("<div class='player-card-grid'>");
    foreach i, id in ranked_ids {
        write_player_card(id, players[id], threshold, max_taken);
    }
    write("</div>");

    write("<section class='card'>");
    write("<div class='section-head'><div class='eyebrow'>Audit files</div><div><h2>Persistent records</h2>");
    write("<p>Per-player records: <code>data/clan_logs/player-&lt;id&gt;.tsv</code><br>");
    write("Current rollup: <code>data/clan_logs/index.tsv</code></p>");
    write("<p class='muted'>Git checkout installs an empty <code>data/clan_logs/</code> directory marker so the record path exists before first render.</p>");
    write("</div></div></section>");

    write("</div></body></html>");
}