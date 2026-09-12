# Plugin Manager

One place to look after the Omarchy shell plugins you installed from git:
list them, read their details, see which have updates waiting, update, enable,
disable, remove, add new ones from a git URL, and carry the whole set to
another Omarchy install with an export file.

- **Plugin ID:** `io.github.kimm-stensborg.plugin-manager`
- **Kinds:** `overlay`, `bar-widget`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`; `git`, `jq`

It manages **git plugins only**: the checkouts `omarchy plugin add` makes in
`~/.config/omarchy/plugins/`. Everything else is left alone, and so is the
manager itself:

- the built-in `omarchy.*` plugins
- clones of built-ins
- folders dropped in by hand
- symlinks to working copies

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
| `a` / `/` | type a git URL to add, or an export file to import; `⏎` goes, `Esc` leaves the field |
| `x` | export your plugins to a file |
| `o` | open its repository in the browser |
| `r` | reload the list |
| `Esc` | close |

## What it shows

For every plugin:

- name, version, description, author, license and kinds
- whether it is enabled
- its remote, branch, commit and last commit

Problems are called out: a manifest the validator rejects, local changes that
would stop an update from fast-forwarding, and a checkout that has diverged
from upstream.

## Updates

A check does the same fetch as `omarchy plugin update`, so "3 new commits"
means exactly what an update would bring in. The commits are listed, along
with the version the upstream manifest declares.

The results are cached in `~/.cache/omarchy/plugin-manager/updates.json`. The
bar button checks at startup and every six hours after that, and opening the
manager redoes a check older than that. A lock keeps the bar on each monitor
from fetching at the same time.

## Adding

Paste a git URL and press `⏎`. The plugin is cloned and validated by
`omarchy plugin add`, and it lands **disabled**. Plugins run unsandboxed
inside `omarchy-shell`, so read the code before you switch it on with `e`.

## Export and import

`x` writes every plugin to `~/omarchy-plugins-<host>-<date>.json`. Copy that
file to the other machine, install the Plugin Manager there, type the file's
path into the add field and press `⏎`. A preview lists what will be installed
and what is skipped, and nothing happens until you confirm it.

For each plugin the file records:

- its git URL and the commit it was at
- whether it was enabled
- where it sat: its section in the bar and its neighbours, or whether it was
  the bar itself
- its inline settings from `shell.json`

The import clones the **latest** version of each plugin. Plugins that were
enabled are switched on again in the same section, next to the same widget
when the other bar has it, and with the same settings.

A plugin whose remote another machine cannot fetch from is not included, and
the preview says why: one with no remote, or one whose remote is a path on
this disk. Plugins that are already installed are left as they are.

From a terminal:

```bash
bin/plugin-manager export [file]
bin/plugin-manager import <file> --dry-run   # what it would do
bin/plugin-manager import <file>
```

## How it works

| Path | What |
|------|------|
| `Manager.qml` | the overlay: list, details, actions |
| `BarWidget.qml` | the bar button and its update badge |
| `bin/plugin-manager` | the backend; the only code that touches the system |
| `install.sh` | shortcut, menu entry, enable |
| `test.sh` | backend tests |

The backend prints one JSON document per command (`list`, `check`, `update`,
`remove`, `add`, `enable`, `disable`, `export`, `import`). The actions wrap
the stock `omarchy-plugin-*` commands, so cloning, validation, rollback and
rescans work exactly as they do from the terminal.

Those commands finish by rescanning the shell, and a rescan unloads every open
panel, this one included. So the overlay does not wait on them. It starts
`plugin-manager run …` detached, and that job:

1. writes `running.json` while it works,
2. writes the reply to `last-action.json`,
3. summons the manager back, which shows the result.

Checks, exports and import previews do not rescan, so they run directly.

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
local bare repositories as their upstreams. A stand-in `omarchy-shell` first on
`PATH` answers in place of the running shell, so no test touches your real
plugins or `shell.json`.
