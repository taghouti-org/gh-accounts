#!/usr/bin/env bash
# ============================================================
#  gh-accounts.sh — GitHub multi-account SSH manager (TUI)
# ============================================================
set -uo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
STORE="$SSH_DIR/.gh_accounts"
FLASH_DURATION="${GH_ACCOUNTS_FLASH:-0.8}"

# ── ANSI helpers ─────────────────────────────────────────────
ESC=$'\033'
R="${ESC}[0m"          # reset
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

FG="${ESC}[38;5;253m"
BG_SEL="${ESC}[48;5;238m"
BG_PANEL="${ESC}[48;5;235m"
BG_STATUS="${ESC}[48;5;236m"
BG_GREEN="${ESC}[48;5;22m"
BG_RED="${ESC}[48;5;52m"

CG="${ESC}[38;5;120m"   # green
CC="${ESC}[38;5;80m"    # cyan
CY="${ESC}[38;5;221m"   # yellow
CR="${ESC}[38;5;203m"   # red
CB="${ESC}[38;5;111m"   # blue
CP="${ESC}[38;5;141m"   # purple
CO="${ESC}[38;5;215m"   # orange
CGR="${ESC}[38;5;244m"  # gray
CBR="${ESC}[38;5;60m"   # border

# ── terminal primitives ───────────────────────────────────────
_tput()   { command -v tput &>/dev/null && tput "$@" 2>/dev/null || true; }
t_rows()  { tput lines 2>/dev/null || echo 24; }
t_cols()  { tput cols  2>/dev/null || echo 80; }
t_hide()  { printf '%s' "${ESC}[?25l"; }
t_show()  { printf '%s' "${ESC}[?25h"; }
t_move()  { printf '%s' "${ESC}[$1;$2H"; }   # row col
t_cls()   { printf '%s' "${ESC}[2J${ESC}[H"; }
t_clrl()  { printf '%s' "${ESC}[2K"; }
t_alt_on()  { printf '%s' "${ESC}[?1049h"; }
t_alt_off() { printf '%s' "${ESC}[?1049l"; }

rept() {                 # rept N CHAR
  local n=$1 c=$2 s=""
  local i; for (( i=0; i<n; i++ )); do s+="$c"; done
  printf '%s' "$s"
}

trunc() {                # trunc STRING MAX  → truncated
  local s="$1" m=$2
  (( ${#s} > m )) && printf '%s…' "${s:0:$(( m-1 ))}" || printf '%s' "$s"
}

# ── key reading ───────────────────────────────────────────────
read_key() {
  local k
  IFS= read -r -s -n1 k
  if [[ "$k" == $'\033' ]]; then
    local a b
    IFS= read -r -s -n1 -t 0.1 a || true
    IFS= read -r -s -n1 -t 0.1 b || true
    k="${k}${a}${b}"
  fi
  printf '%s' "$k"
}

# ── store ─────────────────────────────────────────────────────
# format: username|email|alias|keyfile|status|notes
store_init() {
  mkdir -p "$SSH_DIR"
  touch "$STORE"
  chmod 600 "$STORE"
}

store_migrate() {
  # Ensure 6 fields per line and remove duplicate usernames
  local tmp; tmp=$(mktemp)
  local -A seen=()
  local u e a k s rest
  while IFS='|' read -r u e a k s rest; do
    [[ -z "$u" ]] && continue
    [[ -n "${seen[$u]:-}" ]] && continue   # skip duplicate
    seen[$u]=1
    printf '%s|%s|%s|%s|%s|%s\n' "$u" "$e" "$a" "$k" "$s" "${rest:-}"
  done < "$STORE" > "$tmp"
  mv "$tmp" "$STORE"
  chmod 600 "$STORE"
}

store_count()   { grep -c '.' "$STORE" 2>/dev/null || echo 0; }
store_exists()  { grep -q "^$1|" "$STORE" 2>/dev/null; }

store_validate() { [[ "$1" != *"|"* ]]; }

store_add() {
  # store_add user email alias key notes
  echo "$1|$2|$3|$4|unknown|$5" >> "$STORE"
}

store_remove() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$STORE" > "$tmp" || true
  mv "$tmp" "$STORE"; chmod 600 "$STORE"
}

store_get_field() {   # store_get_field USER FIELDNUM
  grep "^$1|" "$STORE" | head -1 | cut -d'|' -f"$2"
}

store_get_primary() { head -1 "$STORE" 2>/dev/null | cut -d'|' -f1; }

store_set_primary() {
  local tmp; tmp=$(mktemp)
  local line; line=$(grep "^$1|" "$STORE" | head -1)
  echo "$line" > "$tmp"
  grep -v "^$1|" "$STORE" >> "$tmp" || true
  mv "$tmp" "$STORE"; chmod 600 "$STORE"
}

store_set_field() {   # store_set_field USER FIELDNUM VALUE
  local tmp; tmp=$(mktemp)
  local u e a k s n
  while IFS='|' read -r u e a k s n; do
    if [[ "$u" == "$1" ]]; then
      local -a f=("$u" "$e" "$a" "$k" "$s" "${n:-}")
      f[$(( $2 - 1 ))]="$3"
      printf '%s|%s|%s|%s|%s|%s\n' "${f[@]}"
    else
      printf '%s|%s|%s|%s|%s|%s\n' "$u" "$e" "$a" "$k" "$s" "${n:-}"
    fi
  done < "$STORE" > "$tmp"
  mv "$tmp" "$STORE"; chmod 600 "$STORE"
}

store_set_status() { store_set_field "$1" 5 "$2"; }
store_set_notes()  { store_set_field "$1" 6 "$2"; }

key_exists() { [[ -f "${SSH_DIR}/$1" ]]; }

agent_status() {
  local c=0; ssh-add -l &>/dev/null || c=$?
  case $c in
    0) echo "Active" ;;
    1) echo "Active (No Keys)" ;;
    *) echo "Inactive" ;;
  esac
}

ensure_ssh_agent() {
  ssh-add -l &>/dev/null && return
  [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "${SSH_AUTH_SOCK:-}" ]] &&
    eval "$(ssh-agent -s)" &>/dev/null || true
}

# ── layout state ──────────────────────────────────────────────
ROWS=0; COLS=0
DETAIL_W=36; TABLE_W=0
W_ACT=3; W_USER=10; W_EMAIL=0; W_ALIAS=0; W_KEY=0; W_STATUS=8; W_ROLE=10
SHOW_EMAIL=false; SHOW_ALIAS=false; SHOW_KEY=false

SELECTED=0
FILTER=""
SORT_MODE="none"
declare -a FILTERED_ACCS=()
ACC_COUNT=0
RUNNING=true

