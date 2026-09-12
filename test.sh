#!/bin/bash

# Backend tests. Everything runs against a throwaway $HOME holding fake plugins
# and local bare "upstreams", with a stand-in omarchy-shell first on PATH, so no
# real plugin is fetched, updated or removed and the running shell is never
# asked anything.
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

# A stand-in for omarchy-shell, first on PATH, so no test talks to the running
# shell. It answers listPlugins from the sandbox's own plugins, remembers what
# was enabled in $SHELL_ENABLED, and logs every call to $SHELL_LOG.
mkdir -p "$SANDBOX/bin"
export SHELL_LOG="$SANDBOX/shell.log" SHELL_ENABLED="$SANDBOX/enabled"
touch "$SHELL_LOG" "$SHELL_ENABLED"
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
chmod +x "$SANDBOX/bin/omarchy-shell"
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
# The manager itself, a git plugin like the rest, which must never show up or
# be acted on.
git_plugin "$PLUGINS/$SELF_ID" "$SELF_ID"
# A remove backup, which is not a plugin.
write_plugin "$PLUGINS/.test.old.bak.20260101000000" test.old 1.0.0

# ------------------------------------------------------------------ list
out=$("$PM" list)
check "list succeeds" '.ok == true' "$out"
check "list shows the git plugins, sorted" '[.plugins[].id] == ["test.alpha", "test.broken"]' "$out"
check "list never shows the manager itself" "all(.plugins[]; .id != \"$SELF_ID\")" "$out"
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
check "check skips the manager itself" ".plugins | has(\"$SELF_ID\") | not" "$out"
out=$("$PM" list)
check "list carries the cached update status" \
  '.plugins[] | select(.id == "test.alpha") | .update.behind == 2' "$out"

out=$("$PM" check --if-stale 3600)
check "a fresh cache is returned without fetching" '.plugins["test.alpha"].behind == 2' "$out"

out=$("$PM" check "$SELF_ID")
check "checking the manager itself is refused" '.ok == false' "$out"
out=$("$PM" check test.beta)
check "checking a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"

# ---------------------------------------------------------------- update
out=$("$PM" update test.gamma)
check "updating a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"
out=$("$PM" update test.alpha)
check "update succeeds" '.ok == true and .id == "test.alpha"' "$out"
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
check "enable asks the shell to enable it" 'true' "$(grep -qxF 'enablePlugin test.alpha {}' "$SHELL_LOG" && echo '{}')"
check "an enabled plugin lists as enabled" '.plugins[] | select(.id == "test.alpha") | .enabled == true' "$("$PM" list)"
out=$("$PM" disable test.alpha)
check "disable asks the shell to disable it" 'true' \
  "$([[ $(jq -r .ok <<<"$out") == true ]] && grep -qxF 'setPluginEnabled test.alpha false' "$SHELL_LOG" && echo '{}')"
out=$("$PM" enable test.beta)
check "enabling a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"

# ------------------------------------------------------------------- add
git init -q --bare -b main "$SANDBOX/delta.git"
write_plugin "$SANDBOX/delta-work" test.delta 2.0.0
git -C "$SANDBOX/delta-work" init -q -b main
commit_all "$SANDBOX/delta-work" "Initial"
git -C "$SANDBOX/delta-work" push -q "$SANDBOX/delta.git" main
out=$("$PM" add "$SANDBOX/delta.git")
check "add clones the plugin and reports its id" '.ok == true and .id == "test.delta"' "$out"
check "the added plugin is on disk" 'true' "$(test -f "$PLUGINS/test.delta/manifest.json" && echo '{}')"
check "the added plugin is a git plugin in the list" '[.plugins[].id] | index("test.delta") != null' "$("$PM" list)"
out=$("$PM" add "$SANDBOX/delta.git")
check "adding the same plugin twice is refused" '.ok == false and (.message | test("already"))' "$out"
out=$("$PM" add "")
check "add needs a URL" '.ok == false' "$out"

# ---------------------------------------------------------------- remove
out=$("$PM" remove test.delta)
check "remove succeeds" '.ok == true' "$out"
check "the removed git plugin is gone" 'true' "$([[ ! -e $PLUGINS/test.delta ]] && echo '{}')"
out=$("$PM" remove test.beta)
check "removing a plugin that is not git is refused" '.ok == false and (.message | test("not a git plugin"))' "$out"
check "it is still on disk" 'true' "$([[ -d $PLUGINS/test.beta ]] && echo '{}')"
out=$("$PM" remove test.link)
check "a symlink to a git working copy is not a git plugin" '.ok == false and (.message | test("not a git plugin"))' "$out"
check "the symlink is still there" 'true' "$([[ -L $PLUGINS/test.link ]] && echo '{}')"
out=$("$PM" remove "$SELF_ID")
check "removing the manager itself is refused" '.ok == false and (.message | test("itself"))' "$out"
check "the manager is still there" 'true' "$([[ -d $PLUGINS/$SELF_ID ]] && echo '{}')"
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
check "the default export file exists" 'true' "$([[ -f $(jq -r .path <<<"$out") ]] && echo '{}')"

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
check "a dry run clones nothing" 'true' "$([[ ! -e $PLUGINS/test.epsilon ]] && echo '{}')"

