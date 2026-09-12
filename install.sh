#!/bin/bash

# Wire up the Plugin Manager: a shortcut, a menu entry and the bar button.
#
#   ./install.sh                 pick a shortcut interactively
#   ./install.sh --key "SUPER + ALT + P"
#   ./install.sh --no-bind       skip the shortcut
#   ./install.sh --uninstall     take the shortcut and menu entry out again
#
# The shortcut proposed is the first free one of the candidates below; it can
# be edited before Enter accepts it. The menu entry lands under Setup > Plugins.
# Re-running replaces this script's own blocks rather than stacking new ones.

set -euo pipefail

ID="io.github.kimm-stensborg.plugin-manager"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
MARKER="-- Plugin Manager ($ID)"
MENU_MARKER="  // ── Plugin Manager ($ID)"
TOGGLE="omarchy-shell shell toggle $ID '{}'"

# SUPER + SHIFT + P is Google Photos on a stock Omarchy, so P for plugins
# starts one modifier over.
CANDIDATES=(
  "SUPER + ALT + P"
  "SUPER + CTRL + SHIFT + P"
  "SUPER + SHIFT + U"
  "SUPER + ALT + U"
)

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

interactive() { [[ -t 0 && -t 1 ]]; }

for tool in jq hyprctl omarchy-shell; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

key=""
bind=1
uninstall=0
while (($# > 0)); do
  case "$1" in
  --key)
    key="${2:-}"
    [[ -n $key ]] || fail "--key requires a shortcut"
    shift 2
    ;;
  --no-bind)
    bind=0
    shift
    ;;
  --uninstall)
    uninstall=1
    shift
    ;;
  -h | --help)
    sed -n '3,12p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) fail "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------- shortcut

# "super+shift+l" for any spelling of SUPER + SHIFT + L, so a combination can be
# compared against what Hyprland reports regardless of order or spacing.
normalize() {
  tr 'a-z' 'A-Z' <<<"$1" |
    tr -d ' ' | tr '+' '\n' |
    sed 's/^MOD$/SUPER/; s/^WIN$/SUPER/; s/^CONTROL$/CTRL/; s/^MOD1$/ALT/' |
    awk '
      /^(SUPER|SHIFT|CTRL|ALT)$/ { mods[$0] = 1; next }
      { key = $0 }
      END {
        split("SUPER SHIFT CTRL ALT", order, " ")
        for (i = 1; i <= 4; i++) if (order[i] in mods) out = out tolower(order[i]) "+"
        print out tolower(key)
      }'
}

