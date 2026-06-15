#!/usr/bin/env bash
# ============================================================
#  gh-accounts.sh — GitHub multi-account SSH manager (TUI)
# ============================================================
set -uo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
STORE="$SSH_DIR/.gh_accounts"

# ── colours & styles ────────────────────────────────────────
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
REV="${ESC}[7m"

FG="${ESC}[38;5;253m"
FG2="${ESC}[38;5;245m"
FG3="${ESC}[38;5;238m"

BG_SEL="${ESC}[48;5;238m"
BG_PANEL="${ESC}[48;5;235m"
BG_STATUS="${ESC}[48;5;236m"

C_GREEN="${ESC}[38;5;120m"
C_CYAN="${ESC}[38;5;80m"
C_YELLOW="${ESC}[38;5;221m"
C_RED="${ESC}[38;5;203m"
C_BLUE="${ESC}[38;5;111m"
C_PURPLE="${ESC}[38;5;141m"
C_ORANGE="${ESC}[38;5;215m"
C_GRAY="${ESC}[38;5;244m"
C_BORDER="${ESC}[38;5;60m"

BG_GREEN="${ESC}[48;5;22m"
BG_RED="${ESC}[48;5;52m"

# ── terminal helpers ─────────────────────────────────────────
tput_cmd() { command -v tput &>/dev/null && tput "$@" 2>/dev/null || true; }
term_rows() { tput lines 2>/dev/null || echo 24; }
term_cols() { tput cols  2>/dev/null || echo 80; }

cursor_hide()     { printf '%s' "${ESC}[?25l"; }
cursor_show()     { printf '%s' "${ESC}[?25h"; }
cursor_move()     { printf '%s' "${ESC}[$1;$2H"; }  # row col (1-based)
clear_screen()    { printf '%s' "${ESC}[2J${ESC}[H"; }
clear_line()      { printf '%s' "${ESC}[2K"; }
save_cursor()     { printf '%s' "${ESC}[s"; }
restore_cursor()  { printf '%s' "${ESC}[u"; }
alt_screen_on()   { printf '%s' "${ESC}[?1049h"; }
alt_screen_off()  { printf '%s' "${ESC}[?1049l"; }

repeat_char() {
  local count=$1 char=$2
  local result=""
  local i
  for (( i=0; i<count; i++ )); do
    result+="$char"
  done
  printf '%s' "$result"
}

# ── box drawing helpers ──────────────────────────────────────
# draw_box row col width height title [color]
draw_box() {
  local row=$1 col=$2 w=$3 h=$4 title="$5" color="${6:-$C_BORDER}"
  local r
  
  # Top border
  cursor_move "$row" "$col"
  printf '%s' "$color"
  if [[ -n "$title" ]]; then
    local t_len=${#title}
    local pad=$(( w - t_len - 4 ))
    if (( pad < 0 )); then pad=0; fi
    printf '╭─ %s %s╮' "$title" "$(repeat_char $pad '─')"
  else
    printf '╭%s╮' "$(repeat_char $(( w - 2 )) '─')"
  fi
  printf '%s' "$RESET"

  # Side borders
  for (( r=1; r<h-1; r++ )); do
    cursor_move "$(( row + r ))" "$col"
    printf '%s│%s' "$color" "$RESET"
    cursor_move "$(( row + r ))" "$(( col + w - 1 ))"
    printf '%s│%s' "$color" "$RESET"
  done

  # Bottom border
  cursor_move "$(( row + h - 1 ))" "$col"
  printf '%s╰%s╯%s' "$color" "$(repeat_char $(( w - 2 )) '─')" "$RESET"
}

clear_area() {  # row col width height
  local row=$1 col=$2 w=$3 h=$4
  local r
  for (( r=0; r<h; r++ )); do
    cursor_move "$(( row + r ))" "$col"
    repeat_char "$w" ' '
  done
}


# read single char (no enter)
read_key() {
  local key
  IFS= read -r -s -n1 key
  # handle escape sequences (arrows etc)
  if [[ "$key" == $'\033' ]]; then
    local seq1 seq2
    IFS= read -r -s -n1 -t 0.1 seq1 || true
    IFS= read -r -s -n1 -t 0.1 seq2 || true
    key="${key}${seq1}${seq2}"
  fi
  printf '%s' "$key"
}

# ── store helpers ─────────────────────────────────────────────
store_init()    { mkdir -p "$SSH_DIR"; touch "$STORE"; chmod 600 "$STORE"; }
store_list()    { cat "$STORE" 2>/dev/null || true; }
store_count()   { grep -c '.' "$STORE" 2>/dev/null || echo 0; }
store_exists()  { grep -q "^$1|" "$STORE" 2>/dev/null; }
store_add()     { echo "$1|$2|$3|$4|unknown" >> "$STORE"; }

store_remove() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$STORE" > "$tmp" || true
  mv "$tmp" "$STORE"; chmod 600 "$STORE"
}

