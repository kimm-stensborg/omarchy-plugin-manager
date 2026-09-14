#!/bin/bash

# Backend tests. Everything runs against a throwaway $HOME holding fake plugins
# and local bare "upstreams", with stand-ins for omarchy-shell, hyprctl and
# omarchy-notification-send first on PATH, so no real plugin is fetched,
# updated or removed, and neither the running shell nor Hyprland is touched.
#
#   ./test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PM="$HERE/bin/plugin-manager"
SELF_ID="io.github.kimm-stensborg.plugin-manager"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_CACHE_HOME="$HOME/.cache"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

PLUGINS="$HOME/.config/omarchy/plugins"
mkdir -p "$PLUGINS"

# Stand-ins, first on PATH:
# - omarchy-shell answers listPlugins from the sandbox's own plugins, remembers
#   what was enabled in $SHELL_ENABLED, and logs every call to $SHELL_LOG;
# - hyprctl reports the bindings in $HYPR_BINDS and the errors in $HYPR_ERRORS,
#   and logs every call to $HYPR_LOG;
# - omarchy-notification-send logs every notification to $NOTIFY_LOG;
# - omarchy logs every call to $OMARCHY_LOG, so a shell restart is observed
#   rather than performed.
mkdir -p "$SANDBOX/bin"
export SHELL_LOG="$SANDBOX/shell.log" SHELL_ENABLED="$SANDBOX/enabled"
export HYPR_LOG="$SANDBOX/hyprctl.log" HYPR_BINDS="$SANDBOX/binds.json" HYPR_ERRORS="$SANDBOX/configerrors"
export NOTIFY_LOG="$SANDBOX/notify.log" OMARCHY_LOG="$SANDBOX/omarchy.log"
touch "$SHELL_LOG" "$SHELL_ENABLED" "$HYPR_LOG" "$HYPR_ERRORS" "$NOTIFY_LOG" "$OMARCHY_LOG"
echo '[]' >"$HYPR_BINDS"
cat >"$SANDBOX/bin/omarchy-shell" <<'SHIM'
#!/bin/bash
[[ ${1:-} == -q ]] && shift
[[ ${1:-} == shell ]] && shift
printf '%s\n' "$*" >>"$SHELL_LOG"
enable() { grep -qxF "$1" "$SHELL_ENABLED" || echo "$1" >>"$SHELL_ENABLED"; }
case "${1:-}" in
listPlugins)
  omarchy-plugin-catalog 2>/dev/null | jq -c --rawfile on "$SHELL_ENABLED" '
    ($on | split("\n")) as $ids
    | map({id, name, kinds, firstParty, enabled: (.id as $id | $ids | index($id) != null)})'
  ;;
enablePlugin | putBarWidget) enable "$2"; echo ok ;;
setPluginEnabled)
  if [[ ${3:-} == true ]]; then
    enable "$2"
  else
    grep -vxF "$2" "$SHELL_ENABLED" >"$SHELL_ENABLED.tmp"
    mv "$SHELL_ENABLED.tmp" "$SHELL_ENABLED"
  fi
  echo ok
  ;;
call) echo unknown ;;
*) echo ok ;;
esac
SHIM
cat >"$SANDBOX/bin/hyprctl" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$HYPR_LOG"
case "$*" in
"binds -j") cat "$HYPR_BINDS" ;;
reload) echo ok ;;
configerrors) cat "$HYPR_ERRORS" ;;
esac
SHIM
cat >"$SANDBOX/bin/omarchy-notification-send" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$NOTIFY_LOG"
SHIM
# `omarchy restart shell` would restart the real desktop shell, which is
# exactly what this file promises not to touch.
cat >"$SANDBOX/bin/omarchy" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_LOG"
SHIM
cp "$SANDBOX/bin/omarchy" "$SANDBOX/bin/omarchy-restart-shell"
chmod +x "$SANDBOX/bin/omarchy-shell" "$SANDBOX/bin/hyprctl" \
  "$SANDBOX/bin/omarchy-notification-send" "$SANDBOX/bin/omarchy" \
  "$SANDBOX/bin/omarchy-restart-shell"
export PATH="$SANDBOX/bin:$PATH"

passed=0
failed=0

check() { # description, jq expression, json
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1"
    echo "      expected: $2"
    echo "      got:      $(head -c 600 <<<"$3")"
  fi
}

# holds <description> <shell condition> -- for what is checked on disk.
holds() {
  if eval "$2"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1"
    echo "      expected to hold: $2"
  fi
}

# write_plugin <dir> <id> <version> [extra-manifest-json]
write_plugin() {
  local extra="${4:-}"
  [[ -n $extra ]] || extra='{}'
  mkdir -p "$1"
  jq -n --arg id "$2" --arg version "$3" --argjson extra "$extra" '
    {schemaVersion: 1, id: $id, name: ($id + " name"), version: $version, author: "Tester",
     license: "MIT", description: ("the " + $id + " plugin"), kinds: ["overlay"],
     entryPoints: {overlay: "Overlay.qml"}} + $extra' >"$1/manifest.json"
  echo 'import QtQuick; Item {}' >"$1/Overlay.qml"
}

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }

# git_plugin <dir> <id> -- a plugin folder that is a git checkout with no remote.
git_plugin() {
  write_plugin "$1" "$2" 1.0.0
  git -C "$1" init -q -b main
  commit_all "$1" "Initial"
}

# test.alpha: a git plugin whose upstream moves two commits ahead.
git init -q --bare -b main "$SANDBOX/alpha.git"
write_plugin "$SANDBOX/alpha-work" test.alpha 1.0.0
git -C "$SANDBOX/alpha-work" init -q -b main
commit_all "$SANDBOX/alpha-work" "Initial"
git -C "$SANDBOX/alpha-work" remote add origin "$SANDBOX/alpha.git"
git -C "$SANDBOX/alpha-work" push -q origin main
git clone -q "$SANDBOX/alpha.git" "$PLUGINS/test.alpha"
write_plugin "$SANDBOX/alpha-work" test.alpha 1.1.0
commit_all "$SANDBOX/alpha-work" "Bump to 1.1.0"
echo "// more" >>"$SANDBOX/alpha-work/Overlay.qml"
commit_all "$SANDBOX/alpha-work" "Add a comment"
git -C "$SANDBOX/alpha-work" push -q origin main

