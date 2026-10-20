# nu-abbr

Fish-like abbreviations for Nushell.

Type `gs` and press Space, and the line becomes `git status --short`. Unlike
an alias, the full command is what you see, edit and find in your history.

Nushell already ships the expansion itself: Reedline expands the entries of
`$env.config.abbreviations` on Space and Enter. nu-abbr is a small manager on
top of that:

- `nu-abbr add` / `nu-abbr erase` / `nu-abbr list`, usable before or after enabling
- abbreviations whose expansion is computed by a closure (zsh-abbrev-alias's
  `-e`), such as `~~` for the path to the git repository root
- `nu-abbr enable` / `nu-abbr disable`, which only touch the entries nu-abbr wrote
  and put back your own entries it replaced

It installs no keybindings, so it works with any Space or Enter binding,
including [nu-autocomplete](https://github.com/yutkat/nu-autocomplete).

## Requirements

- Nushell 0.116 or newer (tested with 0.116.1)

## Install

Clone the repository:

```sh
git clone https://github.com/yutkat/nu-abbr.git /path/to/nu-abbr
```

then add to your `config.nu`:

```nu
use /path/to/nu-abbr/nu-abbr

nu-abbr add gs "git status --short"
nu-abbr add G "| grep"
nu-abbr enable
```

Or install it with [nupm](https://github.com/nushell/nupm) from the clone
(`$env.NUPM_HOME/modules` must be in `$env.NU_LIB_DIRS`):

```nu
nupm install /path/to/nu-abbr --path
```

and add to your `config.nu`:

```nu
use nu-abbr

nu-abbr add gs "git status --short"
nu-abbr add G "| grep"
nu-abbr enable
```

`use` alone changes nothing. To try it without your own configuration:

```sh
XDG_CONFIG_HOME=$(mktemp -d) nu --config examples/minimal-config.nu
```

## Usage

```nu
nu-abbr add gc "git commit"        # add, or replace an abbreviation with the same name
nu-abbr add "~~" {|| ... }         # expansion computed by a closure before every prompt
nu-abbr erase gc gd                # remove abbreviations
nu-abbr list                       # name, expansion, eval (closure?), value (what it expands to now)
nu-abbr enable                     # write the abbreviations and install the pre_prompt hook
nu-abbr disable                    # remove what enable added; the abbreviations stay defined
nu-abbr status                     # enabled, counts, replaced entries, hook
```

Running `enable` again replaces the previous installation without duplicates.
`nu-abbr add` and `nu-abbr erase` take effect immediately while enabled.

## Where a word expands

Reedline replaces the word before the cursor (text up to the previous
whitespace) when you type Space, or press Enter at the end of the word, if
the word is an abbreviation. Nushell then suppresses the expansion when that
word is inside a string or is an argument of an external command:

| Typed                   | Result                                |
| ----------------------- | ------------------------------------- |
| `gs␣`                   | `git status --short ␣`                |
| `ls \| gs␣`, `foo; gs␣` | expanded                              |
| `ls G␣`                 | `ls \| grep ␣`                        |
| `cd ~~␣`                | `cd ../../␣` (inside `a/b` of a repo) |
| `echo "gs␣`, `echo gs␣` | not expanded (string)                 |
| `^git log G␣`           | not expanded (external command arg)   |
| `^gs␣`                  | not expanded; runs the real `gs`      |

Ctrl+Z right after an expansion undoes it.

There is therefore no separate "command position" and "global" kind as in
zsh-abbrev-alias or fish: every abbreviation follows the rule above. A
command abbreviation also expands as a path or glob argument of a Nushell
command (`cd gs␣`), and a "global" one such as `G` does not expand after the
arguments of an external command; type `| grep` there instead.

Enter always expands a word under these rules (Reedline has no switch for
it). Unlike zsh-abbrev-alias, nothing defines an alias behind the
abbreviation, so an unexpanded `gs` would run the `gs` program instead.

## Closures

```nu
# "../../" inside a subdirectory, "." at the root, no expansion outside a repository
nu-abbr add "~~" {|| let p = (git rev-parse --show-cdup); if $p == "" { "." } else { $p } }
```

The closure runs on enable, on add and before every prompt (the working
directory cannot change while you edit a line), so keep it fast. Its stderr
is discarded and trailing newlines are dropped, like `$(...)` in a shell.
When it fails or returns null, the word does not expand.

The hook is a `pre_prompt` entry named `nu_abbr_sync`. `enable` and `disable`
only add or remove that entry; your other hooks, including ones from other
modules, stay in place and in order.

## Migrating from zsh-abbrev-alias

| zsh-abbrev-alias                                       | nu-abbr                                                            |
| ------------------------------------------------------ | ------------------------------------------------------------------ |
| `abbrev-alias gc='git commit'`                         | `nu-abbr add gc "git commit"`                                      |
| `abbrev-alias pr='gh pr view -w \|\| gh pr create -w'` | `nu-abbr add pr "try { gh pr view -w } catch { gh pr create -w }"` |
| `abbrev-alias -g G="\| grep"`                          | `nu-abbr add G "\| grep"` (see [above](#where-a-word-expands))     |
| `abbrev-alias -eg ~~='$(git rev-parse --show-cdup)'`   | `nu-abbr add "~~" {\|\| ... }` (see [Closures](#closures))         |
| `abbrev-alias -u gc`                                   | `nu-abbr erase gc`                                                 |
| `^x Space` (insert a space without expanding)          | prefix the command with `^`, or Ctrl+Z after the expansion         |

Recursive expansion (`-r`) is not supported.

## With nu-autocomplete

Nothing to configure, and the load order does not matter. Reedline expands
the abbreviation as part of the Space that nu-autocomplete binds, and
nu-autocomplete then opens the completion menu for the expanded line
(`gs␣` shows file candidates for `git status --short`). nu-abbr binds no
keys, so nu-autocomplete reports no skipped trigger keys.

Why nu-abbr does not bind Space itself (tested on Nushell 0.116.1):

- Expanding through an `executehostcommand` keybinding ends Reedline's line
  editing for the host command. The events after it in the same binding never
  run, and a menu opened before it is gone afterwards, so the completion menu
  cannot open after an expansion. Every Space would also run your
  `pre_execution`/`pre_prompt` hooks and redraw the prompt.
- nu-autocomplete leaves trigger keys you already bound alone, so a Space
  binding would also stop Space from opening the menu at all.
- A menu-based expansion (open a menu whose source returns the expansion,
  then `menuaccept`) gets no values within the same key press once
  nu-autocomplete turns `completions.quick` and `completions.partial` off.

## Known issues

- Nushell only ever adds `$env.config.abbreviations` entries to the running
  line editor, so a deleted entry keeps expanding until Nushell restarts. In
  an interactive session, `nu-abbr erase` and `nu-abbr disable` therefore first map
  the name to itself and delete the entry at the second prompt after the
  command. An entry you delete from `$env.config.abbreviations` yourself also
  keeps expanding; set it to its own name instead.
- An entry in `$env.config.abbreviations` that you change after nu-abbr wrote
  it is left alone (and kept by `nu-abbr disable`); `nu-abbr list` shows its value
  as null.

## Development

```sh
nu tests/run.nu
```