# Every combination Hyprland has bound outside submaps, in normalize()'s shape,
# with what it does.
bound_combos() {
  hyprctl binds -j | jq -r '
    def mods(m):
      [ if (m / 64 % 2) >= 1 then "super" else empty end,
        if (m % 2) >= 1 then "shift" else empty end,
        if (m / 4 % 2) >= 1 then "ctrl" else empty end,
        if (m / 8 % 2) >= 1 then "alt" else empty end ];
    .[]
    | select(.submap == "" and .key != "")
    | ((mods(.modmask) + [.key | ascii_downcase]) | join("+"))
      + "\t" + (.description // "")
  '
}

describe_conflict() {
  awk -F'\t' -v c="$1" '$1 == c && !found { found = 1; print $2 }' <<<"$TAKEN"
}

is_taken() {
  awk -F'\t' -v c="$1" 'BEGIN { rc = 1 } $1 == c { rc = 0 } END { exit rc }' <<<"$TAKEN"
}

pick_default() {
  local candidate
  for candidate in "${CANDIDATES[@]}"; do
    is_taken "$(normalize "$candidate")" || {
      printf '%s\n' "$candidate"
      return
    }
  done
  printf '%s\n' "${CANDIDATES[0]}"
}

# Drop this script's block from bindings.lua: the marker and the unbind/bind
# lines under it.
strip_binding() {
  [[ -f $BINDINGS ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v marker="$MARKER" '
    $0 == marker { skip = 1; next }
    skip && ($0 ~ /^hl\.unbind\(/ || $0 ~ /^o\.bind\(/) { next }
    { skip = 0; lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$BINDINGS" >"$tmp"
  mv "$tmp" "$BINDINGS"
}

reload_hyprland() {
  hyprctl reload >/dev/null
  local errors
  errors=$(hyprctl configerrors)
  [[ -z ${errors//[[:space:]]/} || $errors == "no errors"* ]] ||
    fail "Hyprland reported config errors:"$'\n'"$errors"
}

write_binding() {
  local combo="$1" conflict="$2"
  mkdir -p "$(dirname "$BINDINGS")"
  touch "$BINDINGS"
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  strip_binding
  {
    printf '\n%s\n' "$MARKER"
    [[ -z $conflict ]] || printf 'hl.unbind("%s")\n' "$combo"
    printf 'o.bind("%s", "Plugin manager", "%s")\n' "$combo" "$TOGGLE"
  } >>"$BINDINGS"
  reload_hyprland
}

# The combination an earlier run bound, so keeping it is not a collision with
# itself.
ours() {
  [[ -f $BINDINGS ]] || return 0
  awk -v marker="$MARKER" '
    $0 == marker { found = 1; next }
    found && /^o\.bind\(/ {
      match($0, /"[^"]+"/)
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' "$BINDINGS"
}

# -------------------------------------------------------------------- menu

# Drop this script's entry from the menu extensions: the marker comment and the
# entry line under it.
strip_menu() {
  [[ -f $MENU ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk -v marker="$MENU_MARKER" '
    $0 == marker { skip = 1; next }
    skip && /"setup\.plugin\.manage"/ { skip = 0; next }
    { skip = 0; print }
  ' "$MENU" >"$tmp"
  mv "$tmp" "$MENU"
}

write_menu() {
  local entry
  entry=$(jq -cn --arg action "$TOGGLE" '{
    "setup.plugin.manage": {icon: "󰐱", label: "Manage Plugins", aliases: ["plugin-manager"],
      description: "List, update, add and remove your plugins", action: $action}
  }' | sed 's/^{//; s/}$//')

  mkdir -p "$(dirname "$MENU")"
  [[ -s $MENU ]] || printf '{\n}\n' >"$MENU"
  cp "$MENU" "$MENU.bak.$(date +%s)"
  strip_menu

  # Into the top-level object, just before its closing brace.
  local tmp
  tmp=$(mktemp)
  awk -v marker="$MENU_MARKER" -v entry="  $entry," '
    { lines[++n] = $0 }
    END {
      last = n
      while (last > 0 && lines[last] !~ /^}[[:space:]]*$/) last--
      if (last == 0) { print "no closing brace in the menu file" > "/dev/stderr"; exit 1 }
      for (i = 1; i < last; i++) print lines[i]
      # One blank line before the block, not one more per re-run.
      if (last > 1 && lines[last - 1] !~ /^[[:space:]]*$/) print ""
      print marker
      print entry
      for (i = last; i <= n; i++) print lines[i]
    }
  ' "$MENU" >"$tmp" || {
    rm -f "$tmp"
    fail "could not add the menu entry to $MENU"
  }
  mv "$tmp" "$MENU"
}

# -------------------------------------------------------------------- main

if ((uninstall)); then
  if [[ -f $BINDINGS ]] && grep -qxF "$MARKER" "$BINDINGS"; then
    cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
    strip_binding
    reload_hyprland
    echo "Removed the shortcut from $BINDINGS"
  fi
  if [[ -f $MENU ]] && grep -qxF "$MENU_MARKER" "$MENU"; then
    cp "$MENU" "$MENU.bak.$(date +%s)"
    strip_menu
    echo "Removed the menu entry from $MENU"
  fi
  echo "The plugin itself stays; remove it with: omarchy plugin remove $ID"
  exit 0
fi

if ((bind)); then
  OURS=$(normalize "$(ours)")
  TAKEN=$(bound_combos | awk -F'\t' -v ours="$OURS" '$1 != ours')

  if [[ -z $key ]]; then
    interactive || fail "no shortcut given; pass --key \"SUPER + ALT + P\" or --no-bind"
    default=$(pick_default)
    if command -v gum >/dev/null; then
      key=$(gum input --header "Shortcut for the Plugin Manager (Enter to accept)" --value "$default") ||
        fail "cancelled"
    else
      read -rp "Shortcut for the Plugin Manager [$default]: " key
    fi
    key="${key:-$default}"
  fi

  combo=$(normalize "$key")
  [[ $combo == *+* ]] || fail "'$key' has no modifier; use something like SUPER + ALT + P"

  conflict=""
  if is_taken "$combo"; then
    conflict=$(describe_conflict "$combo")
    conflict="${conflict:-an existing binding}"
    echo "$key is already bound to: $conflict"
    if interactive; then
      if command -v gum >/dev/null; then
        gum confirm "Take it over?" || fail "aborted"
      else
        read -rp "Take it over? [y/N] " answer
        [[ $answer == [yY]* ]] || fail "aborted"
      fi
    fi
  fi

  write_binding "$key" "$conflict"
  echo "Bound $key to the Plugin Manager in $BINDINGS"
  [[ -z $conflict ]] || echo "It was previously: $conflict"
fi

write_menu
echo "Added Setup > Plugins > Manage Plugins to $MENU"

if omarchy-plugin-list --json | jq -e --arg id "$ID" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
  echo "$ID is already enabled"
else
  omarchy plugin enable "$ID" --section right
fi