update_dims() {
  ROWS=$(t_rows); COLS=$(t_cols)
  (( COLS < 75 )) && DETAIL_W=0 || DETAIL_W=36
  TABLE_W=$(( COLS - DETAIL_W ))
  _compute_cols
}

_compute_cols() {
  local inner=$(( TABLE_W - 2 ))
  W_ACT=3; W_STATUS=8; W_ROLE=10

  if   (( inner >= 85 )); then
    W_USER=16; W_EMAIL=24; W_ALIAS=18; W_KEY=16
    SHOW_EMAIL=true; SHOW_ALIAS=true; SHOW_KEY=true
  elif (( inner >= 65 )); then
    W_USER=16; W_EMAIL=18; W_ALIAS=15; W_KEY=0
    SHOW_EMAIL=true; SHOW_ALIAS=true; SHOW_KEY=false
  elif (( inner >= 45 )); then
    W_USER=18; W_EMAIL=0; W_ALIAS=15; W_KEY=0
    SHOW_EMAIL=false; SHOW_ALIAS=true; SHOW_KEY=false
  else
    W_USER=$(( inner - W_ACT - W_STATUS - W_ROLE - 4 ))
    (( W_USER < 10 )) && W_USER=10
    W_EMAIL=0; W_ALIAS=0; W_KEY=0
    SHOW_EMAIL=false; SHOW_ALIAS=false; SHOW_KEY=false
  fi

  # Shrink columns until they fit
  local avail=$(( TABLE_W - 1 ))
  while true; do
    local total=$(( 1 + W_ACT + 1 + W_USER + 1 ))
    $SHOW_EMAIL && total=$(( total + W_EMAIL + 1 ))
    $SHOW_ALIAS && total=$(( total + W_ALIAS + 1 ))
    $SHOW_KEY   && total=$(( total + W_KEY   + 1 ))
    total=$(( total + W_STATUS + 1 + W_ROLE ))
    (( total <= avail )) && break
    $SHOW_EMAIL && (( W_EMAIL > 0 )) && { (( W_EMAIL-- )); continue; }
    $SHOW_ALIAS && (( W_ALIAS > 0 )) && { (( W_ALIAS-- )); continue; }
    $SHOW_KEY   && (( W_KEY   > 0 )) && { (( W_KEY--   )); continue; }
    (( W_USER > 3 )) && { (( W_USER-- )); continue; }
    break
  done
}

# ── box drawing ───────────────────────────────────────────────
draw_box() {  # row col w h title color
  local row=$1 col=$2 w=$3 h=$4 title="${5:-}" color="${6:-$CBR}"
  local r
  t_move "$row" "$col"
  printf '%s' "$color"
  if [[ -n "$title" ]]; then
    local pad=$(( w - ${#title} - 5 ))
    (( pad < 0 )) && pad=0
    printf '╭─ %s %s╮' "$title" "$(rept $pad '─')"
  else
    printf '╭%s╮' "$(rept $(( w-2 )) '─')"
  fi
  printf '%s' "$R"
  for (( r=1; r<h-1; r++ )); do
    t_move "$(( row+r ))" "$col";         printf '%s│%s' "$color" "$R"
    t_move "$(( row+r ))" "$(( col+w-1 ))"; printf '%s│%s' "$color" "$R"
  done
  t_move "$(( row+h-1 ))" "$col"
  printf '%s╰%s╯%s' "$color" "$(rept $(( w-2 )) '─')" "$R"
}

clear_area() {  # row col w h
  local r
  for (( r=0; r<$4; r++ )); do
    t_move "$(( $1+r ))" "$2"; rept "$3" ' '
  done
}

# ── header / chrome ───────────────────────────────────────────
draw_info_box() {
  draw_box 1 1 46 6 "System Info" "$CB"
  local primary; primary=$(store_get_primary)
  local count;   count=$(store_count)
  local agent;   agent=$(agent_status)
  local acol="$CR"
  [[ "$agent" == "Active" ]]          && acol="$CG"
  [[ "$agent" == "Active (No Keys)" ]] && acol="$CY"
  t_move 2 3; printf '%sActive:%s      %s'    "$CGR" "$R" "${primary:-none}"
  t_move 3 3; printf '%sAccounts:%s    %s'    "$CGR" "$R" "$count"
  t_move 4 3; printf '%sSSH Agent:%s   %s%s%s' "$CGR" "$R" "$acol" "$agent" "$R"
  t_move 5 3
  local cfg="Missing"
  if [[ -f "$CONFIG" ]]; then
    local n; n=$(grep -c "^# gh-accounts:" "$CONFIG" 2>/dev/null || echo 0)
    cfg="Exists ($n managed)"
  fi
  printf '%sSSH Config:%s  %s' "$CGR" "$R" "$cfg"
}

draw_logo() {
  (( COLS < 85 )) && return
  local col=$(( COLS - 37 ))
  t_move 2 "$col"; printf '%s┌─┐┬ ┬  ┌─┐┌─┐┌─┐┌─┐┬ ┬┌┐┌┌┬┐┌─┐%s' "$CC" "$R"
  t_move 3 "$col"; printf '%s│ ┬├─┤  ├─┤│  │  │ ││ ││││ │ └─┐%s' "$CB" "$R"
  t_move 4 "$col"; printf '%s└─┘┴ ┴  ┴ ┴└─┘└─┘└─┘└─┘┘└┘ ┴ └─┘%s' "$CY" "$R"
  t_move 5 "$col"; printf '%s GitHub SSH Account Manager TUI %s'  "${CGR}${DIM}" "$R"
}

draw_frames() {
  draw_box 8 1 "$TABLE_W" "$(( ROWS-9 ))" "Accounts" "$CBR"
  (( DETAIL_W > 0 )) && draw_box 8 "$(( TABLE_W+1 ))" "$DETAIL_W" "$(( ROWS-9 ))" "Selection Details" "$CBR"
}

draw_col_header() {
  t_move 9 1; printf '%s│%s ' "$CBR" "$R"
  rept "$W_ACT" ' '
  printf '%s%s%-*s%s ' "$BOLD" "$CC" "$W_USER" "USERNAME" "$R"
  $SHOW_EMAIL && printf '%s%-*s%s ' "$BOLD" "$W_EMAIL" "EMAIL"      "$R"
  $SHOW_ALIAS && printf '%s%s%-*s%s ' "$BOLD" "$CP" "$W_ALIAS" "HOST ALIAS" "$R"
  $SHOW_KEY   && printf '%s%-*s%s ' "$BOLD" "$W_KEY"   "KEY FILE"   "$R"
  printf '%s%-*s%s ' "$BOLD" "$W_STATUS" "STATUS" "$R"
  printf '%s%-*s%s'  "$BOLD" "$W_ROLE"   "ROLE"   "$R"

  # pad to right border
  local used=$(( 1 + W_ACT + 1 + W_USER + 1 ))
  $SHOW_EMAIL && used=$(( used + W_EMAIL + 1 ))
  $SHOW_ALIAS && used=$(( used + W_ALIAS + 1 ))
  $SHOW_KEY   && used=$(( used + W_KEY   + 1 ))
  used=$(( used + W_STATUS + 1 + W_ROLE ))
  local pad=$(( TABLE_W - 1 - used ))
  (( pad > 0 )) && rept "$pad" ' '
  printf '%s│%s' "$CBR" "$R"

  t_move 10 1; printf '%s├%s┤%s' "$CBR" "$(rept $(( TABLE_W-2 )) '─')" "$R"
}

# ── table rendering ───────────────────────────────────────────
_render_row() {
  local idx=$1 screen_row=$2
  local entry="${FILTERED_ACCS[$idx]}"
  local u e a k s n
  IFS='|' read -r u e a k s n <<< "$entry"

  local primary; primary=$(store_get_primary)
  local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true
  local is_sel=false;  (( idx == SELECTED ))     && is_sel=true

  t_move "$screen_row" 1
  t_clrl
  printf '%s│%s' "$CBR" "$R"

  $is_sel && printf '%s' "$BG_SEL"

  # star column
  local star=' '
  $is_prim && star="${CY}★${R}$( $is_sel && printf '%s' "$BG_SEL" )"
  printf ' %s ' "$star"

  # username
  local ut; ut=$(trunc "$u" "$W_USER")
  if $is_sel; then
    printf '%s%s%-*s%s ' "$BOLD" "$CC" "$W_USER" "$ut" "${R}${BG_SEL}"
  else
    printf '%s%-*s%s ' "$CC" "$W_USER" "$ut" "$R"
  fi

  # email
  if $SHOW_EMAIL; then
    local et; et=$(trunc "$e" "$W_EMAIL")
    if $is_sel; then printf '%-*s ' "$W_EMAIL" "$et"
    else printf '%s%-*s%s ' "$CGR" "$W_EMAIL" "$et" "$R"; fi
  fi

  # alias
  if $SHOW_ALIAS; then
    local at; at=$(trunc "$a" "$W_ALIAS")
    if $is_sel; then printf '%s%-*s%s ' "${CP}${BOLD}" "$W_ALIAS" "$at" "${R}${BG_SEL}"
    else printf '%s%-*s%s ' "$CP" "$W_ALIAS" "$at" "$R"; fi
  fi

  # key file
  if $SHOW_KEY; then
    local kt; kt=$(trunc "$k" "$W_KEY")
    if $is_sel; then printf '%-*s ' "$W_KEY" "$kt"
    else printf '%s%-*s%s ' "$CGR" "$W_KEY" "$kt" "$R"; fi
  fi

  # status badge
  local badge
  case "$s" in
    ok)   badge="${BG_GREEN}${CG}${BOLD} ok ${R}" ;;
    fail) badge="${BG_RED}${CR}${BOLD}FAIL${R}"   ;;
    *)    badge="${CGR} -- ${R}"                   ;;
  esac
  printf '%s ' "$badge"
  $is_sel && printf '%s' "$BG_SEL"

  # role badge
  if $is_prim; then printf '%s%sprimary  %s' "$CY" "$BOLD" "$R"
  else printf '%ssecondary%s' "$CGR" "$R"; fi
  $is_sel && printf '%s' "$BG_SEL"

  # pad to right border
  local used=$(( 1 + W_ACT + 1 + W_USER + 1 ))
  $SHOW_EMAIL && used=$(( used + W_EMAIL + 1 ))
  $SHOW_ALIAS && used=$(( used + W_ALIAS + 1 ))
  $SHOW_KEY   && used=$(( used + W_KEY   + 1 ))
  used=$(( used + 4 + 1 + 9 ))
  local pad=$(( TABLE_W - 1 - used ))
  (( pad > 0 )) && rept "$pad" ' '

  printf '%s' "$R"
  printf '%s │%s' "$CBR" "$R"
}

