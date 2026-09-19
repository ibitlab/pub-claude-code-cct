#!/usr/bin/env bash
# stack-report.sh — which languages / ecosystems you worked on, by time window.
#
# Signal comes from file_path arguments of Read / Write / Edit tool calls
# across every transcript: extensions map to languages, special basenames
# (platformio.ini, Cargo.toml, Dockerfile, …) map to ecosystems.
#
# Windows match cost-report.sh:
#   day    — 00:00 local today → now
#   week   — most recent Monday 00:00 local → now
#   month  — rolling last 30 days → now
#
# Usage:
#   ./stack-report.sh             # summary — drop languages with <2 touches
#   ./stack-report.sh -v          # extended — include low-count entries

set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ROOT="$HOME/.claude/projects"
EXTENDED=0
case "${1:-}" in
  -v|--extended) EXTENDED=1 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

# ---------- window start timestamps (UTC ISO 8601) ----------

to_utc_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

today_local=$(date +%Y-%m-%d)
today_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)
yesterday_epoch=$(( today_epoch - 86400 ))
dow=$(date +%u)
monday_epoch=$(date -v-$((dow-1))d -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)
month_epoch=$(date -v-30d -j -f "%Y-%m-%d %H:%M:%S" "$today_local 00:00:00" +%s)

TODAY_ISO=$(to_utc_iso "$today_epoch")
YESTERDAY_ISO=$(to_utc_iso "$yesterday_epoch")
WEEK_ISO=$(to_utc_iso "$monday_epoch")
MONTH_ISO=$(to_utc_iso "$month_epoch")

TODAY_LABEL=$(date -r "$today_epoch" +%Y-%m-%d)
YESTERDAY_LABEL=$(date -r "$yesterday_epoch" +%Y-%m-%d)
WEEK_LABEL="$(date -r "$monday_epoch" +%Y-%m-%d) → $(date -v+6d -r "$monday_epoch" +%Y-%m-%d)"
MONTH_LABEL="$(date -r "$month_epoch" +%Y-%m-%d) → $today_local"

# ---------- aggregate via one jq pass ----------