# test.broken: a git plugin with no remote that names an entry point that does
# not exist.
git_plugin "$PLUGINS/test.broken" test.broken
git -C "$PLUGINS/test.broken" rm -q Overlay.qml
commit_all "$PLUGINS/test.broken" "Lose the entry point"

# Plugins that are not git plugins, which the manager leaves alone: test.beta
# dropped in by hand, test.gamma a clone of a built-in, and test.link a symlink
# to a git working copy elsewhere.
write_plugin "$PLUGINS/test.beta" test.beta 0.1.0
write_plugin "$PLUGINS/test.gamma" test.gamma 1.0.0 '{"omarchy": {"clonedFrom": "omarchy.clock"}}'
git_plugin "$SANDBOX/link-work" test.link
ln -s "$SANDBOX/link-work" "$PLUGINS/test.link"
# The manager itself, a git plugin like the rest: listed and checked, but never
# removed or switched off.
git_plugin "$PLUGINS/$SELF_ID" "$SELF_ID"
# A remove backup, which is not a plugin.
write_plugin "$PLUGINS/.test.old.bak.20260101000000" test.old 1.0.0

# ------------------------------------------------------------------ list
out=$("$PM" list)
check "list succeeds" '.ok == true' "$out"
check "list shows the git plugins, sorted, the manager among them" \
  "[.plugins[].id] == [\"$SELF_ID\", \"test.alpha\", \"test.broken\"]" "$out"
check "the manager is marked as itself, and nothing else is" \
  "all(.plugins[]; .self == (.id == \"$SELF_ID\"))" "$out"
check "a git plugin carries its remote, branch and last commit" \
  ".plugins[] | select(.id == \"test.alpha\") | .git.remote == \"$SANDBOX/alpha.git\" and .git.branch == \"main\" and .git.subject == \"Initial\" and .git.dirty == false" "$out"
check "manifest fields come through" \
  '.plugins[] | select(.id == "test.alpha") | .name == "test.alpha name" and .version == "1.0.0" and .author == "Tester" and .license == "MIT" and .kinds == ["overlay"]' "$out"
check "a broken plugin is flagged with the validator's reason" \
  '.plugins[] | select(.id == "test.broken") | .valid == false and (.validationError | test("entry point file not found"))' "$out"
check "a valid plugin is not flagged" '.plugins[] | select(.id == "test.alpha") | .valid == true' "$out"
check "nothing is checked yet" '.plugins[] | select(.id == "test.alpha") | .update == null' "$out"

# ----------------------------------------------------------------- check
out=$("$PM" check)
check "check succeeds and stamps the time" '.ok == true and (.checkedAt | type == "string")' "$out"
check "check finds alpha two commits behind, at 1.1.0" \
  '.plugins["test.alpha"] | .behind == 2 and .ahead == 0 and .remoteVersion == "1.1.0" and .error == ""' "$out"
check "check lists the incoming commits, newest first" \
  '[.plugins["test.alpha"].commits[].subject] == ["Add a comment", "Bump to 1.1.0"]' "$out"
check "a git plugin without a remote says why it cannot be checked" '.plugins["test.broken"].error | length > 0' "$out"
check "check leaves out plugins that are not git" \
  '.plugins | (has("test.beta") or has("test.gamma") or has("test.link")) | not' "$out"
check "check covers the manager too" ".plugins | has(\"$SELF_ID\")" "$out"
out=$("$PM" list)
check "list carries the cached update status" \
  '.plugins[] | select(.id == "test.alpha") | .update.behind == 2' "$out"

out=$("$PM" check --if-stale 3600)
check "a fresh cache is returned without fetching" '.plugins["test.alpha"].behind == 2' "$out"

out=$("$PM" check "$SELF_ID")
check "the manager can check itself" ".ok == true and (.plugins | has(\"$SELF_ID\"))" "$out"
out=$("$PM" check test.beta)
check "checking a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"

# ---------------------------------------------------------- notification
: >"$NOTIFY_LOG"
"$PM" check --notify >/dev/null
holds "a check with --notify announces a new update" 'grep -qF "test.alpha name has an update" "$NOTIFY_LOG"'
holds "the notification opens the manager when clicked" \
  'grep -qF -- "--exec omarchy-shell shell summon $SELF_ID {}" "$NOTIFY_LOG"'
: >"$NOTIFY_LOG"
"$PM" check --notify >/dev/null
holds "the same update is not announced twice" '[[ ! -s $NOTIFY_LOG ]]'
"$PM" check >/dev/null
holds "a check without --notify announces nothing" '[[ ! -s $NOTIFY_LOG ]]'

# ---------------------------------------------------------------- update
out=$("$PM" update test.gamma)
check "updating a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"
out=$("$PM" update "$SELF_ID")
check "the manager may update itself" '.message | test("itself") | not' "$out"
out=$("$PM" update test.alpha)
check "update succeeds" '.ok == true and .id == "test.alpha"' "$out"
# rescanPlugins re-reads manifests but not the QML behind them, so code that
# has actually moved is only live after the shell process restarts.
check "an update that moved the plugin asks for a restart" '.restart == true' "$out"
out=$("$PM" update test.alpha)
check "an update with nothing to fetch does not" '.restart == false' "$out"
out=$("$PM" list)
check "after update alpha is at 1.1.0 and no longer behind" \
  '.plugins[] | select(.id == "test.alpha") | .version == "1.1.0" and .update.behind == 0' "$out"

echo "// local edit" >>"$PLUGINS/test.alpha/Overlay.qml"
out=$("$PM" list)
check "a local edit shows as dirty" '.plugins[] | select(.id == "test.alpha") | .git.dirty == true' "$out"
git -C "$PLUGINS/test.alpha" checkout -q -- Overlay.qml