store_get_field() {   # username field(1-5)
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

store_set_status() {  # username status
  local final; final=$(mktemp)
  while IFS='|' read -r u e a k s; do
    if [[ "$u" == "$1" ]]; then
      echo "$u|$e|$a|$k|$2"
    else
      echo "$u|$e|$a|$k|$s"
    fi
  done < "$STORE" > "$final"
  mv "$final" "$STORE"; chmod 600 "$STORE"
}

# ── layout ────────────────────────────────────────────────────
ROWS=0
COLS=0
DETAIL_WIDTH=36
TABLE_WIDTH=0
W_ACT=2
W_STATUS=8
W_ROLE=10
W_USER=10
W_EMAIL=0
W_ALIAS=0
W_KEY=0
SHOW_EMAIL=false
SHOW_ALIAS=false
SHOW_KEY=false

update_dims() {
  ROWS=$(term_rows)
  COLS=$(term_cols)
  if (( COLS < 75 )); then
    DETAIL_WIDTH=0
  else
    DETAIL_WIDTH=36
  fi
  TABLE_WIDTH=$(( COLS - DETAIL_WIDTH ))
  compute_columns
}

pad_right() {   # text width [fill_char]
  local text="$1" width="$2" fill="${3:- }"
  local visible; visible=$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')
  local vlen=${#visible}
  local pad=$(( width - vlen ))
  printf '%s' "$text"
  if (( pad > 0 )); then printf '%*s' "$pad" '' | tr ' ' "${fill}"; fi
}

truncate_str() {  # str maxlen
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    printf '%s…' "${s:0:$(( max - 1 ))}"
  else
    printf '%s' "$s"
  fi
}

agent_status() {
  local code=0
  ssh-add -l &>/dev/null || code=$?
  if (( code == 0 )); then
    echo "Active"
  elif (( code == 1 )); then
    echo "Active (No Keys)"
  else
    echo "Inactive"
  fi
}

draw_info_box() {
  local row=1 col=1 w=46 h=6
  draw_box $row $col $w $h "System Info" "$C_BLUE"
  
  local primary; primary=$(store_get_primary)
  local count;   count=$(store_count)
  local agent;   agent=$(agent_status)
  
  local agent_color="$C_RED"
  if [[ "$agent" == "Active" ]]; then
    agent_color="$C_GREEN"
  elif [[ "$agent" == "Active (No Keys)" ]]; then
    agent_color="$C_YELLOW"
  fi

  cursor_move $(( row + 1 )) $(( col + 2 ))
  printf '%sActive:%s      %s' "${C_GRAY}" "${RESET}" "${primary:-none}"
  
  cursor_move $(( row + 2 )) $(( col + 2 ))
  printf '%sAccounts:%s    %s' "${C_GRAY}" "${RESET}" "${count}"
  
  cursor_move $(( row + 3 )) $(( col + 2 ))
  printf '%sSSH Agent:%s   %s%s%s' "${C_GRAY}" "${RESET}" "${agent_color}" "${agent}" "${RESET}"
  
  cursor_move $(( row + 4 )) $(( col + 2 ))
  local cfg_status="Missing"
  if [[ -f "$CONFIG" ]]; then
    local m_cnt; m_cnt=$(grep -c "^# gh-accounts:" "$CONFIG" 2>/dev/null || echo 0)
    cfg_status="Exists ($m_cnt managed)"
  fi
  printf '%sSSH Config:%s  %s' "${C_GRAY}" "${RESET}" "$cfg_status"
}

draw_ascii_logo() {
  if (( COLS < 85 )); then return; fi
  local r=2
  local col=$(( COLS - 37 )) # logo is 33 chars wide
  
  cursor_move $r $col
  printf '%s┌─┐┬ ┬  ┌─┐┌─┐┌─┐┌─┐┬ ┬┌┐┌┌┬┐┌─┐%s' "$C_CYAN" "$RESET"
  cursor_move $(( r + 1 )) $col
  printf '%s│ ┬├─┤  ├─┤│  │  │ ││ ││││ │ └─┐%s' "$C_BLUE" "$RESET"
  cursor_move $(( r + 2 )) $col
  printf '%s└─┘┴ ┴  ┴ ┴└─┘└─┘└─┘└─┘┴┘└ ┴ └─┘%s' "$C_YELLOW" "$RESET"
  
  cursor_move $(( r + 3 )) $col
  printf '%s GitHub SSH Account Manager TUI %s' "${C_GRAY}${DIM}" "${RESET}"
}

draw_layout_boxes() {
  draw_box 8 1 $TABLE_WIDTH $(( ROWS - 9 )) "Accounts" "$C_BORDER"
  if (( DETAIL_WIDTH > 0 )); then
    draw_box 8 $(( TABLE_WIDTH + 1 )) $DETAIL_WIDTH $(( ROWS - 9 )) "Selection Details" "$C_BORDER"
  fi
}

compute_columns() {
  local inner=$(( TABLE_WIDTH - 2 ))
  
  W_ACT=2
  W_STATUS=8
  W_ROLE=10
  
  if (( inner >= 85 )); then
    W_USER=16
    W_EMAIL=24
    W_ALIAS=18
    W_KEY=16
    SHOW_EMAIL=true
    SHOW_ALIAS=true
    SHOW_KEY=true
  elif (( inner >= 65 )); then
    W_USER=16
    W_EMAIL=18
    W_ALIAS=15
    W_KEY=0
    SHOW_EMAIL=true
    SHOW_ALIAS=true
    SHOW_KEY=false
  elif (( inner >= 45 )); then
    W_USER=18
    W_EMAIL=0
    W_ALIAS=15
    W_KEY=0
    SHOW_EMAIL=false
    SHOW_ALIAS=true
    SHOW_KEY=false
  else
    W_USER=$(( inner - W_ACT - W_STATUS - W_ROLE - 4 ))
    (( W_USER < 10 )) && W_USER=10
    W_EMAIL=0
    W_ALIAS=0
    W_KEY=0
    SHOW_EMAIL=false
    SHOW_ALIAS=false
    SHOW_KEY=false
  fi
}

draw_colheader() {
  cursor_move 9 1
  printf '%s│%s' "$C_BORDER" "$RESET"
  
  printf ' '
  printf '%-*s' $W_ACT ''
  printf '%s%s%-*s%s ' "${BOLD}" "${C_CYAN}" $W_USER "USERNAME" "${RESET}"
  
  if $SHOW_EMAIL; then
    printf '%s%-*s%s ' "${BOLD}" $W_EMAIL "EMAIL" "${RESET}"
  fi
  if $SHOW_ALIAS; then
    printf '%s%s%-*s%s ' "${BOLD}" "${C_PURPLE}" $W_ALIAS "HOST ALIAS" "${RESET}"
  fi
  if $SHOW_KEY; then
    printf '%s%-*s%s ' "${BOLD}" $W_KEY "KEY FILE" "${RESET}"
  fi
  
  printf '%s%-*s%s ' "${BOLD}" $W_STATUS "STATUS" "${RESET}"
  printf '%s%-*s%s' "${BOLD}" $W_ROLE "ROLE" "${RESET}"
  
  local printed=$(( 1 + W_ACT + 1 + W_USER + 1 ))
  if $SHOW_EMAIL; then printed=$(( printed + W_EMAIL + 1 )); fi
  if $SHOW_ALIAS; then printed=$(( printed + W_ALIAS + 1 )); fi
  if $SHOW_KEY;   then printed=$(( printed + W_KEY + 1 )); fi
  printed=$(( printed + W_STATUS + 1 + W_ROLE ))
  
  local remaining=$(( TABLE_WIDTH - 1 - printed ))
  if (( remaining > 0 )); then
    repeat_char $remaining ' '
  fi
  
  printf '%s│%s' "$C_BORDER" "$RESET"
  
  # Divider row (row 10)
  cursor_move 10 1
  printf '%s├%s┤%s' "$C_BORDER" "$(repeat_char $(( TABLE_WIDTH - 2 )) '─')" "$RESET"
}

draw_table() {
  compute_columns
  local table_rows=$(( ROWS - 11 ))  # row 11 to ROWS-3
  local row_num=0
  local -a accs=()

  while IFS='|' read -r u e a k s; do
    [[ -z "$u" ]] && continue
    if [[ -n "$FILTER" ]]; then
      local combined="${u}${e}${a}"
      [[ "${combined,,}" != *"${FILTER,,}"* ]] && continue
    fi
    accs+=("$u|$e|$a|$k|$s")
  done < "$STORE"

  ACC_COUNT=${#accs[@]}
  (( SELECTED >= ACC_COUNT )) && SELECTED=$(( ACC_COUNT > 0 ? ACC_COUNT - 1 : 0 ))
  (( SELECTED < 0 )) && SELECTED=0

  local primary; primary=$(store_get_primary)
  local visible_rows=$(( ROWS - 13 ))
  local scroll=0
  if (( SELECTED >= visible_rows )); then
    scroll=$(( SELECTED - visible_rows + 1 ))
  fi

  local display_row=0
  for (( i=scroll; i<${#accs[@]}; i++ )); do
    (( display_row >= visible_rows )) && break
    local screen_row=$(( 11 + display_row ))
    cursor_move "$screen_row" 1
    
    printf '%s│%s' "$C_BORDER" "$RESET"

    IFS='|' read -r u e a k s <<< "${accs[$i]}"
    local is_sel=false; (( i == SELECTED )) && is_sel=true
    local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true

    local star=' '; $is_prim && star="${C_YELLOW}★${RESET}"
    
    if $is_sel; then
      printf '%s' "$BG_SEL"
    fi
    
    printf ' %s ' "$star"
    
    local u_t; u_t=$(truncate_str "$u" $W_USER)
    if $is_sel; then
      printf '%s%s%-*s%s ' "${BOLD}" "${C_CYAN}" $W_USER "$u_t" "${RESET}${BG_SEL}"
    else
      printf '%s%-*s%s ' "${C_CYAN}" $W_USER "$u_t" "${RESET}"
    fi

    if $SHOW_EMAIL; then
      local e_t; e_t=$(truncate_str "$e" $W_EMAIL)
      if $is_sel; then
        printf '%-*s ' $W_EMAIL "$e_t"
      else
        printf '%s%-*s%s ' "${C_GRAY}" $W_EMAIL "$e_t" "${RESET}"
      fi
    fi

    if $SHOW_ALIAS; then
      local a_t; a_t=$(truncate_str "$a" $W_ALIAS)
      if $is_sel; then
        printf '%s%-*s%s ' "${C_PURPLE}${BOLD}" $W_ALIAS "$a_t" "${RESET}${BG_SEL}"
      else
        printf '%s%-*s%s ' "${C_PURPLE}" $W_ALIAS "$a_t" "${RESET}"
      fi
    fi

    if $SHOW_KEY; then
      local k_t; k_t=$(truncate_str "$k" $W_KEY)
      if $is_sel; then
        printf '%-*s ' $W_KEY "$k_t"
      else
        printf '%s%-*s%s ' "${C_GRAY}" $W_KEY "$k_t" "${RESET}"
      fi
    fi

    local status_badge
    case "$s" in
      ok)      status_badge="${BG_GREEN}${C_GREEN}${BOLD} ok ${RESET}" ;;
      fail)    status_badge="${BG_RED}${C_RED}${BOLD}FAIL${RESET}" ;;
      *)       status_badge="${C_GRAY} -- ${RESET}" ;;
    esac
    
    if $is_sel; then
      printf '%s ' "$status_badge"
      printf '%s' "$BG_SEL"
    else
      printf '%s ' "$status_badge"
    fi

    local role_badge
    if $is_prim; then
      role_badge="${C_YELLOW}${BOLD}primary  ${RESET}"
    else
      role_badge="${C_GRAY}secondary${RESET}"
    fi
    
    if $is_sel; then
      printf '%s' "$role_badge"
      printf '%s' "$BG_SEL"
    else
      printf '%s' "$role_badge"
    fi

    local printed=$(( 1 + W_ACT + 1 + W_USER + 1 ))
    if $SHOW_EMAIL; then printed=$(( printed + W_EMAIL + 1 )); fi
    if $SHOW_ALIAS; then printed=$(( printed + W_ALIAS + 1 )); fi
    if $SHOW_KEY;   then printed=$(( printed + W_KEY + 1 )); fi
    printed=$(( printed + W_STATUS + 1 + W_ROLE ))
    
    local remaining=$(( TABLE_WIDTH - 1 - printed ))
    if (( remaining > 0 )); then
      repeat_char $remaining ' '
    fi
    
    printf '%s' "${RESET}"
    printf '%s│%s\n' "$C_BORDER" "$RESET"
    
    (( display_row++ ))
  done

  # Blank remaining rows
  for (( r=display_row; r<visible_rows; r++ )); do
    cursor_move "$(( 11 + r ))" 1
    printf '%s│%s' "$C_BORDER" "$RESET"
    repeat_char $(( TABLE_WIDTH - 2 )) ' '
    printf '%s│%s\n' "$C_BORDER" "$RESET"
  done

  if (( ACC_COUNT == 0 )); then
    local mid=$(( 11 + visible_rows / 2 ))
    local msg="No accounts · Press 'a' to add one"
    if [[ -n "$FILTER" ]]; then
      msg="No accounts match '${FILTER}'"
    fi
    local mlen=${#msg}
    local mpad=$(( (TABLE_WIDTH - 2 - mlen) / 2 ))
    if (( mpad < 1 )); then mpad=1; fi
    cursor_move "$mid" $(( 1 + mpad ))
    printf '%s%s%s' "${C_GRAY}" "$msg" "${RESET}"
  fi

  FILTERED_ACCS=("${accs[@]}")
  
  if (( DETAIL_WIDTH > 0 )); then
    draw_detail
  fi
}

draw_detail() {
  local col=$(( TABLE_WIDTH + 1 ))
  local r=9
  local dw=$(( DETAIL_WIDTH - 2 ))
  
  if (( ${#FILTERED_ACCS[@]} == 0 )); then
    for (( pr = r; pr < ROWS - 2; pr++ )); do
      cursor_move "$pr" $(( col + 1 ))
      repeat_char $dw ' '
    done
    cursor_move $(( r + 3 )) $(( col + 2 ))
    printf '%sNo account selected%s' "${C_GRAY}" "${RESET}"
    return
  fi

  local entry="${FILTERED_ACCS[$SELECTED]}"
  IFS='|' read -r u e a k s <<< "$entry"
  local primary; primary=$(store_get_primary)
  local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true
  local host; $is_prim && host="github.com" || host="$a"
  local remote="git@${host}:${u}/repo.git"

  detail_row() {  # row label value [val_color]
    cursor_move "$1" $(( col + 1 ))
    printf ' '
    printf '%s%-10s%s ' "${C_GRAY}" "$2" "${RESET}"
    local vc="${3:-${FG}}"
    local val_space=$(( dw - 13 ))
    local val_t; val_t=$(truncate_str "$4" $val_space)
    printf '%s%s%s' "${vc}" "$val_t" "${RESET}"
    local len=$(( 1 + 10 + 1 + ${#val_t} ))
    if (( len < dw )); then
      repeat_char $(( dw - len )) ' '
    fi
  }

  config_row() {  # row label value [val_color]
    cursor_move "$1" $(( col + 1 ))
    printf ' '
    printf '%s%-12s%s ' "${C_GRAY}" "$2" "${RESET}"
    local vc="${3:-${FG}}"
    local val_space=$(( dw - 15 ))
    local val_t; val_t=$(truncate_str "$4" $val_space)
    printf '%s%s%s' "${vc}" "$val_t" "${RESET}"
    local len=$(( 1 + 12 + 1 + ${#val_t} ))
    if (( len < dw )); then
      repeat_char $(( dw - len )) ' '
    fi
  }

  detail_row $(( r   )) "User"   "${C_CYAN}${BOLD}"   "$u"
  detail_row $(( r+1 )) "Email"  "${FG}"               "$e"
  detail_row $(( r+2 )) "Alias"  "${C_PURPLE}"         "$a"
  detail_row $(( r+3 )) "Key"    "${C_GRAY}"           "$k"
  
  local s_color="${C_GREEN}"
  [[ "$s" != "ok" ]] && s_color="${C_RED}"
  detail_row $(( r+4 )) "Status" "$s_color"            "$s"
  
  local r_val="secondary"
  $is_prim && r_val="primary"
  detail_row $(( r+5 )) "Role"   "$( $is_prim && echo "${C_YELLOW}" || echo "${C_GRAY}" )" "$r_val"

  # Divider: Git Config
  cursor_move $(( r+6 )) $(( col + 1 ))
  printf '%s├─ Git Config %s┤%s' "$C_BORDER" "$(repeat_char $(( dw - 14 )) '─')" "$RESET"

  config_row $(( r+7 )) "user.name"  "${C_CYAN}" "$u"
  config_row $(( r+8 )) "user.email" "${C_CYAN}" "$e"

  # Divider: SSH Config
  cursor_move $(( r+9 )) $(( col + 1 ))
  printf '%s├─ SSH Config %s┤%s' "$C_BORDER" "$(repeat_char $(( dw - 14 )) '─')" "$RESET"

  config_row $(( r+10 )) "Host"         "${C_PURPLE}" "$host"
  config_row $(( r+11 )) "HostName"     "${FG}" "github.com"
  config_row $(( r+12 )) "IdentityFile" "${FG}" "~/.ssh/${k}"

  local last_r=$(( r + 12 ))
  if (( ROWS >= 26 )); then
    # Divider: Clone URL
    cursor_move $(( r+13 )) $(( col + 1 ))
    printf '%s├─ Clone URL %s┤%s' "$C_BORDER" "$(repeat_char $(( dw - 13 )) '─')" "$RESET"

    config_row $(( r+14 )) "git clone" "${C_ORANGE}" "$remote"
    last_r=$(( r + 14 ))
  fi

  for (( pr = last_r + 1; pr <= ROWS - 3; pr++ )); do
    cursor_move "$pr" $(( col + 1 ))
    repeat_char $dw ' '
  done
}

draw_filter_bar() {
  cursor_move "$(( ROWS - 1 ))" 1
  printf '%s' "${BG_STATUS}${C_YELLOW}${BOLD} /Filter: ${RESET}${BG_STATUS}${FG}${FILTER}"
  local len=$(( 10 + ${#FILTER} ))
  local remaining=$(( COLS - len ))
  if (( remaining > 0 )); then
    repeat_char $remaining ' '
  fi
  printf '%s' "${RESET}"
}

draw_flash() {  # msg [color]
  local msg="$1" col="${2:-$C_CYAN}"
  local mlen=${#msg}
  local bw=$(( mlen + 6 ))
  local bh=3
  local br=$(( ROWS / 2 - 1 ))
  local bc=$(( (COLS - bw) / 2 ))
  
  clear_area $br $bc $bw $bh
  draw_box $br $bc $bw $bh "" "$col"
  cursor_move $(( br + 1 )) $(( bc + 3 ))
  printf '%s%s%s' "${BOLD}" "$msg" "${RESET}"
  
  sleep 0.8
  full_redraw
}

draw_keybinds() {
  cursor_move "$ROWS" 1
  printf '%s' "${BG_STATUS}${FG}"
  
  local binds=(
    "a:add"
    "d:delete"
    "s:primary"
    "t:test"
    "r:repo"
    "/:filter"
    "q:quit"
  )
  
  printf ' '
  local len=1
  for b in "${binds[@]}"; do
    local key="${b%%:*}"
    local desc="${b##*:}"
    local btn="${C_YELLOW}${BOLD}<${key}>${RESET}${BG_STATUS} ${desc}  "
    printf '%s' "$btn"
    local btn_plain="<${key}> ${desc}  "
    len=$(( len + ${#btn_plain} ))
  done
  
  local remaining=$(( COLS - len ))
  if (( remaining > 0 )); then
    repeat_char $remaining ' '
  fi
  printf '%s' "${RESET}"
}

full_redraw() {
  update_dims
  clear_screen
  draw_info_box
  draw_ascii_logo
  draw_layout_boxes
  draw_colheader
  draw_table
  if [[ -n "$FILTER" ]]; then
    draw_filter_bar
  else
    cursor_move "$(( ROWS - 1 ))" 1
    clear_line
  fi
  draw_keybinds
}

# ── input helpers ─────────────────────────────────────────────
# read a line at given position with a prompt
read_inline() {   # row col prompt varname
  local row=$1 col=$2 prompt="$3"
  cursor_move "$row" "$col"
  printf '%s%s %s' "${C_YELLOW}${BOLD}" "$prompt" "${RESET}"
  cursor_show
  local val=""
  IFS= read -r val
  cursor_hide
  eval "$4=\"\$val\""
}

# mini form in a box
show_form() {
  local bw=56 bh=10
  local br=$(( (ROWS - bh) / 2 ))
  local bc=$(( (COLS - bw) / 2 ))

  clear_area $br $bc $bw $bh
  draw_box $br $bc $bw $bh "Add GitHub Account" "$C_BLUE"

  local -n _user=$1 _email=$2 _alias=$3 _key=$4

  field() {   # form_row label varref default
    local frow=$(( br + $1 )) label="$2" def="$4"
    cursor_move "$frow" "$(( bc + 3 ))"
    printf '%s%-12s%s' "${C_GRAY}" "$label" "${RESET}"
    
    local input_width=34
    cursor_move "$frow" "$(( bc + 17 ))"
    printf '%s%s%s' "${BG_PANEL}" "$(repeat_char $input_width ' ')" "${RESET}"
    
    cursor_move "$frow" "$(( bc + 17 ))"
    printf '%s' "${C_CYAN}"
    cursor_show
    local val=""
    IFS= read -r -e -i "$def" val
    cursor_hide
    printf '%s' "${RESET}"
    eval "$3=\"\$val\""
  }

  field 2 "Username:"  _user  "${_user}"
  field 3 "Email:"     _email "${_email}"
  
  [[ -z "${_alias}" && -n "${_user}" ]] && _alias="github-${_user}"
  [[ -z "${_key}"   && -n "${_user}" ]] && _key="id_ed25519_${_user}"
  
  field 5 "Host Alias:" _alias "${_alias}"
  field 6 "Key File:"   _key   "${_key}"
}

# confirm box
show_confirm() {  # message  → returns 0=yes 1=no
  local msg="$1"
  local bw=50 bh=6
  local br=$(( (ROWS - bh) / 2 ))
  local bc=$(( (COLS - bw) / 2 ))

  clear_area $br $bc $bw $bh
  draw_box $br $bc $bw $bh "Confirm Action" "$C_RED"

  cursor_move "$(( br + 2 ))" "$(( bc + 4 ))"
  printf '%s%s%s' "${FG}" "$msg" "${RESET}"

  cursor_move "$(( br + 4 ))" "$(( bc + 4 ))"
  printf '%s[y]%s Yes   %s[n]%s No' "${C_GREEN}${BOLD}" "${RESET}" "${C_GRAY}" "${RESET}"

  local key; key=$(read_key)
  [[ "$key" == "y" || "$key" == "Y" ]]
}

# set-repo modal
show_repo_modal() {
  local u="$1" e="$2" a="$3" is_prim="$4"
  local host; [[ "$is_prim" == "true" ]] && host="github.com" || host="$a"
  local bw=62 bh=15
  local br=$(( (ROWS - bh) / 2 ))
  local bc=$(( (COLS - bw) / 2 ))

  clear_area $br $bc $bw $bh
  draw_box $br $bc $bw $bh "Local Repo Config Generator" "$C_CYAN"

  cursor_move "$(( br + 2 ))" "$(( bc + 4 ))"
  printf '%sGit Username: %s%s%s' "${C_GRAY}" "${C_GREEN}" "$u" "${RESET}"
  cursor_move "$(( br + 3 ))" "$(( bc + 4 ))"
  printf '%sGit Email:    %s%s%s' "${C_GRAY}" "${C_GREEN}" "$e" "${RESET}"
  
  cursor_move "$(( br + 5 ))" "$(( bc + 4 ))"
  printf '%sEnter repo path (e.g. owner/repo) or Enter to skip:%s' "${C_YELLOW}" "${RESET}"
  cursor_move "$(( br + 6 ))" "$(( bc + 4 ))"
  
  local input_width=52
  printf '%s%s%s' "${BG_PANEL}" "$(repeat_char $input_width ' ')" "${RESET}"
  cursor_move "$(( br + 6 ))" "$(( bc + 4 ))"
  printf '%s' "${C_CYAN}"
  cursor_show
  local rpath=""
  IFS= read -r rpath
  cursor_hide
  printf '%s' "${RESET}"

  cursor_move "$(( br + 8 ))" "$(( bc + 4 ))"
  printf '%sRun these commands inside your local repository:%s' "${C_GRAY}" "${RESET}"
  
  cursor_move "$(( br + 10 ))" "$(( bc + 4 ))"
  printf '%sgit config user.name  "%s"%s' "${C_GREEN}" "$u" "${RESET}"
  cursor_move "$(( br + 11 ))" "$(( bc + 4 ))"
  printf '%sgit config user.email "%s"%s' "${C_GREEN}" "$e" "${RESET}"
  
  cursor_move "$(( br + 12 ))" "$(( bc + 4 ))"
  if [[ -n "$rpath" ]]; then
    printf '%sgit remote set-url origin git@%s:%s.git%s' "${C_ORANGE}${BOLD}" "$host" "$rpath" "${RESET}"
  else
    printf '%sgit remote set-url origin git@%s:OWNER/REPO.git%s' "${C_GRAY}" "$host" "${RESET}"
  fi
  
  cursor_move "$(( br + 14 ))" "$(( bc + 4 ))"
  printf '%s[Press any key to close]%s' "${C_GRAY}" "${RESET}"
  read_key > /dev/null
}

# ── config management ─────────────────────────────────────────
config_ensure() { touch "$CONFIG"; chmod 600 "$CONFIG"; }

config_add_block() {  # alias keyfile username
  config_ensure
  cat >> "$CONFIG" <<BLOCK

# gh-accounts: $3
Host $1
  HostName github.com
  User git
  IdentityFile ${SSH_DIR}/$2
BLOCK
}

config_remove_block() {  # alias
  config_ensure
  python3 - "$CONFIG" "$1" <<'PYEOF'
import sys, re
cfg = open(sys.argv[1]).read()
pattern = r'\n# gh-accounts:.*?\nHost ' + re.escape(sys.argv[2]) + r'\b[^\n]*\n(?:[ \t]+[^\n]*\n)*'
cfg2 = re.sub(pattern, '\n', cfg, flags=re.DOTALL)
open(sys.argv[1], 'w').write(cfg2)
PYEOF
}

config_rewrite_all() {
  config_ensure
  local primary; primary=$(store_get_primary)
  # strip managed blocks
  python3 - "$CONFIG" <<'PYEOF'
import sys, re
cfg = open(sys.argv[1]).read()
cfg2 = re.sub(r'\n# gh-accounts:.*?\nHost \S+\n(?:[ \t]+[^\n]*\n)*', '\n', cfg, flags=re.DOTALL)
open(sys.argv[1], 'w').write(cfg2.strip() + '\n')
PYEOF
  while IFS='|' read -r u e a k s; do
    [[ -z "$u" ]] && continue
    local host
    if [[ "$u" == "$primary" ]]; then
      host="github.com"
    else
      host="$a"
    fi
    printf '\n# gh-accounts: %s\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s/%s\n' \
      "$u" "$host" "$SSH_DIR" "$k" >> "$CONFIG"
  done < "$STORE"
}

# ── state ──────────────────────────────────────────────────────
SELECTED=0
FILTER=""
VIEW="accounts"
FILTERED_ACCS=()
ACC_COUNT=0
RUNNING=true

# Set local git user identity in repositories under $HOME that reference GitHub.
set_local_git_identity_for_home() {
  local name="$1" email="$2"
  # exclude common large or state directories
  local exclude=("$HOME/.cache" "$HOME/.local" "$HOME/.config" "$HOME/.cargo" "$HOME/.npm" "$HOME/.venv" "$HOME/.pyenv" "$HOME/.ssh")

  # Build find command parts
  local find_cmd=(find "$HOME")
  for e in "${exclude[@]}"; do
    find_cmd+=( -path "$e" -prune -o )
  done
  find_cmd+=( -type f -name config -path '*/.git/config' -print )

  local cfg
  while IFS= read -r cfg; do
    local repo_root; repo_root=$(dirname "$(dirname "$cfg")")
    # check remote urls for github reference
    local url
    url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
    if [[ -z "$url" ]]; then
      url=$(git -C "$repo_root" remote -v 2>/dev/null | awk '{print $2; exit}' || true)
    fi
    if [[ -n "$url" && ( "$url" == *github.com* || "$url" == *git@github.com* ) ]]; then
      git -C "$repo_root" config user.name "$name" 2>/dev/null || true
      git -C "$repo_root" config user.email "$email" 2>/dev/null || true
    fi
  done < <("${find_cmd[@]}")
}

# ── actions ────────────────────────────────────────────────────
action_add() {
  local username="" email="" alias="" keyfile=""
  show_form username email alias keyfile

  [[ -z "$username" || -z "$email" || -z "$alias" || -z "$keyfile" ]] && {
    full_redraw; draw_flash "all fields required" "${C_RED}"; full_redraw; return; }
  store_exists "$username" && {
    full_redraw; draw_flash "account '${username}' already exists" "${C_RED}"; full_redraw; return; }

  # keygen
  if [[ ! -f "${SSH_DIR}/${keyfile}" ]]; then
    local msg="Generating SSH key..."
    local bw=$(( ${#msg} + 6 ))
    local bh=3
    local br=$(( ROWS / 2 - 1 ))
    local bc=$(( (COLS - bw) / 2 ))
    clear_area $br $bc $bw $bh
    draw_box $br $bc $bw $bh "" "$C_CYAN"
    cursor_move $(( br + 1 )) $(( bc + 3 ))
    printf '%s%s%s' "${BOLD}" "$msg" "${RESET}"
    ssh-keygen -t ed25519 -C "$email" -f "${SSH_DIR}/${keyfile}" -N "" &>/dev/null
  fi
  ssh-add "${SSH_DIR}/${keyfile}" &>/dev/null || true

  local is_first=false
  [[ ! -s "$STORE" ]] && is_first=true

  store_add "$username" "$email" "$alias" "$keyfile"

  if $is_first; then
    git config --global user.name  "$username" 2>/dev/null || true
    git config --global user.email "$email"    2>/dev/null || true
    config_add_block "github.com" "$keyfile" "$username"
  else
    config_add_block "$alias" "$keyfile" "$username"
  fi

  full_redraw
  draw_flash "✔ added ${username}" "${C_GREEN}"
  full_redraw
}

action_delete() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  IFS='|' read -r u e a k s <<< "$entry"
  local primary; primary=$(store_get_primary)

  full_redraw
  show_confirm "remove '${u}'? key files are kept." || { full_redraw; return; }

  config_remove_block "$( [[ "$u" == "$primary" ]] && echo "github.com" || echo "$a" )"
  store_remove "$u"
  [[ "$u" == "$primary" ]] && [[ -s "$STORE" ]] && {
    local new_prim; new_prim=$(head -1 "$STORE" | cut -d'|' -f1)
    # give it github.com slot
    config_rewrite_all
    local np_email; np_email=$(store_get_field "$new_prim" 2)
    git config --global user.name  "$new_prim"  2>/dev/null || true
    git config --global user.email "$np_email" 2>/dev/null || true
  }
  (( SELECTED > 0 )) && (( SELECTED-- ))
  full_redraw
  draw_flash "removed ${u}" "${C_YELLOW}"
  full_redraw
}

action_set_primary() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  IFS='|' read -r u e a k s <<< "$entry"
  local current; current=$(store_get_primary)
  [[ "$u" == "$current" ]] && { draw_flash "${u} is already primary" "${C_YELLOW}"; full_redraw; return; }

  store_set_primary "$u"
  config_rewrite_all

  if command -v git >/dev/null 2>&1; then
    git config --global user.name "$u" 2>/dev/null || true
    git config --global user.email "$e" 2>/dev/null || true
  fi

  full_redraw
  draw_flash "★ ${u} is now primary" "${C_YELLOW}"
  full_redraw
}

action_test() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  IFS='|' read -r u e a k s <<< "$entry"
  local primary; primary=$(store_get_primary)
  local host; [[ "$u" == "$primary" ]] && host="github.com" || host="$a"

  local msg="Testing connection to ${host}..."
  local bw=$(( ${#msg} + 6 ))
  local bh=3
  local br=$(( ROWS / 2 - 1 ))
  local bc=$(( (COLS - bw) / 2 ))
  clear_area $br $bc $bw $bh
  draw_box $br $bc $bw $bh "" "$C_CYAN"
  cursor_move $(( br + 1 )) $(( bc + 3 ))
  printf '%s%s%s' "${BOLD}" "$msg" "${RESET}"

  local result
  if result=$(ssh -T -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -i "${SSH_DIR}/${k}" "git@${host}" 2>&1); then
    store_set_status "$u" "ok"
    full_redraw; draw_flash "✔ ${u}: authenticated" "${C_GREEN}"
  else
    if echo "$result" | grep -q "successfully authenticated"; then
      store_set_status "$u" "ok"
      full_redraw; draw_flash "✔ ${u}: authenticated" "${C_GREEN}"
    else
      store_set_status "$u" "fail"
      full_redraw; draw_flash "✖ ${u}: auth failed" "${C_RED}"
    fi
  fi
  full_redraw
}

action_repo_modal() {
  (( ACC_COUNT == 0 )) && return
  local entry="${FILTERED_ACCS[$SELECTED]}"
  IFS='|' read -r u e a k s <<< "$entry"
  local primary; primary=$(store_get_primary)
  local is_prim=false; [[ "$u" == "$primary" ]] && is_prim=true

  full_redraw
  show_repo_modal "$u" "$e" "$a" "$is_prim"
  full_redraw
}

action_filter_start() {
  FILTER=""
  draw_filter_bar
  cursor_show
  # read chars until enter/esc
  while true; do
    local key; key=$(read_key)
    case "$key" in
      $'\n'|$'\r') break ;;
      $'\177'|$'\b')
        [[ -n "$FILTER" ]] && FILTER="${FILTER%?}"
        ;;
      $'\033') FILTER=""; break ;;
      *) FILTER+="$key" ;;
    esac
    draw_table
    draw_filter_bar
  done
  cursor_hide
  full_redraw
}

# ── cleanup ────────────────────────────────────────────────────
cleanup() {
  cursor_show
  alt_screen_off
  tput_cmd rmcup 2>/dev/null || true
  tput_cmd cnorm 2>/dev/null || true
  echo
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
trap full_redraw SIGWINCH

# ── main loop ──────────────────────────────────────────────────
if [[ ! -t 0 ]]; then
  echo "error: gh-accounts requires an interactive terminal." >&2
  exit 1
fi
store_init
alt_screen_on
cursor_hide
full_redraw

while $RUNNING; do
  key=$(read_key)
  case "$key" in
    $'\033[A'|k) (( SELECTED > 0 )) && (( SELECTED-- )); draw_table ;;
    $'\033[B'|j) (( SELECTED < ACC_COUNT - 1 )) && (( SELECTED++ )); draw_table ;;
    a) action_add ;;
    d|$'\177') action_delete ;;
    s) action_set_primary ;;
    t) action_test ;;
    r) action_repo_modal ;;
    /) action_filter_start ;;
    $'\033') FILTER=""; full_redraw ;;
    q|Q) RUNNING=false ;;
    *) true ;;
  esac
done
