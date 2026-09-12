#!/bin/bash

# Backend tests. Everything runs against a throwaway $HOME holding fake plugins
# and local bare "upstreams", so no real plugin is fetched, updated or removed.
# The stock omarchy-plugin-* commands still ask the running shell to rescan,
# which only re-reads the real plugin directory and changes nothing.
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

# test.alpha: git-managed, with an upstream that moves two commits ahead.
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

# test.beta: dropped in by hand. test.gamma: a clone of a built-in.
write_plugin "$PLUGINS/test.beta" test.beta 0.1.0
write_plugin "$PLUGINS/test.gamma" test.gamma 1.0.0 '{"omarchy": {"clonedFrom": "omarchy.clock"}}'
# test.broken: names an entry point that does not exist.
write_plugin "$PLUGINS/test.broken" test.broken 1.0.0
rm "$PLUGINS/test.broken/Overlay.qml"
# The manager itself, which must never show up or be acted on.
write_plugin "$PLUGINS/$SELF_ID" "$SELF_ID" 0.1.0
# A remove backup, which is not a plugin.
write_plugin "$PLUGINS/.test.old.bak.20260101000000" test.old 1.0.0

# ------------------------------------------------------------------ list
out=$("$PM" list)
check "list succeeds" '.ok == true' "$out"
check "list shows the four user plugins, sorted" \
  '[.plugins[].id] == ["test.alpha", "test.beta", "test.broken", "test.gamma"]' "$out"
check "list never shows the manager itself" "all(.plugins[]; .id != \"$SELF_ID\")" "$out"
check "git plugin is sourced from git with its remote" \
  ".plugins[] | select(.id == \"test.alpha\") | .source == \"git\" and .git.remote == \"$SANDBOX/alpha.git\" and .git.branch == \"main\" and .git.subject == \"Initial\" and .git.dirty == false" "$out"
check "hand-dropped plugin is local, without git" \
  '.plugins[] | select(.id == "test.beta") | .source == "local" and .git == null' "$out"
check "a clone says what it was cloned from" \
  '.plugins[] | select(.id == "test.gamma") | .source == "clone" and .clonedFrom == "omarchy.clock"' "$out"
check "manifest fields come through" \
  '.plugins[] | select(.id == "test.beta") | .name == "test.beta name" and .version == "0.1.0" and .author == "Tester" and .license == "MIT" and .kinds == ["overlay"]' "$out"
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
check "a plugin without git is not checkable" '.plugins["test.beta"].checkable == false' "$out"
check "check skips the manager itself" ".plugins | has(\"$SELF_ID\") | not" "$out"
out=$("$PM" list)
check "list carries the cached update status" \
  '.plugins[] | select(.id == "test.alpha") | .update.behind == 2' "$out"

out=$("$PM" check --if-stale 3600)
check "a fresh cache is returned without fetching" '.plugins["test.alpha"].behind == 2' "$out"

out=$("$PM" check "$SELF_ID")
check "checking the manager itself is refused" '.ok == false' "$out"

# ---------------------------------------------------------------- update
out=$("$PM" update test.beta)
check "updating a plugin without git is refused" '.ok == false and (.message | test("not a git checkout"))' "$out"
out=$("$PM" update test.alpha)
check "update succeeds" '.ok == true and .id == "test.alpha"' "$out"
out=$("$PM" list)
check "after update alpha is at 1.1.0 and no longer behind" \
  '.plugins[] | select(.id == "test.alpha") | .version == "1.1.0" and .update.behind == 0' "$out"

echo "// local edit" >>"$PLUGINS/test.alpha/Overlay.qml"
out=$("$PM" list)
check "a local edit shows as dirty" '.plugins[] | select(.id == "test.alpha") | .git.dirty == true' "$out"
git -C "$PLUGINS/test.alpha" checkout -q -- Overlay.qml

# ------------------------------------------------------------------- add
git init -q --bare -b main "$SANDBOX/delta.git"
write_plugin "$SANDBOX/delta-work" test.delta 2.0.0
git -C "$SANDBOX/delta-work" init -q -b main
commit_all "$SANDBOX/delta-work" "Initial"
git -C "$SANDBOX/delta-work" push -q "$SANDBOX/delta.git" main
out=$("$PM" add "$SANDBOX/delta.git")
check "add clones the plugin and reports its id" '.ok == true and .id == "test.delta"' "$out"
check "the added plugin is on disk" 'true' "$(test -f "$PLUGINS/test.delta/manifest.json" && echo '{}')"
out=$("$PM" add "$SANDBOX/delta.git")
check "adding the same plugin twice is refused" '.ok == false and (.message | test("already"))' "$out"
out=$("$PM" add "")
check "add needs a URL" '.ok == false' "$out"

# ---------------------------------------------------------------- remove
out=$("$PM" remove test.delta)
check "remove succeeds" '.ok == true' "$out"
check "the removed git plugin is gone" 'true' "$([[ ! -e $PLUGINS/test.delta ]] && echo '{}')"
out=$("$PM" remove test.beta)
check "a non-git plugin is removed to a backup" '.ok == true and (.output | test("Backup at"))' "$out"
out=$("$PM" remove "$SELF_ID")
check "removing the manager itself is refused" '.ok == false and (.message | test("itself"))' "$out"
check "the manager is still there" 'true' "$([[ -d $PLUGINS/$SELF_ID ]] && echo '{}')"
out=$("$PM" remove ../../etc)
check "a path is not an id" '.ok == false and (.message | test("invalid"))' "$out"
out=$("$PM" remove test.nope)
check "removing a missing plugin is refused" '.ok == false and (.message | test("not installed"))' "$out"

out=$("$PM" check)
check "a full check drops removed plugins from the cache" \
  '(.plugins | has("test.delta") or has("test.beta")) | not' "$out"

# ------------------------------------------------------------------- run
export PLUGIN_MANAGER_NO_SUMMON=1
STATE="$XDG_CACHE_HOME/omarchy/plugin-manager"
out=$("$PM" run --label "Enabling gamma" --id test.gamma --kind toggle -- remove "$SELF_ID")
check "run passes the command's reply through" '.ok == false and (.message | test("itself"))' "$out"
out=$(cat "$STATE/last-action.json")
check "run records the reply with its label, id and kind" \
  '.label == "Enabling gamma" and .id == "test.gamma" and .kind == "toggle" and .result.ok == false and (.seq | length > 0)' "$out"
check "run clears its running marker when done" 'true' "$([[ ! -e $STATE/running.json ]] && echo '{}')"
seq1=$(jq -r .seq "$STATE/last-action.json")
"$PM" run --label "Removing gamma" --id test.gamma --kind remove -- remove test.gamma >/dev/null
out=$(cat "$STATE/last-action.json")
check "a second run gets a new sequence number" ".seq != \"$seq1\" and .result.ok == true" "$out"
check "a run really does the work" 'true' "$([[ ! -e $PLUGINS/test.gamma ]] && echo '{}')"
out=$("$PM" run --label x -- bogus)
check "a failing command still leaves a reply" '.ok == false' "$out"

out=$("$PM" bogus)
check "an unknown command fails as JSON" '.ok == false' "$out"

echo "$passed passed, $failed failed"
((failed == 0))