# -------------------------------------------------------- enable/disable
: >"$SHELL_LOG"
out=$("$PM" enable test.alpha)
check "enable goes through the shell" '.ok == true' "$out"
holds "enable asks the shell to enable it" 'grep -qxF "enablePlugin test.alpha {}" "$SHELL_LOG"'
check "an enabled plugin lists as enabled" '.plugins[] | select(.id == "test.alpha") | .enabled == true' "$("$PM" list)"
out=$("$PM" disable test.alpha)
check "disable succeeds" '.ok == true' "$out"
holds "disable asks the shell to disable it" 'grep -qxF "setPluginEnabled test.alpha false" "$SHELL_LOG"'
out=$("$PM" enable test.beta)
check "enabling a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"
out=$("$PM" disable "$SELF_ID")
check "the manager does not switch itself off" '.ok == false and (.message | test("itself"))' "$out"
out=$("$PM" enable "$SELF_ID")
check "nor on" '.ok == false and (.message | test("itself"))' "$out"

# ------------------------------------------------------------------- add
git init -q --bare -b main "$SANDBOX/delta.git"
write_plugin "$SANDBOX/delta-work" test.delta 2.0.0
git -C "$SANDBOX/delta-work" init -q -b main
commit_all "$SANDBOX/delta-work" "Initial"
git -C "$SANDBOX/delta-work" push -q "$SANDBOX/delta.git" main
out=$("$PM" add "$SANDBOX/delta.git")
check "add clones the plugin and reports its id" '.ok == true and .id == "test.delta"' "$out"
holds "the added plugin is on disk" '[[ -f $PLUGINS/test.delta/manifest.json ]]'
check "the added plugin is a git plugin in the list" '[.plugins[].id] | index("test.delta") != null' "$("$PM" list)"
out=$("$PM" add "$SANDBOX/delta.git")
check "adding the same plugin twice is refused" '.ok == false and (.message | test("already"))' "$out"
out=$("$PM" add "")
check "add needs a URL" '.ok == false' "$out"

# ---------------------------------------------------------------- remove
out=$("$PM" remove test.delta)
check "remove succeeds" '.ok == true' "$out"
holds "the removed git plugin is gone" '[[ ! -e $PLUGINS/test.delta ]]'
out=$("$PM" remove test.beta)
check "removing a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"
holds "it is still on disk" '[[ -d $PLUGINS/test.beta ]]'
out=$("$PM" remove test.link)
check "a symlink to a git working copy is not a git plugin" '.ok == false and (.message | test("not a git plugin"))' "$out"
holds "the symlink is still there" '[[ -L $PLUGINS/test.link ]]'
out=$("$PM" remove "$SELF_ID")
check "removing the manager itself is refused" '.ok == false and (.message | test("itself"))' "$out"
holds "the manager is still there" '[[ -d $PLUGINS/$SELF_ID ]]'
out=$("$PM" remove ../../etc)
check "a path is not an id" '.ok == false and (.message | test("invalid"))' "$out"
out=$("$PM" remove test.nope)
check "removing a missing plugin is refused" '.ok == false and (.message | test("not installed"))' "$out"

out=$("$PM" check)
check "a full check drops removed plugins from the cache" '.plugins | has("test.delta") | not' "$out"

# ---------------------------------------------------------------- export
mkdir -p "$HOME/.config/omarchy"
cat >"$HOME/.config/omarchy/shell.json" <<'JSON'
{"version": 1,
 "bar": {"layout": {"left": [], "center": [],
   "right": [{"id": "omarchy.tray"}, {"id": "test.alpha", "format": "x"}, {"id": "omarchy.power"}]}},
 "plugins": []}
JSON
echo test.alpha >>"$SHELL_ENABLED"
git -C "$PLUGINS/test.alpha" remote set-url origin https://example.invalid/alpha.git

out=$("$PM" export "$SANDBOX/export.json")
check "export succeeds and says where" ".ok == true and .path == \"$SANDBOX/export.json\" and .exported == 1" "$out"
doc=$(cat "$SANDBOX/export.json")
check "the export names its format and version" '.format == "omarchy-plugin-manager" and .version == 1 and (.exportedAt | length > 0)' "$doc"
check "only git plugins with a reachable remote are exported" '[.plugins[].id] == ["test.alpha"]' "$doc"
check "an exported plugin carries its URL, commit and enabled state" \
  '.plugins[0] | .url == "https://example.invalid/alpha.git" and (.commit | length == 40) and .enabled == true and .bar == false' "$doc"
check "an exported bar widget carries its place, neighbours and settings" \
  '.plugins[0].placements == [{section: "right", index: 1, after: "omarchy.tray", before: "omarchy.power", settings: {format: "x"}}]' "$doc"
check "a git plugin without a remote is skipped with the reason" \
  '.skipped[] | select(.id == "test.broken") | .reason | test("no remote")' "$doc"
check "plugins that are not git are left out of the export altogether" \
  'all((.plugins + .skipped)[]; .id != "test.beta" and .id != "test.gamma" and .id != "test.link")' "$doc"
check "the manager itself is neither exported nor skipped" \
  "all((.plugins + .skipped)[]; .id != \"$SELF_ID\")" "$doc"

git -C "$PLUGINS/test.alpha" remote set-url origin "$SANDBOX/alpha.git"
"$PM" export "$SANDBOX/export-local.json" >/dev/null
check "a checkout whose remote is a local path is skipped" \
  '(.plugins | length) == 0 and (.skipped[] | select(.id == "test.alpha") | .reason | test("path on this machine"))' \
  "$(cat "$SANDBOX/export-local.json")"
out=$("$PM" export)
check "export without a path writes to the home folder" \
  "(.path | startswith(\"$HOME/omarchy-plugins-\")) and (.path | endswith(\".json\"))" "$out"
holds "the default export file exists" '[[ -f $(jq -r .path <<<"$out") ]]'

