#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# 부모 프로세스 종료/인터럽트 시 즉시 정상 종료되도록 시그널 처리
trap 'exit 0' INT TERM HUP EXIT

# ─── ANSI Helpers (Standard 16-color palette only) ───────────────────────────
R="\033[0m"         # Reset
B="\033[1m"         # Bold
D="\033[2m"         # Dim
I="\033[3m"         # Italic

# Foreground accents (Standard 16 colors)
FG_BLACK="\033[30m"
FG_RED="\033[31m"
FG_GREEN="\033[32m"
FG_YELLOW="\033[33m"
FG_BLUE="\033[34m"
FG_MAGENTA="\033[35m"
FG_CYAN="\033[36m"
FG_WHITE="\033[37m"
FG_GRAY="\033[90m"
FG_BRIGHT_RED="\033[91m"
FG_BRIGHT_GREEN="\033[92m"
FG_BRIGHT_YELLOW="\033[93m"
FG_BRIGHT_BLUE="\033[94m"
FG_BRIGHT_MAGENTA="\033[95m"
FG_BRIGHT_CYAN="\033[96m"
FG_BRIGHT_WHITE="\033[97m"

# Number Highlight Color
NUM_COLOR="${FG_BRIGHT_WHITE}${B}"

# ─── Stdin 안전 읽기 (타임아웃 적용 및 무한 블로킹 방지) ─────────────────────
RAW_JSON=""
if [ ! -t 0 ]; then
  # 0.3초 이내에 입력이 오지 않으면 멈추지 않고 즉시 넘어감
  RAW_JSON=$(timeout 0.3s cat 2>/dev/null || true)
fi

# 입력이 없거나 비어있으면 기본 빈 JSON 객체 사용
if [ -z "$RAW_JSON" ]; then
  RAW_JSON="{}"
fi

