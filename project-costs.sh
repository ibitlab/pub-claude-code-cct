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
#   ./project-costs.sh --merged                       # total cost per MERGED project
#   ./project-costs.sh --merged -v                    # …with one row per member folder
#   ./project-costs.sh --merged --dates <name> [-v]   # daily trend for a merged project
#   ./project-costs.sh --merged --list                # merged project names, one per line
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
# Merged projects
# ---------------
# A project that moved or was renamed keeps its old transcripts under the old
# folder; a repo opened from two subfolders gets two folders. `cct → Merged
# projects` binds such folders to one primary and stores the bindings in
# ~/.config/cct/merges.json ({"groups": [{"name", "primary", "members"}]},
# slugs = folder names). --merged reports on those bindings, counted
# together. Plain mode is untouched — merged projects are a separate view.
#
# Prices come from pricing.json next to this script (shared by every cost
# script). Estimates only.

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
HERE="$(cd "$(dirname "$0")" && pwd)"
MERGES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cct/merges.json"
EXTENDED=0
MODE=total
MERGED=0
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--extended) EXTENDED=1; shift ;;
    --list)        MODE=list; shift ;;
    --merged)      MERGED=1; shift ;;
    --dates)
      MODE=dates
      PROJECT="${2:-}"
      [[ -z "$PROJECT" ]] && { echo "--dates requires a project" >&2; exit 1; }
      shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------- pricing (shared: pricing.json = the table, pricing.jq = the helpers) ----------
[[ -f "$HERE/pricing.json" && -f "$HERE/pricing.jq" ]] \
  || { echo "pricing.json / pricing.jq missing next to $0" >&2; exit 1; }
JQ_DEFS=$(jq -r '"def pricing: \(tojson);"' "$HERE/pricing.json"; cat "$HERE/pricing.jq")
# Script-specific helpers on top of the shared ones.
JQ_DEFS+='
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

# Concatenate the transcripts of one or more project folders.
cat_dirs() {
  local d
  for d in "$@"; do
    cat "$d"/*.jsonl 2>/dev/null || true
  done
}

# One TSV row for a set of folders under one label:
#   cost \t label \t sessions \t by_model-json
# An empty label means "the opened folder" (shortest cwd), as in plain mode.
# Prints nothing when the folders hold no priced events.
rows_for_dirs() {
  local label="$1"; shift
  local fallback
  fallback=$(basename "$1")
  cat_dirs "$@" | jq -sr --arg label "$label" --arg fallback "$fallback" "$JQ_DEFS"'
      (if $label == "" then project_root($fallback) else $label end) as $root
      | [ priced[]
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
          ] | @tsv
        end
    '
}

# One TSV row per project folder: cost \t root \t sessions \t by_model-json \t dir
# Sorted by cost, descending. Folders with no priced events are skipped.
# jq runs once per folder, which is what keeps each folder's events
# attributable — a single concatenated pass would lose that provenance.
project_rows() {
  local pdir row
  for pdir in "$ROOT"/*/; do
    row=$(rows_for_dirs "" "${pdir%/}")
    if [[ -n "$row" ]]; then
      printf '%s\t%s\n' "$row" "${pdir%/}"
    fi
  done | sort -t$'\t' -k1,1 -rn
}

# ---------- merged projects ----------