# ---------------------------------------------------------------- import
# epsilon: a bar widget placed before omarchy.menu with a label; zeta: an
# overlay with inline settings; eta: a URL that does not clone.
upstream() { # <id> <extra-manifest-json>
  write_plugin "$SANDBOX/$1-work" "$1" 1.0.0 "$2"
  git -C "$SANDBOX/$1-work" init -q -b main
  commit_all "$SANDBOX/$1-work" "Initial"
  git init -q --bare -b main "$SANDBOX/$1.git"
  git -C "$SANDBOX/$1-work" push -q "$SANDBOX/$1.git" main
}
upstream test.epsilon '{"kinds": ["bar-widget"], "entryPoints": {"barWidget": "Overlay.qml"}}'
upstream test.zeta '{}'
jq -n --arg sb "$SANDBOX" '{format: "omarchy-plugin-manager", version: 1, host: "elsewhere", exportedAt: "2026-09-01T10:00:00+02:00",
  plugins: [
    {id: "test.epsilon", name: "Epsilon", url: ($sb + "/test.epsilon.git"), enabled: true, bar: false,
     placements: [{section: "left", index: 0, after: null, before: "omarchy.menu", settings: {label: "hi"}}], settings: {}},
    {id: "test.zeta", name: "Zeta", url: ($sb + "/test.zeta.git"), enabled: true, bar: false, placements: [], settings: {foo: 1}},
    {id: "test.alpha", name: "Alpha", url: ($sb + "/alpha.git"), enabled: true},
    {id: "../evil", name: "Evil", url: "https://example.invalid/evil.git", enabled: true},
    {id: "test.eta", name: "Eta", url: ($sb + "/missing.git"), enabled: false}],
  skipped: [{id: "test.lib", name: "Lib", reason: "its remote is a path on this machine"}]}' >"$SANDBOX/import.json"

out=$("$PM" import "$SANDBOX/import.json" --dry-run)
check "a dry run plans three installs and two skips" '.ok == true and .message == "3 plugins to import · 2 skipped"' "$out"
check "a dry run knows what is already installed" \
  '.plan[] | select(.id == "test.alpha") | .action == "skip" and .reason == "already installed"' "$out"
check "a dry run refuses an id that is a path" '.plan[] | select(.id == "../evil") | .action == "skip" and (.reason | test("invalid"))' "$out"
check "a dry run says where an enabled widget goes" \
  '.plan[] | select(.id == "test.epsilon") | .action == "install" and .where == "in the left section"' "$out"
check "a dry run passes on what the export skipped" '.skippedAtExport[0].id == "test.lib"' "$out"
holds "a dry run clones nothing" '[[ ! -e $PLUGINS/test.epsilon ]]'

: >"$SHELL_LOG"
out=$("$PM" import "$SANDBOX/import.json")
check "an import with a failing URL reports the failure" \
  '.ok == false and (.message | startswith("Imported 2 of 3 plugins · 1 failed: test.eta: ")) and (.output | test("✗ test.eta"))' "$out"
holds "imported plugins are on disk" '[[ -d $PLUGINS/test.epsilon && -d $PLUGINS/test.zeta ]]'
holds "the bar widget is put back beside its neighbour" \
  "grep -qxF 'putBarWidget test.epsilon {\"section\":\"left\",\"before\":\"omarchy.menu\"}' \"\$SHELL_LOG\""
holds "the bar widget gets its settings back" "grep -qxF 'setBarWidget test.epsilon label \"hi\" {}' \"\$SHELL_LOG\""
holds "the overlay is enabled" 'grep -qxF test.zeta "$SHELL_ENABLED"'
check "the overlay gets its inline settings in shell.json" \
  'any(.plugins[]; . == {id: "test.zeta", foo: 1})' "$(cat "$HOME/.config/omarchy/shell.json")"
check "an import reports per plugin what it did" \
  '.output | test("✓ test.epsilon: added, enabled in the left section") and test("✓ test.zeta: added, enabled")' "$out"

out=$("$PM" import "$SANDBOX/import.json" --dry-run)
check "importing the same file again has nothing left to add" '.message | startswith("1 plugin to import")' "$out"
out=$("$PM" import "$SANDBOX/alpha-work/manifest.json")
check "a file that is not an export is refused" '.ok == false and (.message | test("not a Plugin Manager export"))' "$out"
out=$("$PM" import "$SANDBOX/nowhere.json")
check "a missing file is refused" '.ok == false and (.message | test("no file"))' "$out"

# The Import button's search: the default export in the home folder from
# above, one copied into ~/Downloads a while back, and a namesake that is not
# an export at all.
mkdir -p "$HOME/Downloads"
cp "$SANDBOX/import.json" "$HOME/Downloads/omarchy-plugins-elsewhere-20260901.json"
touch -d '2 days ago' "$HOME/Downloads/omarchy-plugins-elsewhere-20260901.json"
echo '{}' >"$HOME/Downloads/omarchy-plugins-junk.json"
home_export=$(ls "$HOME"/omarchy-plugins-*.json)
out=$("$PM" exports)
check "exports finds the exports in home and Downloads, newest first" \
  ".ok == true and .message == \"2 export files\" and [.files[].path] == [\"$home_export\", \"$HOME/Downloads/omarchy-plugins-elsewhere-20260901.json\"]" "$out"
check "exports says where each one came from and what it holds" \
  '.files[1] | .host == "elsewhere" and .exportedAt == "2026-09-01T10:00:00+02:00" and .count == 5' "$out"
check "exports tells an export made here from one made elsewhere" '.files[0].local == true and .files[1].local == false' "$out"
rm "$home_export" "$HOME"/Downloads/omarchy-plugins-*.json
out=$("$PM" exports)
check "exports with none says where it looked" '.ok == true and .files == [] and .message == "No export files in ~ or ~/Downloads"' "$out"

# --------------------------------------------------------------- opening
# Shortcuts come from ~/.config/hypr/*.lua, checked against the stand-in
# hyprctl; menu entries from the user's extension over Omarchy's real defaults,
# whose "Setup" and "Plugins" labels give the path.
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/extensions"
BINDINGS="$HOME/.config/hypr/bindings.lua"
cat >"$BINDINGS" <<'LUA'
-- o.bind("SUPER + SHIFT + Z", "Old alpha", "omarchy-shell shell toggle test.alpha '{}'")
o.bind("SUPER + SHIFT + A", "Alpha thing", "omarchy-shell shell toggle test.alpha '{}'")
-- Kappa overlay (test.kappa)
o.bind("SUPER + K", "Kappa", "omarchy-shell shell toggle test.kappa '{}'")
o.bind("SUPER + B", "Browser", "omarchy-launch-browser")
LUA
cat >"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" <<'JSONC'
{
  // A comment, and a string that only looks like one: "https://example.invalid"
  "setup.plugin.kappa": {"icon":"x","label":"Kappa","action":"kappa-open now"},
}
JSONC
echo '[{"modmask": 65, "key": "A", "description": "Alpha thing", "dispatcher": "__lua", "arg": "1", "submap": ""}]' >"$HYPR_BINDS"
# test.kappa: a git plugin that ships its own opener script.
git_plugin "$PLUGINS/test.kappa" test.kappa
mkdir -p "$PLUGINS/test.kappa/bin"
printf '#!/bin/bash\n' >"$PLUGINS/test.kappa/bin/kappa-open"
chmod +x "$PLUGINS/test.kappa/bin/kappa-open"
commit_all "$PLUGINS/test.kappa" "Add an opener"
# test.theta: a service, with no window to open.
write_plugin "$PLUGINS/test.theta" test.theta 1.0.0 '{"kinds": ["service"], "entryPoints": {"service": "Overlay.qml"}}'
git -C "$PLUGINS/test.theta" init -q -b main
commit_all "$PLUGINS/test.theta" "Initial"