: >"$SHELL_LOG"
out=$("$PM" import "$SANDBOX/import.json")
check "an import with a failing URL reports the failure" \
  '.ok == false and (.message | startswith("Imported 2 of 3 plugins · 1 failed: test.eta: ")) and (.output | test("✗ test.eta"))' "$out"
check "imported plugins are on disk" 'true' "$([[ -d $PLUGINS/test.epsilon && -d $PLUGINS/test.zeta ]] && echo '{}')"
check "the bar widget is put back beside its neighbour" 'true' \
  "$(grep -qxF 'putBarWidget test.epsilon {"section":"left","before":"omarchy.menu"}' "$SHELL_LOG" && echo '{}')"
check "the bar widget gets its settings back" 'true' \
  "$(grep -qxF 'setBarWidget test.epsilon label "hi" {}' "$SHELL_LOG" && echo '{}')"
check "the overlay is enabled" 'true' "$(grep -qxF test.zeta "$SHELL_ENABLED" && echo '{}')"
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

# --------------------------------------------------------------- opening
# Shortcuts come from ~/.config/hypr/*.lua, checked against a stand-in hyprctl;
# menu entries from the user's extension over Omarchy's real defaults, whose
# "Setup" and "Plugins" labels give the path.
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy/extensions"
cat >"$HOME/.config/hypr/bindings.lua" <<'LUA'
-- o.bind("SUPER + SHIFT + Z", "Old alpha", "omarchy-shell shell toggle test.alpha '{}'")
o.bind("SUPER + SHIFT + A", "Alpha thing", "omarchy-shell shell toggle test.alpha '{}'")
o.bind("SUPER + K", "Kappa", "omarchy-shell shell toggle test.kappa '{}'")
o.bind("SUPER + B", "Browser", "omarchy-launch-browser")
LUA
cat >"$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" <<'JSONC'
{
  // A comment, and a string that only looks like one: "https://example.invalid"
  "setup.plugin.kappa": {"icon":"x","label":"Kappa","action":"kappa-open now"},
}
JSONC
cat >"$SANDBOX/bin/hyprctl" <<'STUB'
#!/bin/bash
[[ "$*" == "binds -j" ]] &&
  echo '[{"modmask": 65, "key": "A", "description": "Alpha thing", "dispatcher": "__lua", "arg": "1", "submap": ""}]'
STUB
chmod +x "$SANDBOX/bin/hyprctl"
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
  ".plugins[] | select(.id == \"test.alpha\") | .opens.shortcuts[0] | .file == \"$HOME/.config/hypr/bindings.lua\" and .line == 2" "$out"
check "a shortcut Hyprland does not have is found but not live" \
  '.plugins[] | select(.id == "test.kappa") | .opens.shortcuts | map({keys, active}) == [{keys: "SUPER + K", active: false}]' "$out"
check "a menu entry that runs a plugin's own script is found, with its path" \
  '.plugins[] | select(.id == "test.kappa") | .opens.menu == [{path: "Setup › Plugins › Kappa", action: "kappa-open now"}]' "$out"
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

# ------------------------------------------------------------------- run
export PLUGIN_MANAGER_NO_SUMMON=1
STATE="$XDG_CACHE_HOME/omarchy/plugin-manager"
out=$("$PM" run --label "Enabling broken" --id test.broken --kind toggle -- remove "$SELF_ID")
check "run passes the command's reply through" '.ok == false and (.message | test("itself"))' "$out"
out=$(cat "$STATE/last-action.json")
check "run records the reply with its label, id and kind" \
  '.label == "Enabling broken" and .id == "test.broken" and .kind == "toggle" and .result.ok == false and (.seq | length > 0)' "$out"
check "run clears its running marker when done" 'true' "$([[ ! -e $STATE/running.json ]] && echo '{}')"
seq1=$(jq -r .seq "$STATE/last-action.json")
"$PM" run --label "Removing broken" --id test.broken --kind remove -- remove test.broken >/dev/null
out=$(cat "$STATE/last-action.json")
check "a second run gets a new sequence number" ".seq != \"$seq1\" and .result.ok == true" "$out"
check "a run really does the work" 'true' "$([[ ! -e $PLUGINS/test.broken ]] && echo '{}')"
out=$("$PM" run --label x -- bogus)
check "a failing command still leaves a reply" '.ok == false' "$out"

out=$("$PM" bogus)
check "an unknown command fails as JSON" '.ok == false' "$out"

echo "$passed passed, $failed failed"
((failed == 0))
