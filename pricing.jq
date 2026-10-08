# pricing.jq — shared jq helpers for the cct cost scripts.
#
# The price table itself is pricing.json. Each bash script loads both files
# like this, so the JSON becomes a `pricing` definition in front of these:
#
#   JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")
#   jq -s "$JQ_DEFS"'  … your program using price / cost_of / priced …  '
#
# Nothing here needs editing when prices change — edit pricing.json.

def _prec: { inp: .input, out: .output, rd: .cache_read, c5: .cache_5m, c1: .cache_1h };

# Price record for a model id. Rules are tried in order; the first whose
# regex matches wins; the last rule (empty regex) is the fallback. `long`
# is the rule's long_prompt set (with its `over` threshold) or null.
def price(mdl):
  (mdl // "") as $m
  | ( first(pricing.rules[] | select(.match as $re | $m | test($re))) // pricing.rules[-1] )
  | _prec + { long: (.long_prompt | if . then _prec + { over } else null end) };

# Prompt size of one request: everything that went in, cached or not.
def prompt_tokens(u):
  (u.input_tokens // 0) + (u.cache_read_input_tokens // 0)
  + (u.cache_creation_input_tokens
     // ((u.cache_creation.ephemeral_5m_input_tokens // 0)
         + (u.cache_creation.ephemeral_1h_input_tokens // 0)));

# USD per token class for one `usage` object at price record p — the long
# prompt set when this request's prompt is over its threshold.
def costs_of(u; p):
  (if p.long and prompt_tokens(u) > p.long.over then p.long else p end) as $q
  | { input:      ((u.input_tokens               // 0) * $q.inp / 1e6),
      output:     ((u.output_tokens              // 0) * $q.out / 1e6),
      cache_read: ((u.cache_read_input_tokens    // 0) * $q.rd  / 1e6),
      cache_5m:   ((u.cache_creation.ephemeral_5m_input_tokens // 0) * $q.c5 / 1e6),
      cache_1h:   ((u.cache_creation.ephemeral_1h_input_tokens // 0) * $q.c1 / 1e6) };

# USD for one `usage` object at price record p.
def cost_of(u; p): costs_of(u; p) | add;

# Claude Code writes one transcript line per content block of an API message
# (thinking, text, each tool_use), and every line repeats the message usage.
# Keep one line per message or costs come out 2-3x too high — the LAST one:
# in background-agent transcripts the usage grows from block to block and
# only the final line carries the full figures.
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