_render_empty_row() {
  local screen_row=$1
  t_move "$screen_row" 1; t_clrl
  printf '%s│%s' "$CBR" "$R"
  rept $(( TABLE_W - 2 )) ' '
  printf '%s│%s' "$CBR" "$R"
}

_load_filtered() {
  local -a accs=()
  local -A seen=()
  local u e a k s n
  while IFS='|' read -r u e a k s n; do
    [[ -z "$u" ]] && continue
    [[ -n "${seen[$u]:-}" ]] && continue
    if [[ -n "$FILTER" ]]; then
      local combined="${u}${e}${a}${n:-}"
      [[ "${combined,,}" != *"${FILTER,,}"* ]] && continue
    fi
    seen[$u]=1
    accs+=("$u|$e|$a|$k|$s|${n:-}")
  done < "$STORE"
  FILTERED_ACCS=("${accs[@]}")

  case "$SORT_MODE" in
    name)
      local tmp; tmp=$(mktemp)
      printf '%s\n' "${FILTERED_ACCS[@]}" | sort -t'|' -k1,1 > "$tmp"
      readarray -t FILTERED_ACCS < "$tmp"; rm -f "$tmp"
      ;;
    status)
      local tmp; tmp=$(mktemp)
      printf '%s\n' "${FILTERED_ACCS[@]}" | sort -t'|' -k5,5 -r > "$tmp"
      readarray -t FILTERED_ACCS < "$tmp"; rm -f "$tmp"
      ;;
    role)
      local prim; prim=$(store_get_primary)
      local -a p=() s=()
      for entry in "${FILTERED_ACCS[@]}"; do
        local u; u=$(cut -d'|' -f1 <<< "$entry")
        [[ "$u" == "$prim" ]] && p+=("$entry") || s+=("$entry")
      done
      FILTERED_ACCS=("${p[@]}" "${s[@]}")
      ;;
  esac

  ACC_COUNT=${#FILTERED_ACCS[@]}
  (( ACC_COUNT == 0 )) && { SELECTED=0; return; }
  (( SELECTED >= ACC_COUNT )) && SELECTED=$(( ACC_COUNT - 1 ))
  (( SELECTED < 0 ))          && SELECTED=0
}

