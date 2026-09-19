#!/usr/bin/env bash
# project-costs.sh — aggregate Claude Code token cost by project.
#
# Usage:
#   ./project-costs.sh                       # total cost per project, sorted desc
#   ./project-costs.sh -v                    # …with per-model breakdown
#   ./project-costs.sh --dates <project>     # daily cost trend for one project
#   ./project-costs.sh --dates <project> -v  # …with per-model daily breakdown
#   ./project-costs.sh --list                # project roots, one per line (scripts/TUI)
#
# What counts as one project
# --------------------------
# A project is one folder under ~/.claude/projects/ — i.e. the directory
# Claude Code was *opened in*. That is Claude Code's own unit, and it is
# neither the git repo root nor the per-event `cwd`:
#
#   * Not the git root. A repo can hold several independently-opened projects
#     (a repo's tools/cli-tool subfolder opened on its own gets its own
#     folder), so rolling up to the repo would merge unrelated work.
#   * Not the per-event `cwd`. That records where the shell stood at that
#     moment and drifts as a session cd's around, so grouping on it invents a
#     phantom project for every visited subdirectory (webapp/assets,
#     .../build, .claude/skills — all part of the project they sit in).
#
# Each project is labelled with the shortest cwd recorded inside it, which is
# the folder that was opened.
#
# <project> accepts that label (`~/…` or absolute) or any unambiguous trailing
# segment of it; an ambiguous argument lists candidates and exits non-zero.
#
# Same list-price pricing as cost-report.sh. Estimates only.

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
EXTENDED=0
MODE=total
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--extended) EXTENDED=1; shift ;;
    --list)        MODE=list; shift ;;
    --dates)
      MODE=dates
      PROJECT="${2:-}"
      [[ -z "$PROJECT" ]] && { echo "--dates requires a project" >&2; exit 1; }
      shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- pricing (shared jq defs; keep in sync with cost-report.sh) ----------