out=$("$PM" list)
check "a shortcut in the Hyprland config is found and is live" \
  '.plugins[] | select(.id == "test.alpha") | .opens.shortcuts | map({keys, description, active}) == [{keys: "SUPER + SHIFT + A", description: "Alpha thing", active: true}]' "$out"
check "a shortcut says where it is written" \
  ".plugins[] | select(.id == \"test.alpha\") | .opens.shortcuts[0] | .file == \"$BINDINGS\" and .line == 2" "$out"
check "a shortcut Hyprland does not have is found but not live" \
  '.plugins[] | select(.id == "test.kappa") | .opens.shortcuts | map({keys, active}) == [{keys: "SUPER + K", active: false}]' "$out"
check "a shortcut written by hand is not the manager's" \
  '.plugins[] | select(.id == "test.alpha") | .opens.shortcuts[0].managed == false' "$out"
check "nor anyone's in particular, a commented-out binding above it notwithstanding" \
  '.plugins[] | select(.id == "test.alpha") | .opens.shortcuts[0].addedBy == null' "$out"
check "a shortcut under the comment a plugin's install.sh writes is the plugin's, and looked after" \
  '.plugins[] | select(.id == "test.kappa") | .opens.shortcuts | map({keys, addedBy, managed}) == [{keys: "SUPER + K", addedBy: "plugin", managed: true}]' "$out"
check "a menu entry that runs a plugin's own script is found, with its path" \
  '.plugins[] | select(.id == "test.kappa") | .opens.menu | map({path, action}) == [{path: "Setup › Plugins › Kappa", action: "kappa-open now"}]' "$out"
check "a plugin's place in the bar is listed" '.plugins[] | select(.id == "test.alpha") | .opens.bar == [{section: "right"}]' "$out"
check "a binding for something else belongs to no plugin" \
  'all(.plugins[]; all(.opens.shortcuts[]; .description != "Browser"))' "$out"
check "Open runs the plugin's live shortcut" \
  ".plugins[] | select(.id == \"test.alpha\") | .openCommand == \"omarchy-shell shell toggle test.alpha '{}'\"" "$out"
check "Open skips a shortcut that is not live and runs the menu entry" \
  '.plugins[] | select(.id == "test.kappa") | .openCommand == "kappa-open now"' "$out"
check "Open falls back to a toggle for a plugin nothing opens" \
  ".plugins[] | select(.id == \"test.broken\") | .openCommand == \"omarchy-shell shell toggle test.broken '{}'\" and .opens == {shortcuts: [], menu: [], bar: []}" "$out"
check "a service has nothing to open" '.plugins[] | select(.id == "test.theta") | .openCommand == ""' "$out"

# ---------------------------------------------------------------- review
echo "// review me" >>"$SANDBOX/alpha-work/Overlay.qml"
commit_all "$SANDBOX/alpha-work" "Ask for a review"
git -C "$SANDBOX/alpha-work" push -q origin main
out=$("$PM" review test.alpha)
check "a review says what an update brings in" \
  '.ok == true and .message == "1 new commit, 1 file changed" and .entry.behind == 1 and .entry.commits[0].subject == "Ask for a review"' "$out"
check "a review lists the changed files with their line counts" \
  '.files == [{path: "Overlay.qml", added: 1, deleted: 0}]' "$out"
check "a review carries the diff" '(.diff | test("\\+// review me")) and .truncated == false and .totalLines > 0' "$out"
check "a review refreshes the cached update status" \
  '.plugins[] | select(.id == "test.alpha") | .update.behind == 1' "$("$PM" list)"
out=$("$PM" review test.broken)
check "a plugin that cannot be fetched cannot be reviewed" '.ok == false and (.message | test("Could not check"))' "$out"
out=$("$PM" review test.gamma)
check "a plugin that is not git cannot be reviewed" '.ok == false and (.message | test("not a git plugin"))' "$out"

# --------------------------------------------------------------- inspect
printf '# Kappa\n\nOpens the **kappa** window.\n' >"$PLUGINS/test.kappa/README.md"
commit_all "$PLUGINS/test.kappa" "Add a README"
out=$("$PM" inspect test.kappa)
check "inspect names the plugin, its kinds and entry points" \
  '.ok == true and .name == "test.kappa name" and .kinds == ["overlay"] and .entryPoints == {overlay: "Overlay.qml"}' "$out"
check "inspect lists every file it ships, with sizes" \
  '[.files[].path] == ["Overlay.qml", "README.md", "bin/kappa-open", "manifest.json"] and all(.files[]; .size > 0)' "$out"
check "inspect marks the files that can run" '.executables == ["bin/kappa-open"]' "$out"
check "inspect carries the README" '.readmeName == "README.md" and (.readme | test("\\*\\*kappa\\*\\* window"))' "$out"
out=$("$PM" inspect test.theta)
check "a plugin without a README says so" '.ok == true and .readmeName == "" and .readme == ""' "$out"
out=$("$PM" inspect test.beta)
check "a plugin that is not git cannot be inspected" '.ok == false' "$out"

# -------------------------------------------------------------- rollback
out=$("$PM" rollback test.kappa)
check "a plugin never updated here has nothing to roll back" '.ok == false and (.message | test("no update"))' "$out"
# alpha is one commit behind since the review above.
before=$(git -C "$PLUGINS/test.alpha" rev-parse HEAD)
"$PM" update test.alpha >/dev/null
after=$(git -C "$PLUGINS/test.alpha" rev-parse HEAD)
check "an update records what a rollback would go back to" \
  ".plugins[] | select(.id == \"test.alpha\") | .rollback.from == \"${before:0:7}\" and .rollback.fromVersion == \"1.1.0\"" "$("$PM" list)"
