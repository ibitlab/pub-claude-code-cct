# pricing.jq — shared jq helpers for the cct cost scripts.
#
# The price table itself is pricing.json. Each bash script loads both files
# like this, so the JSON becomes a `pricing` definition in front of these:
#
#   JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")
#   jq -s "$JQ_DEFS"'  … your program using price / cost_of / priced …  '
#
# Nothing here needs editing when prices change — edit pricing.json.

# Price record for a model id. Rules are tried in order; the first whose
# regex matches wins; the last rule (empty regex) is the fallback.
def price(mdl):
  (mdl // "") as $m
  | ( first(pricing.rules[] | select(.match as $re | $m | test($re))) // pricing.rules[-1] )
  | { inp: .input, out: .output, rd: .cache_read, c5: .cache_5m, c1: .cache_1h };

# USD for one `usage` object at price record p.
def cost_of(u; p):
  ( (u.input_tokens               // 0) * p.inp
  + (u.output_tokens              // 0) * p.out
  + (u.cache_read_input_tokens    // 0) * p.rd
  + (u.cache_creation.ephemeral_5m_input_tokens // 0) * p.c5
  + (u.cache_creation.ephemeral_1h_input_tokens // 0) * p.c1
  ) / 1e6;

# Claude Code writes one transcript line per content block of an API message
# (thinking, text, each tool_use), and every line repeats the whole message
# usage. Keep one line per message or costs come out 2-3x too high.
def msg_id: .message.id // .requestId // .uuid // tojson;
def priced: [ .[] | select(.type=="assistant" and .message.usage) ]
            | group_by(msg_id) | map(last);

# After /compact Claude Code re-appends the whole conversation: exact copies
# of earlier lines with the same uuid. First occurrence wins, order is kept
# (unlike unique_by, which sorts). Input: an array of events.
def dedup_events:
  reduce .[] as $e ({seen: {}, out: []};
    ($e.uuid // ($e | tojson)) as $k
    | if .seen[$k] then . else .seen[$k] = true | .out += [$e] end)
  | .out;
