#!/usr/bin/env bash
# git-dirty-report.sh — Report dirty git repos under the bigconfig workspace,
#                       and optionally commit & push in each dirty repo via pi.
#
# Usage:
#   ./git-dirty-report.sh [subcommand] [options] [root-dir]
#
# Subcommands:
#   report    (default) Show dirty/clean status for all git repos.
#   commit    Launch "pi --print --model deepseek-v4-flash" with prompt "commit and push"
#             in each dirty repo.
#
# Options:
#   --porcelain      Machine-parseable tab-separated output (report only).
#   --dry-run        Show what would be done without actually running pi (commit only).
#   --help, -h       Show this help.
#
# Examples:
#   ./git-dirty-report.sh                         # report on defaults
#   ./git-dirty-report.sh --porcelain             # machine-readable report
#   ./git-dirty-report.sh commit                  # commit & push every dirty repo
#   ./git-dirty-report.sh commit --dry-run        # preview without running
#   ./git-dirty-report.sh /some/other/path        # scan a different root

set -euo pipefail
IFS=$'\n\t'

ROOT="/home/ubuntu/code/bigconfig"
SUBCOMMAND="report"
PORCELAIN=false
DRY_RUN=false

# Collect positional args (subcommand + root) after parsing flags
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --porcelain) PORCELAIN=true ;;
    --dry-run)   DRY_RUN=true ;;
    --help|-h)
      awk 'NR > 1 && /^#/     { sub(/^# ?/, ""); print; next }
           NR > 1 && /^[^#]/  { exit }' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

# First positional: subcommand (report or commit)
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  case "${POSITIONAL[0]}" in
    report|commit) SUBCOMMAND="${POSITIONAL[0]}" ;;
    *)             ROOT="${POSITIONAL[0]}"       ;;
  esac
fi

# Second positional (optional): root-dir override
if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  ROOT="${POSITIONAL[1]}"
fi

# Validate subcommand
if [[ "$SUBCOMMAND" != "report" && "$SUBCOMMAND" != "commit" ]]; then
  echo "Unknown subcommand: $SUBCOMMAND" >&2
  exit 1
fi

# ── Scan: collect all repos and their dirty status ───────────────
GIT_DIRS=()
while IFS= read -r -d '' d; do
  GIT_DIRS+=("$(dirname "$d")")
done < <(find "$ROOT" -name .git \( -type d -o -type f \) -print0 2>/dev/null)

if [[ ${#GIT_DIRS[@]} -eq 0 ]]; then
  echo "No git repositories found under $ROOT"
  exit 1
fi

# Sort for deterministic ordering
IFS=$'\n' GIT_DIRS_SORTED=($(sort <<<"${GIT_DIRS[*]}")); unset IFS

TOTAL=0
DIRTY=0
CLEAN=0
declare -a DIRTY_REPOS=()
declare -a DIRTY_BRANCHES=()
declare -a DIRTY_COUNTS=()
declare -a CLEAN_REPOS=()

for repo in "${GIT_DIRS_SORTED[@]}"; do
  TOTAL=$((TOTAL + 1))
  rel="${repo#$ROOT/}"
  branch=$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")

  tracked_count=$(cd "$repo" && git ls-files 2>/dev/null | wc -l)

  if [[ "$tracked_count" -eq 0 ]]; then
    # Repo with no tracked files (empty repo or bare) — skip from commit
    continue
  fi

  dirty_count=$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l)

  if [[ "$dirty_count" -gt 0 ]]; then
    DIRTY=$((DIRTY + 1))
    DIRTY_REPOS+=("$repo")
    DIRTY_BRANCHES+=("$branch")
    DIRTY_COUNTS+=("$dirty_count")
  else
    CLEAN=$((CLEAN + 1))
    CLEAN_REPOS+=("$repo")
  fi
done

# ── Subcommand dispatch ────────────────────────────────────────────
if [[ "$SUBCOMMAND" == "commit" ]]; then
  # ── commit subcommand: run pi in each dirty repo ─────────────────
  if [[ "$DIRTY" -eq 0 ]]; then
    echo "No dirty repos to commit. All clean."
    exit 0
  fi

  echo "Running 'pi --print --model deepseek-v4-flash \"commit and push\"' in ${DIRTY} dirty repo(s)..."
  echo ""

  for i in "${!DIRTY_REPOS[@]}"; do
    repo="${DIRTY_REPOS[$i]}"
    rel="${repo#$ROOT/}"
    branch="${DIRTY_BRANCHES[$i]}"
    count="${DIRTY_COUNTS[$i]}"

    echo "──────────────────────────────────────────"
    echo "  [${i}/$(($DIRTY - 1))]  $rel  ($branch)  —  $count dirty file(s)"
    echo ""

    if $DRY_RUN; then
      echo "  (dry-run) would run: pi --print --model deepseek-v4-flash 'commit and push'"
    else
      (cd "$repo" && pi --print --model deepseek-v4-flash 'commit and push')
      echo ""
      echo "  Done — exit code: $?"
    fi
  done

  echo "──────────────────────────────────────────"
  echo "  Finished. Processed $DIRTY dirty repo(s)."
  exit 0
fi

# ── report subcommand (default) ────────────────────────────────────
# Print per-repo status
for repo in "${GIT_DIRS_SORTED[@]}"; do
  rel="${repo#$ROOT/}"
  branch=$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
  tracked_count=$(cd "$repo" && git ls-files 2>/dev/null | wc -l)

  if [[ "$tracked_count" -eq 0 ]]; then
    if $PORCELAIN; then
      echo -e "NO-TRACKED-FILES\t$rel\t$branch"
    else
      echo "  ⚠  $rel  ($branch)  —  no tracked files"
    fi
    continue
  fi

  dirty_count=$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l)

  if [[ "$dirty_count" -gt 0 ]]; then
    if $PORCELAIN; then
      echo -e "DIRTY\t$rel\t$branch\t$dirty_count"
    else
      echo "  ✗  $rel  ($branch)  —  $dirty_count dirty file(s)"
      while IFS= read -r line; do
        xy="${line:0:2}"
        path="${line:3}"
        case "$xy" in
          "M ") label="modified (staged)" ;;
          " M") label="modified (unstaged)" ;;
          "A ") label="added (staged)" ;;
          "??") label="untracked" ;;
          "D ") label="deleted (staged)" ;;
          " D") label="deleted (unstaged)" ;;
          "R ") label="renamed (staged)" ;;
          "C ") label="copied (staged)" ;;
          "MM") label="modified (staged+unstaged)" ;;
          *)   label="changed ($xy)" ;;
        esac
        printf "       • %s  %s\n" "$label" "$path"
      done < <(cd "$repo" && git status --porcelain 2>/dev/null)
    fi
  else
    if $PORCELAIN; then
      echo -e "CLEAN\t$rel\t$branch"
    else
      echo "  ✓  $rel  ($branch)  —  clean"
    fi
  fi
done

# Summary
if $PORCELAIN; then
  echo -e "SUMMARY\t$TOTAL repos\t$DIRTY dirty\t$CLEAN clean"
else
  echo ""
  echo "──────────────────────────────────────────"
  echo "  Git Dirty Report — $ROOT"
  echo "  Total repos:  $TOTAL"
  echo "  Dirty:        $DIRTY"
  echo "  Clean:        $CLEAN"
  if [[ "$DIRTY" -gt 0 ]]; then
    echo ""
    echo "  Dirty repos:"
    for repo in "${DIRTY_REPOS[@]}"; do
      rel="${repo#$ROOT/}"
      printf "    • %s\n" "$rel"
    done
  fi
  echo "──────────────────────────────────────────"
fi