draw_table() {
  update_dims
  _load_filtered

  local vis=$(( ROWS - 13 ))

  local scroll=0
  (( SELECTED >= vis )) && scroll=$(( SELECTED - vis + 1 ))

  local row=0 i
  for (( i=scroll; i<ACC_COUNT; i++ )); do
    (( row >= vis )) && break
    _render_row "$i" "$(( 11 + row ))"
    (( row++ ))
  done

  for (( ; row<vis; row++ )); do
    _render_empty_row "$(( 11 + row ))"
  done

  if (( ACC_COUNT == 0 )); then
    local msg="No accounts · Press 'a' to add one"
    [[ -n "$FILTER" ]] && msg="No accounts match '${FILTER}'"
    local mid=$(( 11 + vis / 2 ))
    local mpad=$(( (TABLE_W - 2 - ${#msg}) / 2 ))
    (( mpad < 1 )) && mpad=1
    t_move "$mid" "$(( 1 + mpad ))"
    printf '%s%s%s' "$CGR" "$msg" "$R"
  fi

  (( DETAIL_W > 0 )) && draw_detail
}

# ── detail panel ─────────────────────────────────────────────
draw_detail() {
  local col=$(( TABLE_W + 1 ))
  local dw=$(( DETAIL_W - 2 ))
  local r=9

  if (( ACC_COUNT == 0 )); then
    local p
    for (( p=r; p<ROWS-2; p++ )); do
      t_move "$p" "$(( col+1 ))"; rept "$dw" ' '
    done
    t_move "$(( r+3 ))" "$(( col+2 ))"
    printf '%sNo account selected%s' "$CGR" "$R"
    return
  fi

  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n
  IFS='|' read -r u e a k s n <<< "$entry"
  local primary; primary=$(store_get_primary)
  local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true
  local host; $is_prim && host="github.com" || host="$a"
  local remote="git@${host}:${u}/repo.git"

  _drow() {   # _drow ROW LABEL COLOR VALUE
    t_move "$1" "$(( col+1 ))"
    printf ' %s%-10s%s ' "$CGR" "$2" "$R"
    local v; v=$(trunc "$4" "$(( dw - 13 ))")
    printf '%s%s%s' "$3" "$v" "$R"
    local len=$(( 1 + 10 + 1 + ${#v} ))
    (( len < dw )) && rept "$(( dw - len ))" ' '
  }

  _crow() {   # _crow ROW LABEL COLOR VALUE
    t_move "$1" "$(( col+1 ))"
    printf ' %s%-12s%s ' "$CGR" "$2" "$R"
    local v; v=$(trunc "$4" "$(( dw - 15 ))")
    printf '%s%s%s' "$3" "$v" "$R"
    local len=$(( 1 + 12 + 1 + ${#v} ))
    (( len < dw )) && rept "$(( dw - len ))" ' '
  }

  local kc; key_exists "$k" && kc="$CG" || kc="$CR"
  local sc; [[ "$s" == "ok" ]] && sc="$CG" || sc="$CR"
  local rc; $is_prim && rc="$CY" || rc="$CGR"
  local rv; $is_prim && rv="primary" || rv="secondary"

  _drow $(( r   )) "User"   "${CC}${BOLD}" "$u"
  _drow $(( r+1 )) "Email"  "$FG"          "$e"
  _drow $(( r+2 )) "Alias"  "$CP"          "$a"
  _drow $(( r+3 )) "Key"    "$kc"          "$k"
  _drow $(( r+4 )) "Status" "$sc"          "$s"
  _drow $(( r+5 )) "Role"   "$rc"          "$rv"

  local div=$(( r+6 ))
  if [[ -n "${n:-}" ]]; then
    _drow "$div" "Notes" "$CGR" "$n"
    (( div++ ))
  fi

  t_move "$div" "$(( col+1 ))"
  printf '%s├─ Git Config %s┤%s' "$CBR" "$(rept $(( dw-14 )) '─')" "$R"
  _crow $(( div+1 )) "user.name"  "$CC" "$u"
  _crow $(( div+2 )) "user.email" "$CC" "$e"

  t_move "$(( div+3 ))" "$(( col+1 ))"
  printf '%s├─ SSH Config %s┤%s' "$CBR" "$(rept $(( dw-14 )) '─')" "$R"
  _crow $(( div+4 )) "Host"         "$CP" "$host"
  _crow $(( div+5 )) "HostName"     "$FG" "github.com"
  _crow $(( div+6 )) "IdentityFile" "$FG" "~/.ssh/${k}"

  local last=$(( div+6 ))
  if (( ROWS >= 26 )); then
    t_move "$(( last+1 ))" "$(( col+1 ))"
    printf '%s├─ Clone URL %s┤%s' "$CBR" "$(rept $(( dw-13 )) '─')" "$R"
    _crow "$(( last+2 ))" "git clone" "$CO" "$remote"
    last=$(( last+2 ))
  fi

  local p
  for (( p=last+1; p<=ROWS-3; p++ )); do
    t_move "$p" "$(( col+1 ))"; rept "$dw" ' '
  done
}

# ── status / help bars ────────────────────────────────────────
draw_keybinds() {
  local binds=( a:add d:del s:primary t:test T:test-all r:repo i:import R:rotate /:filter S:sort ?:help q:quit )
  local line=" " len=1

  for b in "${binds[@]}"; do
    local key="${b%%:*}" desc="${b##*:}"
    local chunk="<${key}> ${desc}  "
    (( len + ${#chunk} > COLS )) && break
    line+="${CY}${BOLD}<${key}>${R}${BG_STATUS} ${desc}  "
    len=$(( len + ${#chunk} ))
  done

  t_move "$ROWS" 1
  printf '%s%s%s' "$BG_STATUS" "$FG" "$line"
  (( COLS > len )) && rept "$(( COLS - len ))" ' '
  printf '%s' "$R"
}

draw_filter_bar() {
  t_move "$(( ROWS-1 ))" 1
  local sl=""
  [[ "$SORT_MODE" != "none" ]] && sl=" [sort: $SORT_MODE]"
  printf '%s%s%s /Filter: %s%s%s%s' "$BG_STATUS" "$CY" "$BOLD" "$R" "$BG_STATUS" "$FG" "${FILTER}${sl}"
  local len=$(( 10 + ${#FILTER} + ${#sl} ))
  (( COLS > len )) && rept "$(( COLS - len ))" ' '
  printf '%s' "$R"
}

full_redraw() {
  update_dims
  t_cls
  draw_info_box
  draw_logo
  draw_frames
  draw_col_header
  draw_table
  if [[ -n "$FILTER" ]]; then draw_filter_bar
  else t_move "$(( ROWS-1 ))" 1; t_clrl; fi
  draw_keybinds
}

# ── selection movement ────────────────────────────────────────
move_selection() {
  local new=$1
  (( ACC_COUNT == 0 )) && return
  (( new >= ACC_COUNT )) && new=$(( ACC_COUNT - 1 ))
  (( new < 0 ))          && new=0
  (( new == SELECTED ))  && return
  SELECTED=$new
  draw_table
}

# ── flash overlay ─────────────────────────────────────────────
draw_flash() {
  local msg="$1" color="${2:-$CC}"
  local bw=$(( ${#msg} + 6 ))
  local br=$(( ROWS/2 - 1 ))
  local bc=$(( (COLS - bw) / 2 ))
  clear_area "$br" "$bc" "$bw" 3
  draw_box "$br" "$bc" "$bw" 3 "" "$color"
  t_move "$(( br+1 ))" "$(( bc+3 ))"
  printf '%s%s%s' "$BOLD" "$msg" "$R"
  sleep "$FLASH_DURATION"
}

# ── help overlay ──────────────────────────────────────────────
draw_help() {
  local bw=60 bh=26
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Help — Keybindings" "$CB"
  local row=$(( br+2 ))
  local lines=(
    "${CY}${BOLD}Navigation${R}"
    "  j / ↓            Move down"
    "  k / ↑            Move up"
    "  PgDn / Ctrl-D    Page down"
    "  PgUp / Ctrl-U    Page up"
    ""
    "${CY}${BOLD}Actions${R}"
    "  a                Add new account"
    "  d / Del          Delete selected"
    "  s                Set as primary"
    "  t                Test SSH (selected)"
    "  T                Test SSH (all)"
    "  r                Repo config helper"
    "  i                Import existing key"
    "  R                Rotate SSH key"
    "  V                Verify via GitHub API"
    ""
    "${CY}${BOLD}Other${R}"
    "  /                Filter accounts"
    "  Esc              Clear filter"
    "  S                Cycle sort mode"
    "  ?                Toggle this help"
    "  q                Quit"
  )
  for line in "${lines[@]}"; do
    t_move "$row" "$(( bc+3 ))"
    local vis; vis=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s' "$line"
    local pad=$(( bw - 6 - ${#vis} ))
    (( pad > 0 )) && rept "$pad" ' '
    (( row++ ))
  done
  t_move "$(( br+bh-2 ))" "$(( bc+3 ))"
  printf '%s[Press any key to close]%s' "$CGR" "$R"
  read_key > /dev/null
}

# ── forms ─────────────────────────────────────────────────────
_input_field() {  # _input_field ROW COL LABEL DEFAULT → stdout
  t_move "$1" "$2"; printf '%s%-14s%s' "$CGR" "$3" "$R"
  t_move "$1" "$(( $2 + 16 ))"
  printf '%s%s%s' "$BG_PANEL" "$(rept 34 ' ')" "$R"
  t_move "$1" "$(( $2 + 16 ))"; printf '%s' "$CC"
  t_show
  local val=""
  IFS= read -r -e -i "$4" val
  t_hide; printf '%s' "$R"
  printf '%s' "$val"
}

show_add_form() {
  local bw=58 bh=13
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Add GitHub Account" "$CB"

  local -n _u=$1 _e=$2 _al=$3 _k=$4 _n=$5

  _u=$( _input_field "$(( br+2  ))" "$(( bc+2 ))" "Username:"   "${_u}" )
  _e=$( _input_field "$(( br+3  ))" "$(( bc+2 ))" "Email:"      "${_e}" )
  [[ -z "$_al" && -n "$_u" ]] && _al="github-${_u}"
  [[ -z "$_k"  && -n "$_u" ]] && _k="id_ed25519_${_u}"
  _al=$( _input_field "$(( br+5  ))" "$(( bc+2 ))" "Host Alias:" "${_al}" )
  _k=$(  _input_field "$(( br+6  ))" "$(( bc+2 ))" "Key File:"   "${_k}"  )
  _n=$(  _input_field "$(( br+8  ))" "$(( bc+2 ))" "Notes:"      "${_n}"  )
}

show_confirm() {   # show_confirm MESSAGE → 0=yes 1=no
  local msg="$1"
  local bw=52 bh=6
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Confirm" "$CR"
  t_move "$(( br+2 ))" "$(( bc+4 ))"; printf '%s%s%s' "$FG" "$msg" "$R"
  t_move "$(( br+4 ))" "$(( bc+4 ))"; printf '%s[y]%s Yes   %s[n]%s No' "${CG}${BOLD}" "$R" "$CGR" "$R"
  local k; k=$(read_key)
  [[ "$k" == "y" || "$k" == "Y" ]]
}

show_key_type() {  # → stdout: ed25519|rsa|ecdsa
  local bw=40 bh=8
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Key Type" "$CC"
  t_move "$(( br+2 ))" "$(( bc+4 ))"; printf '%s1)%s ed25519 (Recommended)' "${CG}${BOLD}" "$R"
  t_move "$(( br+3 ))" "$(( bc+4 ))"; printf '%s2)%s rsa (4096-bit)'        "$CGR" "$R"
  t_move "$(( br+4 ))" "$(( bc+4 ))"; printf '%s3)%s ecdsa (521-bit)'       "$CGR" "$R"
  t_move "$(( br+6 ))" "$(( bc+4 ))"; printf '%sSelect [1-3]:%s ' "$CY" "$R"
  t_show; local c; IFS= read -r c; t_hide
  case "$c" in 2) echo "rsa";; 3) echo "ecdsa";; *) echo "ed25519";; esac
}

show_repo_modal() {
  local u="$1" e="$2" a="$3" is_prim="$4"
  local host; [[ "$is_prim" == "true" ]] && host="github.com" || host="$a"
  local bw=64 bh=15
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Local Repo Config Generator" "$CC"
  t_move "$(( br+2 ))" "$(( bc+4 ))"; printf '%sGit Username: %s%s%s' "$CGR" "$CG" "$u" "$R"
  t_move "$(( br+3 ))" "$(( bc+4 ))"; printf '%sGit Email:    %s%s%s' "$CGR" "$CG" "$e" "$R"
  t_move "$(( br+5 ))" "$(( bc+4 ))"; printf '%sEnter repo path (owner/repo) or Enter to skip:%s' "$CY" "$R"
  t_move "$(( br+6 ))" "$(( bc+4 ))"; printf '%s%s%s' "$BG_PANEL" "$(rept 52 ' ')" "$R"
  t_move "$(( br+6 ))" "$(( bc+4 ))"; printf '%s' "$CC"; t_show
  local rpath=""; IFS= read -r rpath; t_hide; printf '%s' "$R"
  t_move "$(( br+8  ))" "$(( bc+4 ))"; printf '%sRun inside your local repo:%s' "$CGR" "$R"
  t_move "$(( br+10 ))" "$(( bc+4 ))"; printf '%sgit config user.name  "%s"%s'  "$CG" "$u" "$R"
  t_move "$(( br+11 ))" "$(( bc+4 ))"; printf '%sgit config user.email "%s"%s'  "$CG" "$e" "$R"
  t_move "$(( br+12 ))" "$(( bc+4 ))"
  if [[ -n "$rpath" ]]; then
    printf '%sgit remote set-url origin git@%s:%s.git%s' "${CO}${BOLD}" "$host" "$rpath" "$R"
  else
    printf '%sgit remote set-url origin git@%s:OWNER/REPO.git%s' "$CGR" "$host" "$R"
  fi
  t_move "$(( br+14 ))" "$(( bc+4 ))"; printf '%s[Press any key to close]%s' "$CGR" "$R"
  read_key > /dev/null
}

# ── SSH config management ─────────────────────────────────────
cfg_ensure() { touch "$CONFIG"; chmod 600 "$CONFIG"; }
cfg_backup() { [[ -f "$CONFIG" ]] && cp "$CONFIG" "${CONFIG}.bak" 2>/dev/null || true; }

# _cfg_strip_managed: write CONFIG to stdout with ALL gh-accounts blocks removed.
#
# State machine:
#   normal  – echoing lines as-is; a "# gh-accounts:" comment transitions to → comment
#   comment – we saw the marker comment and are skipping it; the very next non-blank
#             line must be the "Host …" directive → block; anything else is unexpected,
#             we fall back to normal and emit what we skipped
#   block   – inside a managed Host block; blank lines and indented (^[[:space:]])
#             lines belong to the block and are skipped; the first non-blank,
#             non-indented line ends the block (transition back to normal or comment)
#
# This correctly handles:
#   • blank separator lines before/between blocks
#   • unmanaged Host entries immediately after a managed block
#   • back-to-back managed blocks with no separators
_cfg_strip_managed() {
  local state="normal" saved="" line
  while IFS= read -r line; do
    case "$state" in

      normal)
        if [[ "$line" == "# gh-accounts:"* ]]; then
          state="comment"
          saved="$line"
        else
          printf '%s\n' "$line"
        fi
        ;;

      comment)
        # Skip blank lines between the marker and the Host directive
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^Host([[:space:]]|$) ]]; then
          # This is the managed Host line — enter block-skip mode
          state="block"
        else
          # Unexpected: not a Host line after the marker.
          # Emit the saved comment and current line, resume normal.
          printf '%s\n' "$saved"
          printf '%s\n' "$line"
          state="normal"
        fi
        saved=""
        ;;

      block)
        # Blank or indented lines belong to the block — skip them
        if [[ -z "$line" || "$line" =~ ^[[:space:]] ]]; then
          continue
        fi
        # Non-blank, non-indented line ends the block
        if [[ "$line" == "# gh-accounts:"* ]]; then
          # Immediately start another managed block
          state="comment"
          saved="$line"
        else
          # Unmanaged content follows — emit and resume normal
          state="normal"
          printf '%s\n' "$line"
        fi
        ;;

    esac
  done < "$CONFIG"
}

cfg_add_block() {   # cfg_add_block HOST KEYFILE USERNAME
  cfg_ensure; cfg_backup
  cat >> "$CONFIG" <<EOF

# gh-accounts: $3
Host $1
  HostName github.com
  User git
  IdentityFile ${SSH_DIR}/$2
EOF
}

# cfg_remove_block HOST_ALIAS
# Removes the single managed block whose Host directive matches HOST_ALIAS.
# Uses the same state machine as _cfg_strip_managed, extended to distinguish
# the target host from other managed hosts that must be preserved.
cfg_remove_block() {
  local target="$1"
  cfg_ensure; cfg_backup

  local tmp; tmp=$(mktemp)
  local state="normal" saved_comment="" host_line="" line

  while IFS= read -r line; do
    case "$state" in

      normal)
        if [[ "$line" == "# gh-accounts:"* ]]; then
          state="comment"
          saved_comment="$line"
        else
          printf '%s\n' "$line" >> "$tmp"
        fi
        ;;

      comment)
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^Host([[:space:]]|$) ]]; then
          host_line="$line"
          # Extract the first Host token
          local host_val="${line#Host}"
          host_val="${host_val#"${host_val%%[! ]*}"}"   # ltrim spaces
          host_val="${host_val%% *}"                     # first word
          if [[ "$host_val" == "$target" ]]; then
            state="skip"    # drop this block
          else
            state="keep"    # preserve this block
            printf '%s\n' "$saved_comment" >> "$tmp"
            printf '%s\n' "$host_line"     >> "$tmp"
          fi
        else
          # Unexpected — preserve what we buffered
          printf '%s\n' "$saved_comment" >> "$tmp"
          printf '%s\n' "$line"          >> "$tmp"
          state="normal"
        fi
        saved_comment=""; host_line=""
        ;;

      skip)
        # Drop blank and indented lines belonging to the target block
        if [[ -z "$line" || "$line" =~ ^[[:space:]] ]]; then
          continue
        fi
        # End of target block
        if [[ "$line" == "# gh-accounts:"* ]]; then
          state="comment"; saved_comment="$line"
        else
          state="normal"; printf '%s\n' "$line" >> "$tmp"
        fi
        ;;

      keep)
        printf '%s\n' "$line" >> "$tmp"
        # Non-blank, non-indented line ends the kept block
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]] ]]; then
          if [[ "$line" == "# gh-accounts:"* ]]; then
            # Already written above; switch to comment mode but don't double-print
            # Undo last write and buffer the comment instead
            truncate -s "$(( $(stat -c%s "$tmp") - ${#line} - 1 ))" "$tmp" 2>/dev/null || true
            state="comment"; saved_comment="$line"
          else
            state="normal"
          fi
        fi
        ;;

    esac
  done < "$CONFIG"

  mv "$tmp" "$CONFIG"; chmod 600 "$CONFIG"
}

# cfg_rewrite_all: strip every managed block then re-append all accounts from store.
cfg_rewrite_all() {
  cfg_ensure; cfg_backup
  local primary; primary=$(store_get_primary)

  # Strip all managed blocks into a temp file, then replace CONFIG
  local tmp; tmp=$(mktemp)
  _cfg_strip_managed > "$tmp"
  mv "$tmp" "$CONFIG"; chmod 600 "$CONFIG"

  # Re-append one block per account
  local u e a k s n
  while IFS='|' read -r u e a k s n; do
    [[ -z "$u" ]] && continue
    local host; [[ "$u" == "$primary" ]] && host="github.com" || host="$a"
    printf '\n# gh-accounts: %s\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s/%s\n' \
      "$u" "$host" "$SSH_DIR" "$k" >> "$CONFIG"
  done < "$STORE"
}

# ── actions ────────────────────────────────────────────────────
action_add() {
  local u="" e="" al="" k="" n=""
  show_add_form u e al k n

  if [[ -z "$u" || -z "$e" || -z "$al" || -z "$k" ]]; then
    full_redraw; draw_flash "All fields required" "$CR"; full_redraw; return
  fi
  if ! store_validate "$u" || ! store_validate "$e" || ! store_validate "$al" || ! store_validate "$k"; then
    full_redraw; draw_flash "Fields must not contain |" "$CR"; full_redraw; return
  fi
  if store_exists "$u"; then
    full_redraw; draw_flash "Account '${u}' already exists" "$CR"; full_redraw; return
  fi

  if [[ ! -f "${SSH_DIR}/${k}" ]]; then
    local ktype; ktype=$(show_key_type)
    local msg="Generating ${ktype} key…"
    local bw=$(( ${#msg}+6 )) br=$(( ROWS/2-1 )) bc=$(( (COLS-${#msg}-6)/2 ))
    clear_area "$br" "$bc" "$bw" 3
    draw_box "$br" "$bc" "$bw" 3 "" "$CC"
    t_move "$(( br+1 ))" "$(( bc+3 ))"; printf '%s%s%s' "$BOLD" "$msg" "$R"
    local kflag="-t ${ktype}"
    [[ "$ktype" == "rsa"   ]] && kflag="-t rsa -b 4096"
    [[ "$ktype" == "ecdsa" ]] && kflag="-t ecdsa -b 521"
    # shellcheck disable=SC2086
    ssh-keygen $kflag -C "$e" -f "${SSH_DIR}/${k}" -N "" &>/dev/null
  fi
  ssh-add "${SSH_DIR}/${k}" &>/dev/null || true

  local is_first=false; [[ ! -s "$STORE" ]] && is_first=true
  store_add "$u" "$e" "$al" "$k" "$n"

  if $is_first; then
    git config --global user.name  "$u" 2>/dev/null || true
    git config --global user.email "$e" 2>/dev/null || true
    cfg_add_block "github.com" "$k" "$u"
  else
    cfg_add_block "$al" "$k" "$u"
  fi

  full_redraw; draw_flash "✔ Added ${u}" "$CG"; full_redraw
}

action_delete() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  local primary; primary=$(store_get_primary)
  local was_primary=false; [[ "$u" == "$primary" ]] && was_primary=true

  full_redraw
  show_confirm "Remove '${u}'? (key files are kept)" || { full_redraw; return; }

  # Remove from store FIRST so cfg_rewrite_all regenerates without this account
  store_remove "$u"
  cfg_rewrite_all

  # If we removed the primary, promote the new first entry and update git globals
  if $was_primary && [[ -s "$STORE" ]]; then
    local np; np=$(store_get_primary)
    local ne; ne=$(store_get_field "$np" 2)
    git config --global user.name  "$np" 2>/dev/null || true
    git config --global user.email "$ne" 2>/dev/null || true
  fi

  (( SELECTED > 0 )) && (( SELECTED-- ))
  full_redraw; draw_flash "Removed ${u}" "$CY"; full_redraw
}

action_set_primary() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  local current; current=$(store_get_primary)

  if [[ "$u" == "$current" ]]; then
    draw_flash "${u} is already primary" "$CY"; full_redraw; return
  fi

  store_set_primary "$u"
  cfg_rewrite_all
  git config --global user.name  "$u" 2>/dev/null || true
  git config --global user.email "$e" 2>/dev/null || true
  full_redraw; draw_flash "★ ${u} is now primary" "$CY"; full_redraw
}

_ssh_test() {   # _ssh_test ENTRY → sets status, returns 0/1
  local entry="$1"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  local primary; primary=$(store_get_primary)
  local host; [[ "$u" == "$primary" ]] && host="github.com" || host="$a"
  local out
  out=$(ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${SSH_DIR}/${k}" "git@${host}" 2>&1) && {
    store_set_status "$u" "ok"; return 0
  }
  if echo "$out" | grep -q "successfully authenticated"; then
    store_set_status "$u" "ok"; return 0
  fi
  store_set_status "$u" "fail"; return 1
}

action_test() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  local primary; primary=$(store_get_primary)
  local host; [[ "$u" == "$primary" ]] && host="github.com" || host="$a"
  local msg="Testing ${host}…"
  local bw=$(( ${#msg}+6 )) br=$(( ROWS/2-1 )) bc=$(( (COLS-${#msg}-6)/2 ))
  clear_area "$br" "$bc" "$bw" 3
  draw_box "$br" "$bc" "$bw" 3 "" "$CC"
  t_move "$(( br+1 ))" "$(( bc+3 ))"; printf '%s%s%s' "$BOLD" "$msg" "$R"
  if _ssh_test "$entry"; then
    full_redraw; draw_flash "✔ ${u}: authenticated" "$CG"
  else
    full_redraw; draw_flash "✖ ${u}: auth failed" "$CR"
  fi
  full_redraw
}

action_test_all() {
  (( ACC_COUNT == 0 )) && return
  local msg="Testing all accounts…"
  local bw=$(( ${#msg}+6 )) br=$(( ROWS/2-1 )) bc=$(( (COLS-${#msg}-6)/2 ))
  clear_area "$br" "$bc" "$bw" 3
  draw_box "$br" "$bc" "$bw" 3 "" "$CC"
  t_move "$(( br+1 ))" "$(( bc+3 ))"; printf '%s%s%s' "$BOLD" "$msg" "$R"
  local pass=0 fail=0 total=0
  local u e a k s n
  while IFS='|' read -r u e a k s n; do
    [[ -z "$u" ]] && continue
    (( total++ ))
    _ssh_test "$u|$e|$a|$k|$s|${n:-}" && (( pass++ )) || (( fail++ ))
  done < "$STORE"
  local fc; (( fail == 0 )) && fc="$CG" || fc="$CY"
  full_redraw; draw_flash "✔ ${pass}/${total} passed, ${fail} failed" "$fc"; full_redraw
}

action_import() {
  local -a keys=()
  local f
  for f in "${SSH_DIR}"/id_* "${SSH_DIR}"/*.pub; do
    [[ -f "$f" && "$f" != *.pub ]] || continue
    local base; base=$(basename "$f")
    grep -q "|${base}|" "$STORE" 2>/dev/null && continue
    keys+=("$base")
  done

  if (( ${#keys[@]} == 0 )); then
    draw_flash "No unimported keys found" "$CGR"; full_redraw; return
  fi

  local bw=50 bh=$(( ${#keys[@]} + 6 ))
  (( bh < 8 )) && bh=8
  local br=$(( (ROWS-bh)/2 )) bc=$(( (COLS-bw)/2 ))
  clear_area "$br" "$bc" "$bw" "$bh"
  draw_box "$br" "$bc" "$bw" "$bh" "Import SSH Key" "$CC"
  local row=$(( br+2 )) idx=1
  local k
  for k in "${keys[@]}"; do
    t_move "$row" "$(( bc+4 ))"; printf '%s%s)%s %s' "${CG}${BOLD}" "$idx" "$R" "$k"
    (( row++ )); (( idx++ ))
  done
  t_move "$(( row+1 ))" "$(( bc+4 ))"; printf '%sEnter number (or Enter to skip):%s ' "$CY" "$R"
  t_show; local choice; IFS= read -r choice; t_hide

  if [[ -z "$choice" ]] || ! [[ "$choice" =~ ^[0-9]+$ ]] || \
     (( choice < 1 || choice > ${#keys[@]} )); then
    full_redraw; return
  fi

  local sel="${keys[$(( choice-1 ))]}"
  local pub="${SSH_DIR}/${sel}.pub"
  local email_hint=""
  [[ -f "$pub" ]] && email_hint=$(awk '{print $NF}' "$pub" | sed 's/^.*://;s/>$//')

  local bw2=56 bh2=8
  local br2=$(( (ROWS-bh2)/2 )) bc2=$(( (COLS-bw2)/2 ))
  clear_area "$br2" "$bc2" "$bw2" "$bh2"
  draw_box "$br2" "$bc2" "$bw2" "$bh2" "Import: ${sel}" "$CB"

  t_move "$(( br2+2 ))" "$(( bc2+3 ))"; printf '%s%-12s%s' "$CGR" "Username:" "$R"
  t_move "$(( br2+2 ))" "$(( bc2+17 ))"; printf '%s' "$CC"; t_show
  local uname=""; IFS= read -r uname; t_hide

  [[ -z "$uname" ]] && { full_redraw; return; }

  local uemail="$email_hint"
  t_move "$(( br2+3 ))" "$(( bc2+3 ))"; printf '%s%-12s%s' "$CGR" "Email:" "$R"
  t_move "$(( br2+3 ))" "$(( bc2+17 ))"; printf '%s' "$CC"; t_show
  IFS= read -r -e -i "$uemail" uemail; t_hide

  local ualias="github-${uname}"
  store_add "$uname" "$uemail" "$ualias" "$sel" ""
  cfg_add_block "$ualias" "$sel" "$uname"
  full_redraw; draw_flash "✔ Imported ${uname} (${sel})" "$CG"; full_redraw
}

action_rotate() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  full_redraw
  show_confirm "Rotate SSH key for '${u}'?" || { full_redraw; return; }
  local msg="Rotating key for ${u}…"
  local bw=$(( ${#msg}+6 )) br=$(( ROWS/2-1 )) bc=$(( (COLS-${#msg}-6)/2 ))
  clear_area "$br" "$bc" "$bw" 3
  draw_box "$br" "$bc" "$bw" 3 "" "$CC"
  t_move "$(( br+1 ))" "$(( bc+3 ))"; printf '%s%s%s' "$BOLD" "$msg" "$R"
  local old="${SSH_DIR}/${k}"
  [[ -f "$old"      ]] && mv "$old"      "${old}.old"      2>/dev/null || true
  [[ -f "${old}.pub" ]] && mv "${old}.pub" "${old}.pub.old" 2>/dev/null || true
  ssh-keygen -t ed25519 -C "$e" -f "${SSH_DIR}/${k}" -N "" &>/dev/null
  ssh-add "${SSH_DIR}/${k}" &>/dev/null || true
  full_redraw; draw_flash "✔ Key rotated for ${u}" "$CG"; full_redraw
}

action_repo_modal() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  local u e a k s n; IFS='|' read -r u e a k s n <<< "$entry"
  local primary; primary=$(store_get_primary)
  local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true
  full_redraw
  show_repo_modal "$u" "$e" "$a" "$is_prim"
  full_redraw
}

action_sort() {
  case "$SORT_MODE" in
    none)   SORT_MODE="name"   ;;
    name)   SORT_MODE="status" ;;
    status) SORT_MODE="role"   ;;
    role)   SORT_MODE="none"   ;;
  esac
  full_redraw; draw_flash "Sort: ${SORT_MODE}" "$CC"; full_redraw
}

action_filter() {
  FILTER=""
  draw_filter_bar
  t_show
  while true; do
    local k; k=$(read_key)
    case "$k" in
      $'\n'|$'\r')       break ;;
      $'\177'|$'\b')     [[ -n "$FILTER" ]] && FILTER="${FILTER%?}" ;;
      $'\033')           FILTER=""; break ;;
      *)                 FILTER+="$k" ;;
    esac
    draw_table
    draw_filter_bar
  done
  t_hide
  full_redraw
}

# ── cleanup ────────────────────────────────────────────────────
cleanup() {
  stty echo icanon ixon ixoff 2>/dev/null || true
  t_show
  t_alt_off
  _tput rmcup 2>/dev/null || true
  _tput cnorm 2>/dev/null || true
  echo
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
trap full_redraw SIGWINCH

# ── bootstrap ─────────────────────────────────────────────────
[[ ! -t 0 ]] && { echo "error: requires an interactive terminal." >&2; exit 1; }

store_init
store_migrate          # also deduplicates the store file on startup
ensure_ssh_agent

stty -echo -icanon -ixon -ixoff min 1 time 0 2>/dev/null || true

t_alt_on
t_hide
full_redraw

PAGE_SIZE=10

while $RUNNING; do
  key=$(read_key)
  case "$key" in
    $'\033[A'|k) move_selection $(( SELECTED - 1 )) ;;
    $'\033[B'|j) move_selection $(( SELECTED + 1 )) ;;
    $'\033[5~'|$'\025') move_selection $(( SELECTED - PAGE_SIZE )) ;;
    $'\033[6~'|$'\004') move_selection $(( SELECTED + PAGE_SIZE )) ;;
    a)       action_add ;;
    d|$'\177') action_delete ;;
    s)       action_set_primary ;;
    t)       action_test ;;
    T)       action_test_all ;;
    r)       action_repo_modal ;;
    i)       action_import ;;
    R)       action_rotate ;;
    /)       action_filter ;;
    S)       action_sort ;;
    '?')     full_redraw; draw_help; full_redraw ;;
    $'\033') FILTER=""; draw_table ;;
    q|Q)     RUNNING=false ;;
  esac
done