# name \t slug \t slug…  (primary first), one line per merged project.
group_lines() {
  [[ -f "$MERGES_FILE" ]] || return 0
  jq -r '.groups[]? | select(.primary) | .primary as $p
         | [ (.name // $p), $p, (.members[]? | select(. != $p)) ] | @tsv' "$MERGES_FILE"
}

# Existing folders for a list of slugs → GROUP_DIRS (folders that vanished
# from ~/.claude/projects are skipped, e.g. after a manual cleanup).
group_dirs() {
  GROUP_DIRS=()
  local s
  for s in "$@"; do
    [[ -d "$ROOT/$s" ]] && GROUP_DIRS+=("$ROOT/$s")
  done
  return 0
}

# Resolve a merged project by exact name, else by a unique case-insensitive
# substring. Prints "name \t slug \t slug…"; lists candidates and fails otherwise.
find_group() {
  local q="$1"
  [[ -f "$MERGES_FILE" ]] || { echo "No merged projects defined ($MERGES_FILE)" >&2; return 1; }
  jq -r --arg q "$q" '
    [ .groups[]? | select(.primary) | .primary as $p
      | { name: (.name // $p), slugs: ([$p] + [ .members[]? | select(. != $p) ]) } ] as $g
    | ([ $g[] | select(.name == $q) ]) as $exact
    | ([ $g[] | select(.name | ascii_downcase | contains($q | ascii_downcase)) ]) as $sub
    | (if ($exact | length) == 1 then $exact else $sub end) as $hit
    | if ($hit | length) == 1 then ($hit[0] | [.name] + .slugs | @tsv)
      elif ($hit | length) == 0 then
        ("Merged project not found: \($q)\nKnown merged projects:\n"
         + ([ $g[].name ] | map("  " + .) | join("\n")) + "\n") | halt_error(1)
      else
        ("Ambiguous merged project: \($q)\nMatches:\n"
         + ([ $hit[].name ] | map("  " + .) | join("\n")) + "\n") | halt_error(1)
      end
  ' "$MERGES_FILE"
}

# cost \t name \t sessions \t by_model-json \t folders   — one row per group.
merged_rows() {
  local f row
  while IFS=$'\t' read -r -a f; do
    (( ${#f[@]} >= 2 )) || continue
    group_dirs "${f[@]:1}"
    (( ${#GROUP_DIRS[@]} )) || continue
    row=$(rows_for_dirs "${f[0]}" "${GROUP_DIRS[@]}")
    if [[ -n "$row" ]]; then
      printf '%s\t%s\n' "$row" "${#GROUP_DIRS[@]}"
    fi
  done < <(group_lines) | sort -t$'\t' -k1,1 -rn
}

# ---------- daily trend ----------

print_daily() {
  local label="$1"; shift
  # Local UTC offset — buckets UTC timestamps into local calendar days.
  local OFF DAILY
  OFF=$(date +%z | awk '{ s = (substr($0,1,1)=="-") ? -1 : 1
                          print s * (substr($0,2,2)*3600 + substr($0,4,2)*60) }')

  DAILY=$(cat_dirs "$@" | jq -sr --argjson off "$OFF" "$JQ_DEFS"'
      [ priced[]
        | select(.timestamp)
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

  printf 'Daily cost — %s\n' "$label"
  printf '%s\n' "=================================================="
  printf '\n'

  if [[ -z "$DAILY" ]]; then
    printf '  (no usage recorded)\n'
  else
    local TOTAL=0 kind a b c color
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
}

# ==================================================================
# Merged-project modes
# ==================================================================
if [[ $MERGED -eq 1 ]]; then
  if [[ "$MODE" == list ]]; then
    group_lines | cut -f1
    exit 0
  fi

  if [[ "$MODE" == dates ]]; then
    LINE=$(find_group "$PROJECT") || exit 1
    IFS=$'\t' read -r -a F <<< "$LINE"
    group_dirs "${F[@]:1}"
    (( ${#GROUP_DIRS[@]} )) || { echo "No folders of '${F[0]}' exist under $ROOT" >&2; exit 1; }
    print_daily "⊕ ${F[0]}  (${#GROUP_DIRS[@]} folders)" "${GROUP_DIRS[@]}"
    exit 0
  fi

  ROWS=$(merged_rows)

  printf '%s\n' "Cost by merged project (estimate at list prices)"
  printf '%s\n' "=================================================="
  printf '\n'

  if [[ -z "$ROWS" ]]; then
    if [[ -f "$MERGES_FILE" ]]; then
      printf '  (no usage recorded for any merged project)\n'
    else
      printf '  (no merged projects yet — cct → Merged projects → New merged project)\n'
    fi
  else
    TOTAL=0
    while IFS=$'\t' read -r cost name sessions _models nfold; do
      label="⊕ $name  ($nfold folders)"
      n=${#label}
      (( n > 44 )) && label="…${label: n-43}"
      printf '%s %3s sess   $%8.2f\n' "$(pad_chars "$label" 44)" "$sessions" "$cost"
      TOTAL=$(awk -v x="$TOTAL" -v y="$cost" 'BEGIN{printf "%.4f", x+y}')
      if [[ $EXTENDED -eq 1 ]]; then
        LINE=$(find_group "$name") || continue
        IFS=$'\t' read -r -a F <<< "$LINE"
        for s in "${F[@]:1}"; do
          if [[ ! -d "$ROOT/$s" ]]; then
            printf '  %s\n' "$(pad_chars "$s" 42)  (folder missing)"
            continue
          fi
          row=$(rows_for_dirs "" "$ROOT/$s")
          if [[ -z "$row" ]]; then
            printf '  %s   0 sess   $%8.2f\n' "$(pad_chars "$s" 42)" 0
            continue
          fi
          IFS=$'\t' read -r mcost mroot msess _mm <<< "$row"
          mlabel=$(printf '%s' "$mroot" | sed "s|^$HOME|~|")
          [[ -d "$mroot" ]] || mlabel="$mlabel (gone)"
          n=${#mlabel}
          (( n > 42 )) && mlabel="…${mlabel: n-41}"
          printf '  %s %3s sess   $%8.2f\n' "$(pad_chars "$mlabel" 42)" "$msess" "$mcost"
        done
      fi
    done <<< "$ROWS"
    printf '\n'
    printf '%-44s %3s        $%8.2f\n' "total" "" "$TOTAL"
  fi
  printf '\n'
  printf '  (list prices; subscription plans pay the plan, not this amount)\n'
  exit 0
fi

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
  print_daily "$LABEL" "$PDIR"
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