AGG=$(find "$ROOT" -maxdepth 2 -name "*.jsonl" -print0 2>/dev/null \
  | xargs -0 cat 2>/dev/null \
  | jq -sr --arg d "$TODAY_ISO" --arg y "$YESTERDAY_ISO" \
           --arg w "$WEEK_ISO" --arg m "$MONTH_ISO" '
    # Basename of a path string (last "/"-delimited segment).
    def base: sub(".*/"; "");
    # Lowercased extension; "" if the basename has no dot.
    def ext: base | ascii_downcase
           | if test("\\.") then sub(".*\\."; "") else "" end;

    # Marker-basename → ecosystem. Takes precedence over extension so
    # platformio.ini counts as PlatformIO, not INI.
    def ecosystem:
      . as $b |
      {"platformio.ini": "PlatformIO",
       "package.json": "Node.js", "package-lock.json": "Node.js",
       "yarn.lock": "Yarn", "pnpm-lock.yaml": "pnpm",
       "Cargo.toml": "Rust/Cargo", "Cargo.lock": "Rust/Cargo",
       "pyproject.toml": "Python", "requirements.txt": "Python pip",
       "setup.py": "Python", "Pipfile": "Python", "poetry.lock": "Python",
       "go.mod": "Go", "go.sum": "Go",
       "Gemfile": "Ruby", "Gemfile.lock": "Ruby",
       "composer.json": "PHP",
       "Dockerfile": "Docker",
       "docker-compose.yml": "Docker", "docker-compose.yaml": "Docker",
       "Makefile": "Make", "CMakeLists.txt": "CMake",
       "pom.xml": "Java/Maven",
       "build.gradle": "Java/Gradle", "build.gradle.kts": "Kotlin/Gradle",
       ".gitignore": "Git", ".gitattributes": "Git"
      }[$b] // null;

    # Extension → language / format.
    def language:
      . as $e |
      {"py": "Python", "pyi": "Python",
       "ts": "TypeScript", "tsx": "TypeScript (React)",
       "js": "JavaScript", "jsx": "JavaScript (React)",
       "mjs": "JavaScript", "cjs": "JavaScript",
       "go": "Go", "rs": "Rust",
       "c": "C", "h": "C/C++ header",
       "cpp": "C++", "cc": "C++", "cxx": "C++", "hpp": "C++", "hh": "C++",
       "ino": "Arduino",
       "sh": "Bash", "bash": "Bash", "zsh": "Zsh", "fish": "Fish",
       "rb": "Ruby", "java": "Java", "kt": "Kotlin", "swift": "Swift",
       "php": "PHP", "lua": "Lua", "r": "R",
       "sql": "SQL",
       "html": "HTML", "htm": "HTML", "css": "CSS",
       "scss": "SASS", "less": "LESS",
       "vue": "Vue", "svelte": "Svelte",
       "md": "Markdown", "mdx": "Markdown",
       "json": "JSON", "yaml": "YAML", "yml": "YAML",
       "toml": "TOML", "ini": "INI", "xml": "XML",
       "tf": "Terraform", "hcl": "HCL",
       "proto": "Protobuf"
      }[$e] // null;

    # One event per Read/Write/Edit tool_use with a file_path.
    def events:
      [ .[]
        | select(.type=="assistant" and .timestamp)
        | .timestamp as $ts
        | (.message.content[]? | select(.type=="tool_use")) as $t
        | select($t.name == "Read" or $t.name == "Write" or $t.name == "Edit")
        | { ts: $ts, path: $t.input.file_path }
        | select(.path != null) ];

    def classify:
      . as $ae
      | [ $ae[]
          | { path: .path,
              lang: (.path | ext | language),
              eco: (.path | base | ecosystem) } ];

    # start..end_excl window; end_excl="" means open-ended (now).
    def summarize(start; end_excl; evs):
      ([ evs[]
         | select(.ts >= start)
         | select(end_excl == "" or .ts < end_excl)
       ] | classify) as $c
      | { total:       ($c | length),
          total_files: ($c | map(.path) | unique | length),
          by_ecosystem:
            ( $c | map(select(.eco != null))
                 | group_by(.eco)
                 | map({ name:    .[0].eco,
                         touches: length,
                         files:   ([.[].path] | unique | length) })
                 | sort_by(-.touches) ),
          by_language:
            ( $c | map(select(.eco == null and .lang != null))
                 | group_by(.lang)
                 | map({ name:    .[0].lang,
                         touches: length,
                         files:   ([.[].path] | unique | length) })
                 | sort_by(-.touches) ),
          unknown:
            ( $c | map(select(.eco == null and .lang == null)) | length ) };

    events as $a
    | { today:     summarize($d; "";   $a),
        yesterday: summarize($y; $d;   $a),
        week:      summarize($w; "";   $a),
        month:     summarize($m; "";   $a) }
  ')

# ---------- print ----------

BAR_WIDTH=10

# render_bar VALUE MAX  →  fixed-width unicode bar scaled to MAX.
# Uses full blocks "█" + an optional half block "▌". Pads with spaces so
# each bar occupies BAR_WIDTH display columns, independent of unicode byte
# length (bash %s can't do display-width padding for multibyte chars).
render_bar() {
  local value="$1" max="$2" bar="" i
  if (( max > 0 && value > 0 )); then
    # value / max, scaled to BAR_WIDTH*2 so we can render halves.
    local units=$(( value * BAR_WIDTH * 2 / max ))
    local full=$(( units / 2 )) half=$(( units % 2 ))
    # Never lose a non-zero value to rounding — show at least a half tick.
    (( full == 0 && half == 0 )) && half=1
    for ((i=0; i<full; i++)); do bar+="█"; done
    (( half )) && bar+="▌"
    local vis=$(( full + half ))
    local pad=$(( BAR_WIDTH - vis ))
    for ((i=0; i<pad; i++)); do bar+=" "; done
  else
    for ((i=0; i<BAR_WIDTH; i++)); do bar+=" "; done
  fi
  printf '%s' "$bar"
}

print_section() {
  # $1=label   $2=window-key   $3=field (by_ecosystem|by_language)
  local label="$1" key="$2" field="$3"
  local rows max
  rows=$(echo "$AGG" | jq -r ".$key.$field[] | \"\\(.touches)\\t\\(.files)\\t\\(.name)\"")
  [[ -z "$rows" ]] && return
  # Scale bars to this section's own max (ecosystems and languages live on
  # very different scales — sharing a max would squash the smaller group).
  max=$(echo "$AGG" | jq -r ".$key.$field | map(.touches) | max // 0")

  local printed_header=0
  while IFS=$'\t' read -r t fc n; do
    # Summary mode drops low-count language entries; ecosystems always print.
    if [[ "$field" == "by_language" && $EXTENDED -eq 0 && "$t" -lt 2 ]]; then
      continue
    fi
    if (( printed_header == 0 )); then
      printf '  %s:\n' "$label"
      printed_header=1
    fi
    printf '    %7s  %7s   %s  %s\n' "$t" "$fc" "$(render_bar "$t" "$max")" "$n"
  done <<< "$rows"
}

print_window() {
  local label="$1" span="$2" key="$3"
  local total unknown total_files
  total=$(       echo "$AGG" | jq -r ".$key.total")
  unknown=$(     echo "$AGG" | jq -r ".$key.unknown")
  total_files=$( echo "$AGG" | jq -r ".$key.total_files")

  printf '\n%s — %s\n' "$label" "$span"
  if (( total == 0 )); then
    printf '  (no activity)\n'
    return
  fi
  printf '  %d touches across %d files  (%d unknown)\n' "$total" "$total_files" "$unknown"
  printf '\n    %7s  %7s\n' "touches" "files"

  print_section "ecosystems" "$key" "by_ecosystem"
  # Blank line between sections so the two bar scales don't read as one ranking.
  echo
  print_section "languages"  "$key" "by_language"
}

printf '%s\n' "Stack / tech used (file touches from Read/Write/Edit)"
printf '%s\n' "====================================================="

print_window "today"     "$TODAY_LABEL"      today
print_window "yesterday" "$YESTERDAY_LABEL"  yesterday
print_window "week"      "$WEEK_LABEL"       week
print_window "30 days"   "$MONTH_LABEL"      month

printf '\n'
printf '  (bars are scaled within each section; extension → language,\n'
printf '   marker basename → ecosystem)\n'
