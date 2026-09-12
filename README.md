# Plugin Manager

One place to look after the Omarchy shell plugins you installed from git:
list them, read their details, see how each one is opened and open it, see
which have updates waiting, update, enable, disable, remove, add new ones from
a git URL, and carry the whole set to another Omarchy install with an export
file.

- **Plugin ID:** `io.github.kimm-stensborg.plugin-manager`
- **Kind:** `overlay`
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

`install.sh` enables the plugin and gives you two ways to open it:

- a **shortcut**. It proposes the first free one of `SUPER + ALT + P`,
  `SUPER + CTRL + SHIFT + P`, `SUPER + SHIFT + U` and `SUPER + ALT + U`, and
  you can edit the proposal before accepting it. It lands in
  `~/.config/hypr/bindings.lua`.
- a **menu entry**, *Setup › Plugins › Manage Plugins*, in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`.

```bash
install.sh --key "SUPER + ALT + P"   # skip the prompt
install.sh --no-bind                 # menu entry only
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
| `⏎` | open the selected plugin |
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
- **how it opens**: its shortcuts, its entries in the Omarchy menu, and its
  place in the bar

Problems are called out: a manifest the validator rejects, local changes that
would stop an update from fast-forwarding, and a checkout that has diverged
from upstream.

## Opening a plugin

A shortcut or menu entry belongs to a plugin when its command names the
plugin's id, or runs a script from the plugin's own `bin/` folder.

- **Shortcuts** are read from the `o.bind("KEYS", "Description", "command")`
  lines in `~/.config/hypr/*.lua`. Hyprland cannot say what a binding runs
  with a Lua config, so each one is checked against Hyprland's live bindings
  by keys and description. A shortcut that has been unbound or taken over is
  marked as not active.
- **Menu entries** come from the Omarchy menu: the defaults, with your
  `omarchy-menu.jsonc` on top. Each is shown as its path, for example
  *Setup › Plugins › Manage Plugins*.

Two kinds of shortcut are not found: one that runs a script of your own which
then opens the plugin, and one built by Lua code instead of written as a plain
`o.bind` line.

`⏎`, or the **Open** button, closes the manager and opens the plugin with the
command its own shortcut or menu entry runs. When it has neither, Open uses a
plain `omarchy-shell shell toggle <id> '{}'`. A plugin that only runs in the
background has nothing to open, and a disabled one has to be enabled first.

## Updates

A check does the same fetch as `omarchy plugin update`, so "3 new commits"
means exactly what an update would bring in. The commits are listed, along
with the version the upstream manifest declares.

The results are cached in `~/.cache/omarchy/plugin-manager/updates.json`.
Opening the manager redoes a check that is more than six hours old, and `C`
checks again at any time.

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

The manager is gone for a second or two while the shell rebuilds its panels;
no plugin can stay on screen through that.

Checks, exports and import previews do not rescan, so they run directly.

## Remove

```bash
~/.config/omarchy/plugins/io.github.kimm-stensborg.plugin-manager/install.sh --uninstall
omarchy plugin remove io.github.kimm-stensborg.plugin-manager
rm -rf ~/.cache/omarchy/plugin-manager
```

## Developing

Work in a clone of the repository and bring commits into the installed copy
without going through GitHub:

```bash
git -C ~/.config/omarchy/plugins/io.github.kimm-stensborg.plugin-manager pull ~/Projects/omarchy-plugin-manager main
omarchy restart shell
```

Do not edit the installed copy itself: `omarchy plugin update` refuses to
fast-forward over local changes.

A rescan does not pick up changed QML: the shell keeps the compiled component
cached for as long as the old instance is alive, so after changing
`Manager.qml` run `omarchy restart shell`. Errors land in
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