# ─── Parse JSON (Single jq pass) ─────────────────────────────────────────────
PARSED=$(echo "$RAW_JSON" | jq -r '
  (.agent_state // "idle"),
  (.context_window.used_percentage // 0),
  (.vcs.branch // ""),
  (.vcs.dirty // false),
  (.sandbox.enabled // false),
  (.artifact_count // 0),
  (if .subagents | type == "array" then (.subagents | length) else 0 end),
  (.task_count // 0),
  (.model.display_name // ""),
  (.cwd // ""),
  (.terminal_width // 80)
' 2>/dev/null || printf "idle\n0\n\nfalse\nfalse\n0\n0\n0\n\n\n80\n")

{
  read -r STATE || STATE="idle"
  read -r USED_PCT || USED_PCT="0"
  read -r VCS_BRANCH || VCS_BRANCH=""
  read -r VCS_DIRTY || VCS_DIRTY="false"
  read -r SANDBOX || SANDBOX="false"
  read -r ARTIFACTS || ARTIFACTS="0"
  read -r SUBAGENTS || SUBAGENTS="0"
  read -r BG_TASKS || BG_TASKS="0"
  read -r MODEL || MODEL=""
  read -r CWD || CWD=""
  read -r COLS || COLS="80"
} <<< "$PARSED"

# ─── Computed Values ─────────────────────────────────────────────────────────
# Use LC_NUMERIC=C to prevent bash printf errors in locales that use commas for decimals
PCT_FMT=$(LC_NUMERIC=C printf "%.1f" "$USED_PCT" 2>/dev/null || echo "0.0")
PCT_INT=${USED_PCT%.*}; PCT_INT=${PCT_INT:-0}

# ─── State Indicator (No background colors) ──────────────────────────────────
case "$STATE" in
  idle)     S="${FG_BRIGHT_GREEN}${B}● READY${R}" ;;
  thinking) S="${FG_BRIGHT_YELLOW}${B}◆ THINKING${R}" ;;
  working)  S="${FG_BRIGHT_CYAN}${B}⚙ WORKING${R}" ;;
  tool_use) S="${FG_BRIGHT_MAGENTA}${B}🔧 TOOL${R}" ;;
  *)        S="${FG_WHITE}${B}⏳ $(echo "$STATE" | tr '[:lower:]' '[:upper:]')${R}" ;;
esac

# ─── VCS Branch ──────────────────────────────────────────────────────────────
V=""
if [ -n "$VCS_BRANCH" ]; then
  if [ "$VCS_DIRTY" = "true" ]; then
    V="${FG_GRAY} ╱ ${FG_BRIGHT_RED}${VCS_BRANCH}${FG_BRIGHT_YELLOW}*${R}"
  else
    V="${FG_GRAY} ╱ ${FG_BRIGHT_BLUE}${VCS_BRANCH}${R}"
  fi
fi

# ─── Model ───────────────────────────────────────────────────────────────────
M=""
if [ -n "$MODEL" ]; then
  M="${FG_GRAY} ╱ ${FG_BRIGHT_MAGENTA}${I}${MODEL}${R}"
fi

# ─── Directory (CWD) ─────────────────────────────────────────────────────────
DIR_FMT=""
if [ -n "$CWD" ]; then
  HOME_DIR="/data/data/com.termux/files/home"
  CWD_SHORT="${CWD/#$HOME_DIR/\~}"
  DIR_FMT="${FG_GRAY} ╱ ${FG_BRIGHT_CYAN}📂 ${CWD_SHORT}${R}"
fi

# ─── Sandbox Badge ───────────────────────────────────────────────────────────
if [ "$SANDBOX" = "true" ]; then
  SB="${FG_GRAY}sandbox ${FG_BRIGHT_GREEN}${B}ON${R}"
else
  SB="${FG_GRAY}sandbox off${R}"
fi

# ─── Context Bar (15 segments, fine-grain Unicode) ────────────────────────────
BAR_LEN=15
FILLED=$((PCT_INT * BAR_LEN / 100))
REMAINDER=$(( (PCT_INT * BAR_LEN) % 100 ))

# Pick color based on percentage
if [ "$PCT_INT" -ge 90 ]; then
  BAR_COLOR="$FG_BRIGHT_RED"
elif [ "$PCT_INT" -ge 60 ]; then
  BAR_COLOR="$FG_BRIGHT_YELLOW"
else
  BAR_COLOR="$FG_BRIGHT_WHITE"
fi

# Build bar with partial-fill last block
BAR=""
for ((i = 0; i < BAR_LEN; i++)); do
  if [ "$i" -lt "$FILLED" ]; then
    BAR="${BAR}█"
  elif [ "$i" -eq "$FILLED" ]; then
    if [ "$REMAINDER" -ge 75 ]; then
      BAR="${BAR}▓"
    elif [ "$REMAINDER" -ge 50 ]; then
      BAR="${BAR}▒"
    elif [ "$REMAINDER" -ge 25 ]; then
      BAR="${BAR}░"
    else
      BAR="${BAR}·"
    fi
  else
    BAR="${BAR}·"
  fi
done

# ─── Stats ───────────────────────────────────────────────────────────────────
CTX="${FG_GRAY}ctx ${BAR_COLOR}${BAR} ${NUM_COLOR}${PCT_FMT}%${R}"
ART_FMT="${FG_GRAY}artifacts ${NUM_COLOR}${ARTIFACTS}${R}"
SUB_FMT="${FG_GRAY}subagents ${NUM_COLOR}${SUBAGENTS}${R}"
BG_FMT="${FG_GRAY}tasks ${NUM_COLOR}${BG_TASKS}${R}"

# ─── Separators ──────────────────────────────────────────────────────────────
DOT="${FG_GRAY} · ${R}"

# ─── Output ──────────────────────────────────────────────────────────────────
LINE1="${S}${M}${DIR_FMT}${V}"
LINE2=" ${CTX}${DOT}${ART_FMT}${DOT}${SUB_FMT}${DOT}${BG_FMT}${DOT}${SB}"

if [ "$COLS" -ge 120 ]; then
  # Wide: single line
  echo -e "${LINE1}${FG_GRAY}  │  ${R}${LINE2}"
elif [ "$COLS" -ge 80 ]; then
  # Medium: two-line layout with border
  echo -e "${FG_GRAY}╭─${R} ${LINE1}"
  echo -e "${FG_GRAY}╰─${R}${LINE2}"
else
  # Narrow: compact two-line, minimal chrome
  echo -e "${S}${M}"
  echo -e "${CTX}${DOT}${BG_FMT}"
fi