echo "// local edit" >>"$PLUGINS/test.alpha/Overlay.qml"
out=$("$PM" rollback test.alpha)
check "a rollback over local changes is refused" '.ok == false and (.message | test("local changes"))' "$out"
git -C "$PLUGINS/test.alpha" checkout -q -- Overlay.qml
: >"$SHELL_LOG"
out=$("$PM" rollback test.alpha)
check "a rollback succeeds and says where to" ".ok == true and .message == \"Rolled back test.alpha name to ${before:0:7}\"" "$out"
holds "the plugin is back on the commit it was on" '[[ $(git -C "$PLUGINS/test.alpha" rev-parse HEAD) == "$before" ]]'
holds "the shell is asked to reload it" 'grep -qx rescanPlugins "$SHELL_LOG"'
check "the undone update shows as waiting again, with no second rollback on offer" \
  '.plugins[] | select(.id == "test.alpha") | .update.behind == 1 and .rollback == null' "$("$PM" list)"
out=$("$PM" rollback test.alpha)
check "a rollback is one step, once" '.ok == false' "$out"
"$PM" update test.alpha >/dev/null
git -C "$PLUGINS/test.alpha" commit -q --allow-empty -m "Move on"
check "a plugin that has moved on since its update offers no rollback" \
  '.plugins[] | select(.id == "test.alpha") | .rollback == null' "$("$PM" list)"
out=$("$PM" rollback test.alpha)
check "and refuses one" '.ok == false and (.message | test("moved on"))' "$out"
git -C "$PLUGINS/test.alpha" reset -q --hard "$after"

# ------------------------------------------------------------- shortcuts
out=$("$PM" suggest-key test.kappa)
check "a suggestion starts from the plugin's initials" '.ok == true and .keys == "SUPER + ALT + T"' "$out"
check "more suggestions come with it, the proposal first, twelve at most" \
  '.suggestions[0] == .keys and (.suggestions | length) > 1 and (.suggestions | length) <= 12 and (.suggestions | unique | length) == (.suggestions | length)' "$out"
echo '[{"modmask": 65, "key": "A", "description": "Alpha thing"}, {"modmask": 72, "key": "T", "description": "Terminal thing"}]' >"$HYPR_BINDS"
out=$("$PM" suggest-key test.kappa)
check "a suggestion skips a combination that is taken" '.keys == "SUPER + CTRL + T"' "$out"
check "and so do the other suggestions" 'all(.suggestions[]; . != "SUPER + ALT + T")' "$out"
echo '[{"modmask": 65, "key": "A", "description": "Alpha thing"}]' >"$HYPR_BINDS"

out=$("$PM" keycheck "super+shift+a")
check "a combination is spelled one way, and a taken one says by what" \
  '.ok == true and .keys == "SUPER + SHIFT + A" and .taken == true and .takenBy == "Alpha thing"' "$out"
out=$("$PM" keycheck "alt + super + j")
check "a free combination is free, with the modifiers in order" '.keys == "SUPER + ALT + J" and .taken == false' "$out"
out=$("$PM" keycheck "a")
check "a key without a modifier is refused" '.ok == false' "$out"
out=$("$PM" keycheck "SUPER + K + J")
check "two keys are refused" '.ok == false' "$out"

out=$("$PM" bind test.kappa "SUPER + SHIFT + A")
check "binding a taken combination is refused and says by what" \
  '.ok == false and .taken == true and (.message | test("taken by Alpha thing"))' "$out"
: >"$HYPR_LOG"
out=$("$PM" bind test.kappa "super + alt + k")
check "bind succeeds with the combination spelled out" '.ok == true and .keys == "SUPER + ALT + K"' "$out"
holds "the binding is written below its comment" \
  "grep -A1 -xF -- '-- test.kappa name (test.kappa), bound by Plugin Manager' \"\$BINDINGS\" | grep -qxF 'o.bind(\"SUPER + ALT + K\", \"test.kappa name\", \"kappa-open now\")'"
holds "Hyprland is reloaded" 'grep -qx reload "$HYPR_LOG" && grep -qx configerrors "$HYPR_LOG"'
holds "the bindings written by hand are left alone" 'grep -qF "\"Alpha thing\"" "$BINDINGS" && grep -qF "\"Browser\"" "$BINDINGS"'
holds "binding moves the plugin's own shortcut rather than adding one" \
  '! grep -qxF -- "-- Kappa overlay (test.kappa)" "$BINDINGS" && ! grep -qF "\"SUPER + K\"" "$BINDINGS"'
check "the list knows the manager made it" \
  '.plugins[] | select(.id == "test.kappa") | any(.opens.shortcuts[]; .keys == "SUPER + ALT + K" and .managed and .addedBy == "manager")' "$("$PM" list)"
out=$("$PM" keycheck "SUPER + ALT + K" test.kappa)
check "a plugin's own shortcut is no conflict for itself" '.taken == false' "$out"

"$PM" bind test.kappa "SUPER + ALT + J" >/dev/null
holds "binding again replaces the manager's block rather than adding one" \
  '[[ $(grep -c "(test.kappa), bound by Plugin Manager" "$BINDINGS") == 1 ]] && ! grep -qF "SUPER + ALT + K" "$BINDINGS"'
out=$("$PM" bind test.kappa "SUPER + SHIFT + A" --replace)
check "--replace takes a combination over" '.ok == true' "$out"
holds "taking over unbinds the combination first" \
  "grep -A1 -xF -- '-- test.kappa name (test.kappa), bound by Plugin Manager' \"\$BINDINGS\" | grep -qxF 'hl.unbind(\"SUPER + SHIFT + A\")'"

before=$(md5sum <"$BINDINGS")
echo "error: something broke" >"$HYPR_ERRORS"
out=$("$PM" bind test.kappa "SUPER + ALT + Q")
check "a binding Hyprland rejects is not kept" '.ok == false and (.message | test("rejected"))' "$out"
holds "the bindings are put back as they were" '[[ $(md5sum <"$BINDINGS") == "$before" ]]'
: >"$HYPR_ERRORS"

