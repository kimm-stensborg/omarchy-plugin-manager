# Plugin Manager

One place to see and look after the Omarchy shell plugins you have installed:
list them, read their details, see which have updates waiting, update, enable,
disable, remove, and add new ones from a git URL.

- **Plugin ID:** `io.github.kimm-stensborg.plugin-manager`
- **Kinds:** `overlay`, `bar-widget`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`; `git`, `jq`

It manages what lives in `~/.config/omarchy/plugins/` — third-party plugins and
your clones of built-ins. The built-in `omarchy.*` plugins are left out, since
they can be neither updated nor removed, and so is the manager itself.

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-plugin-manager.git
~/.config/omarchy/plugins/io.github.kimm-stensborg.plugin-manager/install.sh
```

`install.sh` gives you three ways in:

- a **shortcut**. It proposes the first free one of `SUPER + ALT + P`,
  `SUPER + CTRL + SHIFT + P`, `SUPER + SHIFT + U` and `SUPER + ALT + U`, and
  you can edit the proposal before accepting it. It lands in
  `~/.config/hypr/bindings.lua`.
- a **menu entry**, *Setup › Plugins › Manage Plugins*, in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
- the **bar button**. Enabling the plugin puts it in the right section. It
  shows a badge with the number of plugins that have an update.

```bash
install.sh --key "SUPER + ALT + P"   # skip the prompt
install.sh --no-bind                 # menu entry and bar button only
install.sh --uninstall               # take the shortcut and menu entry out
```

Or open it directly:

```bash
omarchy-shell shell toggle io.github.kimm-stensborg.plugin-manager '{}'
```

## Keys

| Key | Does |
|-----|------|
| `↑` `↓` / `j` `k`, `Home` `End` | select a plugin |
| `c` | check the selected plugin for an update |
| `C` | check every plugin |
| `u` | update the selected plugin |
| `e` | enable or disable it |
| `d` / `Del` | remove it (asks first) |
| `a` / `/` | type a git URL to add; `⏎` adds, `Esc` leaves the field |
| `o` | open its repository in the browser |
| `r` | reload the list |
| `Esc` | close |

## What it shows

For every plugin: name, version, description, author, license, kinds, whether
it is enabled, and where it came from.

- **git**: the remote, branch, commit and last commit. This is what
  `omarchy plugin add` produces.
- **local**: dropped in by hand.
- **clone**: made with `omarchy plugin clone`.
- **symlink**: a link to a working copy elsewhere, handy while developing.

Problems are called out: a manifest the validator rejects, local changes that
would stop an update from fast-forwarding, and a checkout that has diverged
from upstream.

## Updates

A check does the same fetch as `omarchy plugin update`, so "3 new commits"
means exactly what an update would bring in. The commits are listed, along
with the version the upstream manifest declares. Only git checkouts can be
checked, since nothing else has an upstream.

The results are cached in `~/.cache/omarchy/plugin-manager/updates.json`. The
bar button checks at startup and every six hours after that, and opening the
manager redoes a check older than that. A lock keeps the bar on each monitor
from fetching at the same time.

## Adding

Paste a git URL and press `⏎`. The plugin is cloned and validated by
`omarchy plugin add`, and it lands **disabled**. Plugins run unsandboxed
inside `omarchy-shell`, so read the code before you switch it on with `e`.

## How it works

| Path | What |
|------|------|
| `Manager.qml` | the overlay: list, details, actions |
| `BarWidget.qml` | the bar button and its update badge |
| `bin/plugin-manager` | the backend; the only code that touches the system |
| `install.sh` | shortcut, menu entry, enable |
| `test.sh` | backend tests |

The backend prints one JSON document per command (`list`, `check`, `update`,
`remove`, `add`, `enable`, `disable`). The actions wrap the stock
`omarchy-plugin-*` commands, so cloning, validation, rollback and rescans work
exactly as they do from the terminal.

Those commands finish by rescanning the shell, and a rescan unloads every open
panel, this one included. So the overlay does not wait on them. It starts
`plugin-manager run …` detached, and that job:

1. writes `running.json` while it works,
2. writes the reply to `last-action.json`,
3. summons the manager back, which shows the result.

## Remove

```bash
~/.config/omarchy/plugins/io.github.kimm-stensborg.plugin-manager/install.sh --uninstall
omarchy plugin remove io.github.kimm-stensborg.plugin-manager
rm -rf ~/.cache/omarchy/plugin-manager
```

## Developing

Symlink a working copy in place of the installed plugin:

```bash
ln -sfn ~/Projects/omarchy-plugin-manager ~/.config/omarchy/plugins/io.github.kimm-stensborg.plugin-manager
omarchy-shell shell rescanPlugins
```

A rescan does not pick up changed QML: the shell keeps the compiled component
cached for as long as the old instance is alive. After changing
`Manager.qml` or `BarWidget.qml`, run `omarchy restart shell`. The backend is
re-read on every call, so changes there need nothing. Errors land in
`/run/user/$UID/quickshell/by-id/*/log.log`. To drive the overlay without
touching the keyboard, `omarchy-shell shell call <id> <function> x` calls any
of its functions, for example `toggleEnabled` or `checkAll`.

## Tests

```bash
./test.sh
```

The tests run the backend against a throwaway `$HOME`, using fake plugins and
local bare repositories as their upstreams. No real plugin is touched.

## Roadmap

- Export your plugins (URLs, commits, enabled state and bar placement) to a
  file, and import it on another Omarchy install.