JQ_DEFS='
    def price(mdl):
      (mdl // "") as $m |
      if   ($m | startswith("claude-fable")) or ($m | startswith("claude-mythos"))
                                            then {inp:10,  out:50, rd:1,    c5:12.5,  c1:20}
      elif $m | test("^claude-opus-(5|4-[5-9])")
                                            then {inp:5,   out:25, rd:0.5,  c5:6.25,  c1:10}
      elif $m | startswith("claude-opus")   then {inp:15,  out:75, rd:1.5,  c5:18.75, c1:30}
      elif $m | test("^claude-sonnet-5")    then {inp:2,   out:10, rd:0.2,  c5:2.5,   c1:4}
      elif $m | startswith("claude-sonnet") then {inp:3,   out:15, rd:0.3,  c5:3.75,  c1:6}
      elif $m | test("^claude-haiku-(5|4-[5-9])")
                                            then {inp:1,   out:5,  rd:0.1,  c5:1.25,  c1:2}
      elif $m | startswith("claude-haiku")  then {inp:0.8, out:4,  rd:0.08, c5:1,     c1:1.6}
      else                                       {inp:5,   out:25, rd:0.5,  c5:6.25,  c1:10}
      end;
    def cost_of(u; p):
      ( (u.input_tokens               // 0) * p.inp
      + (u.output_tokens              // 0) * p.out
      + (u.cache_read_input_tokens    // 0) * p.rd
      + (u.cache_creation.ephemeral_5m_input_tokens // 0) * p.c5
      + (u.cache_creation.ephemeral_1h_input_tokens // 0) * p.c1
      ) / 1e6;
    # Home-relative display form: /Users/me/projects/foo → ~/projects/foo
    def shorten($home): if $home != "" and startswith($home + "/")
                        then "~" + .[($home | length):] else . end;
    # Clip from the LEFT — a project path is distinguished by its tail, so
    # keep the tail and mark the elision with a leading ellipsis.
    def clip($w): if (length) <= $w then . else "…" + .[(length - $w + 1):] end;
    # The opened folder: shortest cwd seen in this project. Every other cwd in
    # the folder is a subdirectory the session walked into.
    def project_root($fallback):
      ([ .[] | .cwd // empty ] | unique) as $c
      | if ($c | length) > 0 then ($c | min_by(length)) else $fallback end;
'

# ---------- print helpers ----------
if [[ -z "${NO_COLOR:-}" ]]; then
  RST=$'\e[0m'
else
  RST=""
fi

color_for() {
  [[ -n "${NO_COLOR:-}" ]] && return 0
  case "$1" in
    claude-fable*|claude-mythos*) printf '\e[95m' ;;  # bright magenta
    claude-opus*)                 printf '\e[94m' ;;  # bright blue
    claude-sonnet*)               printf '\e[92m' ;;  # bright green
    claude-haiku*)                printf '\e[93m' ;;  # bright yellow
    *)                            ;;
  esac
}

# printf's %-Ns pads by BYTES; `…` and `~` paths may be multibyte, so pad by
# character count instead (same helper as cost-report.sh).
pad_chars() {
  local s="$1" w="$2"
  local n p
  n=$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  p=$(( w - n )); (( p < 0 )) && p=0
  printf '%s%*s' "$s" "$p" ""
}

# One TSV row per project: cost \t root \t sessions \t by_model-json \t dir
# Sorted by cost, descending. Projects with no priced events are skipped.
# jq runs once per project folder, which is what keeps each folder's events
# attributable — a single concatenated pass would lose that provenance.
project_rows() {
  local pdir
  for pdir in "$ROOT"/*/; do
    set -- "$pdir"*.jsonl
    [[ -e "$1" ]] || continue
    cat "$@" 2>/dev/null | jq -sr --arg dir "$pdir" "$JQ_DEFS"'
      ($dir | rtrimstr("/") | split("/") | last) as $fallback
      | project_root($fallback) as $root
      | [ .[]
          | select(.type=="assistant" and .message.usage)
          | { sid:   .sessionId,
              model: (.message.model // "unknown"),
              cost:  cost_of(.message.usage; price(.message.model)) } ] as $a
      | if ($a | length) == 0 then empty
        else
          [ "\([$a[].cost] | add // 0)"
          , $root
          , "\([$a[].sid] | unique | length)"
          , ( $a | group_by(.model)
                 | map({model: .[0].model, cost: ([.[].cost] | add)})
                 | map(select(.cost > 0)) | sort_by(-.cost) | tojson )
          , $dir
          ] | @tsv
        end
    '
  done | sort -t$'\t' -k1,1 -rn
}

# ==================================================================
# Mode: machine-readable project list (roots, cost-sorted)
# ==================================================================
# The TUI consumes this instead of scraping the human table, so display
# formatting (clipping, column widths) can change without breaking it.
if [[ "$MODE" == list ]]; then
  project_rows | cut -f2
  exit 0
fi

# ==================================================================
# Mode: daily trend for one project
# ==================================================================
if [[ "$MODE" == dates ]]; then
  ROWS=$(project_rows)
  [[ -z "$ROWS" ]] && { echo "No usage recorded." >&2; exit 1; }

  # Resolve the argument against project roots: exact path (~/… or absolute)
  # first, then an unambiguous trailing path segment.
  QA=${PROJECT/#\~\//$HOME/}
  QS=${PROJECT#\~/}
  # An exact root match wins outright; otherwise fall back to roots ending in
  # "/<query>". Suffix test is index-based so path segments containing regex
  # metacharacters (".claude") compare literally.
  HITS=$(awk -F'\t' -v qa="$QA" -v qs="$QS" '
    $2 == qa { exact = exact $0 ORS; ne++ }
    length($2) > length(qs) &&
      substr($2, length($2) - length(qs)) == "/" qs { sfx = sfx $0 ORS; ns++ }
    END { if (ne) printf "%s", exact; else if (ns) printf "%s", sfx }
  ' <<< "$ROWS")

  COUNT=$(printf '%s' "$HITS" | grep -c . || true)
  if [[ "$COUNT" -eq 0 ]]; then
    printf 'Project not found: %s\n' "$PROJECT" >&2
    printf 'Known projects:\n' >&2
    cut -f2 <<< "$ROWS" | sed "s|^$HOME|~|" | sed 's/^/  /' >&2
    exit 1
  elif [[ "$COUNT" -gt 1 ]]; then
    printf 'Ambiguous project: %s\nMatches:\n' "$PROJECT" >&2
    cut -f2 <<< "$HITS" | sed "s|^$HOME|~|" | sed 's/^/  /' >&2
    exit 1
  fi

  LABEL=$(cut -f2 <<< "$HITS" | sed "s|^$HOME|~|")
  PDIR=$(cut -f5 <<< "$HITS")

  # Local UTC offset — buckets UTC timestamps into local calendar days.
  OFF=$(date +%z | awk '{ s = (substr($0,1,1)=="-") ? -1 : 1
                          print s * (substr($0,2,2)*3600 + substr($0,4,2)*60) }')

  DAILY=$(cat "$PDIR"*.jsonl 2>/dev/null \
    | jq -sr --argjson off "$OFF" "$JQ_DEFS"'
      [ .[]
        | select(.type=="assistant" and .timestamp and .message.usage)
        | { dt: (.timestamp
                 | (try (sub("\\.[0-9]+Z$"; "Z")
                         | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime + $off
                         | strftime("%Y-%m-%d"))
                    catch .[0:10])),
            sid:   .sessionId,
            model: (.message.model // "unknown"),
            cost:  cost_of(.message.usage; price(.message.model)) }
      ]
      | group_by(.dt)
      | map({ dt: .[0].dt,
              cost:     ([.[].cost] | add // 0),
              sessions: ([.[].sid] | unique | length),
              by_model: (group_by(.model)
                         | map({model: .[0].model, cost: ([.[].cost] | add)})
                         | map(select(.cost > 0))
                         | sort_by(-.cost)) })
      | sort_by(.dt) | reverse | .[]
      | ( "D|\(.dt)|\(.sessions)|\(.cost)"
        , (.by_model[] | "S|\(.model)|\(.cost)") )
    ')

  printf 'Daily cost — %s\n' "$LABEL"
  printf '%s\n' "=================================================="
  printf '\n'

  if [[ -z "$DAILY" ]]; then
    printf '  (no usage recorded)\n'
  else
    TOTAL=0
    while IFS='|' read -r kind a b c; do
      if [[ "$kind" == D ]]; then
        printf '%-12s  %3s sessions   $%8.2f\n' "$a" "$b" "$c"
        TOTAL=$(awk -v x="$TOTAL" -v y="$c" 'BEGIN{printf "%.4f", x+y}')
      elif [[ "$kind" == S && $EXTENDED -eq 1 ]]; then
        color=$(color_for "$a")
        printf '  %s%-42s $%8.2f%s\n' "$color" "$a" "$b" "$RST"
      fi
    done <<< "$DAILY"
    printf '\n'
    printf '%-12s %16s $%8.2f\n' "total" "" "$TOTAL"
  fi
  printf '\n'
  printf '  (list prices; subscription plans pay the plan, not this amount)\n'
  exit 0
fi

# ==================================================================
# Mode: total cost per project
# ==================================================================

ROWS=$(project_rows)

printf '%s\n' "Cost by project (estimate at list prices)"
printf '%s\n' "=================================================="
printf '\n'

if [[ -z "$ROWS" ]]; then
  printf '  (no usage recorded)\n'
else
  TOTAL=0
  while IFS=$'\t' read -r cost root sessions models _dir; do
    label=$(printf '%s' "$root" | sed "s|^$HOME|~|")
    # Clip from the left; a path's tail is what identifies it.
    n=${#label}
    (( n > 44 )) && label="…${label: n-43}"
    printf '%s %3s sess   $%8.2f\n' "$(pad_chars "$label" 44)" "$sessions" "$cost"
    TOTAL=$(awk -v x="$TOTAL" -v y="$cost" 'BEGIN{printf "%.4f", x+y}')
    if [[ $EXTENDED -eq 1 ]]; then
      printf '%s' "$models" | jq -r '.[] | "\(.model)|\(.cost)"' \
        | while IFS='|' read -r mdl mcost; do
            color=$(color_for "$mdl")
            printf '  %s%-51s $%8.2f%s\n' "$color" "$mdl" "$mcost" "$RST"
          done
    fi
  done <<< "$ROWS"
  printf '\n'
  printf '%-44s %3s        $%8.2f\n' "total" "" "$TOTAL"
fi
printf '\n'
printf '  (list prices; subscription plans pay the plan, not this amount)\n'