out=$("$PM" bind test.theta "SUPER + ALT + Z")
check "a plugin with nothing to open gets no binding" '.ok == false and (.message | test("nothing to bind"))' "$out"
out=$("$PM" bind test.beta "SUPER + ALT + Z")
check "a plugin that is not git gets no binding" '.ok == false and (.message | test("not a git plugin"))' "$out"

out=$("$PM" unbind test.kappa)
check "unbind succeeds" '.ok == true' "$out"
holds "unbind takes the whole block out" '! grep -qF "(test.kappa), bound by Plugin Manager" "$BINDINGS" && ! grep -qF "hl.unbind" "$BINDINGS"'
holds "and nothing else" 'grep -qF "\"Alpha thing\"" "$BINDINGS" && grep -qF "\"Browser\"" "$BINDINGS"'
out=$("$PM" unbind test.kappa)
check "unbinding with nothing left to unbind is refused" '.ok == false' "$out"
printf '\n-- Kappa overlay (test.kappa)\no.bind("SUPER + K", "Kappa", "kappa-open now")\n' >>"$BINDINGS"
out=$("$PM" unbind test.kappa)
check "a shortcut a plugin wrote for itself is unbound the same way" '.ok == true' "$out"
holds "its block goes whole, and only it" \
  '! grep -qF "(test.kappa)" "$BINDINGS" && ! grep -qF "\"Kappa\"" "$BINDINGS" && grep -qF "\"Alpha thing\"" "$BINDINGS"'
out=$("$PM" unbind test.alpha)
check "a binding written by hand cannot be unbound here" '.ok == false' "$out"

# ------------------------------------------------------------------ menu
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
# Whether a file still reads as JSONC: comments out (outside strings),
# trailing commas out, then parsed as JSON.
jsonc_ok() {
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
out, i, n, in_str = [], 0, len(text), False
while i < n:
    c = text[i]
    if in_str:
        out.append(c)
        if c == "\\":
            out.append(text[i + 1:i + 2]); i += 2; continue
        if c == '"':
            in_str = False
        i += 1; continue
    if c == '"':
        in_str = True; out.append(c); i += 1; continue
    if text.startswith("//", i):
        j = text.find("\n", i); i = n if j < 0 else j; continue
    out.append(c); i += 1
json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))
PY
}
MARK_KAPPA="  // test.kappa name (test.kappa), added by Plugin Manager"

out=$("$PM" menu-add test.kappa)
check "an entry goes under Setup › Plugins by default, beside the entry already there" \
  '.ok == true and .entry == "setup.plugin.kappa-plugin" and .path == "Setup › Plugins › test.kappa name"' "$out"
holds "the entry is written below its comment" \
  "grep -A1 -xF -- '$MARK_KAPPA' \"\$MENU\" | grep -qF '\"setup.plugin.kappa-plugin\":'"
holds "the entry runs what Open runs, and gets an alias" \
  "grep -F '\"setup.plugin.kappa-plugin\"' \"\$MENU\" | grep -F '\"action\":\"kappa-open now\"' | grep -qF '\"aliases\":[\"kappa\"]'"
holds "the entry that was there is left alone" \
  'grep -qF "\"setup.plugin.kappa\": {\"icon\":\"x\",\"label\":\"Kappa\",\"action\":\"kappa-open now\"}" "$MENU"'
holds "the file still reads as JSONC" 'jsonc_ok "$MENU"'
out=$("$PM" list)
check "the list knows the manager made it" \
  '.plugins[] | select(.id == "test.kappa") | any(.opens.menu[]; .entry == "setup.plugin.kappa-plugin" and .managed and .label == "test.kappa name")' "$out"
check "and that it did not make the one that was there" \
  '.plugins[] | select(.id == "test.kappa") | any(.opens.menu[]; .entry == "setup.plugin.kappa" and (.managed | not))' "$out"

out=$("$PM" menu-add test.alpha --parent apps --label "Alpha" --icon "A" --description "")
check "a place, label and icon can be chosen" '.ok == true and .entry == "apps.alpha" and .path == "Apps › Alpha"' "$out"
holds "an empty description is left out" "! grep -F '\"apps.alpha\"' \"\$MENU\" | grep -qF description"
"$PM" menu-add test.alpha --parent system --label "Alpha" >/dev/null
holds "adding again moves the entry rather than adding a second" \
  '[[ $(grep -c "(test.alpha), added by Plugin Manager" "$MENU") == 1 ]] && grep -qF "\"system.alpha\"" "$MENU" && ! grep -qF "\"apps.alpha\"" "$MENU"'
out=$("$PM" menu-add test.alpha --parent nowhere)
check "a place the menu does not have is refused" '.ok == false' "$out"
out=$("$PM" menu-add test.theta)
check "a plugin with nothing to open gets no entry" '.ok == false and (.message | test("nothing to put in the menu"))' "$out"
out=$("$PM" menu-add test.beta)
check "a plugin that is not git gets no entry" '.ok == false and (.message | test("not a git plugin"))' "$out"
holds "the file still reads as JSONC" 'jsonc_ok "$MENU"'

# The entry before the new one without its comma, as a hand edit can leave it.
cp "$MENU" "$SANDBOX/menu.keep"
printf '{\n  "apps.x": {"label":"X","action":"true"}\n}\n' >"$MENU"
out=$("$PM" menu-add test.kappa)
check "an entry lands after one that lacked its comma" '.ok == true' "$out"
holds "and the comma is put in, so the file still reads" 'jsonc_ok "$MENU" && grep -qxF "  \"apps.x\": {\"label\":\"X\",\"action\":\"true\"}," "$MENU"'
cp "$SANDBOX/menu.keep" "$MENU"

out=$("$PM" menu-remove test.alpha)
check "menu-remove succeeds" '.ok == true' "$out"
holds "it takes out the comment and the entry, and nothing else" \
  '! grep -qF "(test.alpha), added by Plugin Manager" "$MENU" && ! grep -qF "\"system.alpha\"" "$MENU" && grep -qF "\"setup.plugin.kappa-plugin\"" "$MENU" && grep -qF "\"setup.plugin.kappa\":" "$MENU"'
holds "the file still reads as JSONC" 'jsonc_ok "$MENU"'
out=$("$PM" menu-remove test.alpha)
check "removing an entry the manager did not make is refused" '.ok == false' "$out"
"$PM" menu-remove test.kappa >/dev/null

# An entry a plugin wrote for itself, under the comment install.sh uses, next
# to one another plugin wrote the same way.
cp "$MENU" "$SANDBOX/menu.keep"
cat >"$MENU" <<'JSONC'
{
  "apps.x": {"label":"X","action":"true"},

  // ── Other (test.other)
  "setup.other":{"label":"Other","action":"omarchy-shell shell toggle test.other '{}'"},

  // ── Alpha (test.alpha)
  "setup.alpha":{"label":"Alpha","action":"omarchy-shell shell toggle test.alpha '{}'"},
}
JSONC
cp "$MENU" "$SANDBOX/menu.self"
out=$("$PM" list)
check "an entry a plugin wrote for itself is looked after, and says who wrote it" \
  '.plugins[] | select(.id == "test.alpha") | .opens.menu | map({entry, managed, addedBy}) == [{entry: "setup.alpha", managed: true, addedBy: "plugin"}]' "$out"
"$PM" menu-add test.alpha --parent system --label "Alpha" >/dev/null
holds "adding moves the plugin's entry rather than adding a second" \
  '! grep -qF "── Alpha (test.alpha)" "$MENU" && ! grep -qF "\"setup.alpha\"" "$MENU" && [[ $(grep -c "(test.alpha), added by Plugin Manager" "$MENU") == 1 ]] && grep -qF "\"system.alpha\"" "$MENU"'
holds "and leaves the other plugin's entry alone" \
  'grep -qxF "  // ── Other (test.other)" "$MENU" && grep -qF "\"setup.other\"" "$MENU" && jsonc_ok "$MENU"'
out=$("$PM" list)
check "the moved entry is the manager's now" \
  '.plugins[] | select(.id == "test.alpha") | any(.opens.menu[]; .entry == "system.alpha" and .addedBy == "manager")' "$out"
cp "$SANDBOX/menu.self" "$MENU"
out=$("$PM" menu-remove test.alpha)
check "menu-remove takes out an entry the plugin wrote for itself" '.ok == true' "$out"
holds "the comment and entry go, and nothing else" \
  '! grep -qF "(test.alpha)" "$MENU" && ! grep -qF "\"setup.alpha\"" "$MENU" && grep -qF "\"setup.other\"" "$MENU" && grep -qF "\"apps.x\"" "$MENU" && jsonc_ok "$MENU"'
cp "$SANDBOX/menu.keep" "$MENU"

# ------------------------------------------------------------------- run
export PLUGIN_MANAGER_NO_SUMMON=1
STATE="$XDG_CACHE_HOME/omarchy/plugin-manager"
out=$("$PM" run --label "Enabling broken" --id test.broken --kind toggle -- remove "$SELF_ID")
check "run passes the command's reply through" '.ok == false and (.message | test("itself"))' "$out"
out=$(cat "$STATE/last-action.json")
check "run records the reply with its label, id and kind" \
  '.label == "Enabling broken" and .id == "test.broken" and .kind == "toggle" and .result.ok == false and (.seq | length > 0)' "$out"
holds "run clears its running marker when done" '[[ ! -e $STATE/running.json ]]'
seq1=$(jq -r .seq "$STATE/last-action.json")
"$PM" run --label "Removing broken" --id test.broken --kind remove -- remove test.broken >/dev/null
out=$(cat "$STATE/last-action.json")
check "a second run gets a new sequence number" ".seq != \"$seq1\" and .result.ok == true" "$out"
holds "a run really does the work" '[[ ! -e $PLUGINS/test.broken ]]'
out=$("$PM" run --label x -- bogus)
check "a failing command still leaves a reply" '.ok == false' "$out"

# --------------------------------------------------------------- avatars
# A curl that serves a PNG for any GitHub account but "ghost", and logs what
# it was asked for.
export CURL_LOG="$SANDBOX/curl.log"
: >"$CURL_LOG"
cat >"$SANDBOX/bin/curl" <<'SHIM'
#!/bin/bash
out="" url=""
while (($# > 0)); do
  case "$1" in
  -o) out="$2"; shift 2 ;;
  --max-time) shift 2 ;;
  -*) shift ;;
  *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$CURL_LOG"
[[ $url == */ghost.png* ]] && exit 22
printf '\x89PNG\r\n\x1a\nfake' >"$out"
SHIM
chmod +x "$SANDBOX/bin/curl"
AVATARS="$XDG_CACHE_HOME/omarchy/plugin-manager/avatars"
git -C "$PLUGINS/test.kappa" remote add origin https://github.com/Octo-Cat/kappa.git 2>/dev/null ||
  git -C "$PLUGINS/test.kappa" remote set-url origin https://github.com/Octo-Cat/kappa.git
git -C "$PLUGINS/test.alpha" remote set-url origin git@github.com:ghost/alpha.git
out=$("$PM" list)
check "a github.com remote names its owner, over https or ssh, with no avatar yet" \
  '(.plugins[] | select(.id == "test.kappa") | .owner == "Octo-Cat" and .avatar == "") and (.plugins[] | select(.id == "test.alpha") | .owner == "ghost")' "$out"
check "any other remote names no owner" \
  'all(.plugins[] | select(.id != "test.kappa" and .id != "test.alpha"); .owner == null)' "$out"
out=$("$PM" avatars)
check "avatars fetches what it can and says what it could not" \
  '.ok == true and .fetched == ["Octo-Cat"] and .failed == ["ghost"]' "$out"
holds "an avatar is kept under its owner, lower-cased" '[[ -f $AVATARS/octo-cat.png ]]'
holds "and nothing is kept for one that failed" '[[ ! -e $AVATARS/ghost.png ]]'
check "the list then points at it" \
  '.plugins[] | select(.id == "test.kappa") | .avatar == "'"$AVATARS"'/octo-cat.png"' "$("$PM" list)"
calls=$(wc -l <"$CURL_LOG")
out=$("$PM" avatars)
check "a second run fetches nothing" '.fetched == [] and .failed == []' "$out"
holds "and asks for neither the one it has nor the one that failed" '[[ $(wc -l <"$CURL_LOG") == "$calls" ]]'

out=$("$PM" bogus)
check "an unknown command fails as JSON" '.ok == false' "$out"

echo "$passed passed, $failed failed"
((failed == 0))
