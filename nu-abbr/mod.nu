# nu-abbr: fish-like abbreviations for Nushell.
#
# Expansion itself is done by Reedline's native abbreviations
# (`$env.config.abbreviations`), which expand the word before the cursor on
# Space and Enter. nu-abbr manages entries in that record, adds abbreviations
# whose expansion is computed by a closure, and can remove everything it added.
#
# `use nu-abbr` only defines commands; nothing changes until `nu-abbr enable`.

# Name of the pre_prompt hook entry nu-abbr owns.
const HOOK_NAME = "nu_abbr_sync"

def state []: nothing -> record {
    $env.__NU_ABBR? | default {enabled: false, abbrs: [], written: {}, saved: {}, pending: {}}
}

# Cell path for a record key, so names like `a.b` or `0` are taken literally.
def key [name: string]: nothing -> cell-path {
    [$name] | into cell-path
}

def is-ours []: any -> bool {
    let hook = $in
    ($hook | describe | str starts-with "record") and ($hook.name? == $HOOK_NAME)
}

def hook []: nothing -> record {
    {name: $HOOK_NAME, code: {|| sweep; sync; retire }}
}

def null-device []: nothing -> string {
    if $nu.os-info.name == windows { "NUL" } else { "/dev/null" }
}

# The text an abbreviation expands to now. A closure that fails or returns
# null gives the name itself, which Reedline "expands" to the same word.
# Like `$(...)` in a shell, trailing newlines are dropped and stderr is
# discarded (the closure runs before every prompt).
def evaluate [name: string, expansion: any]: nothing -> string {
    if ($expansion | describe) != closure {
        return $expansion
    }
    let result = try { do $expansion e> (null-device) } catch { null }
    if $result == null {
        return $name
    }
    try { $result | into string | str replace --regex '\n+$' '' } catch { $name }
}

# Remove a name nu-abbr wrote from `$env.config.abbreviations`, restoring the
# user's entry it replaced. An entry changed after nu-abbr wrote it is kept.
#
# Nushell only ever adds `$env.config.abbreviations` entries to the running
# line editor, so a deleted entry would keep expanding until Nushell restarts.
# In an interactive session the entry is therefore first set to the name
# itself, and `sweep` deletes it once the line editor has picked that up.
def --env forget [name: string]: nothing -> nothing {
    let st = state
    let k = key $name
    let mine = $st.written | get --optional $k
    let saved = $st.saved | get --optional $k
    mut pending = $st.pending
    if $mine != null and ($env.config.abbreviations | get --optional $k) == $mine {
        $env.config.abbreviations = if $saved != null {
            $env.config.abbreviations | upsert $k $saved
        } else if $nu.is-interactive {
            $pending = $pending | upsert $k false
            $env.config.abbreviations | upsert $k $name
        } else {
            $env.config.abbreviations | reject $k
        }
    }
    let written = if $mine == null { $st.written } else { $st.written | reject $k }
    let saved = if $saved == null { $st.saved } else { $st.saved | reject $k }
    $env.__NU_ABBR = $st | upsert written $written | upsert saved $saved | upsert pending $pending
}

# Delete the placeholder entries `forget` left, one prompt after the line
# editor has seen them. Placeholders changed by something else are dropped
# from the list and left alone.
def --env sweep []: nothing -> nothing {
    let st = state
    mut native = $env.config.abbreviations
    mut pending = {}
    for p in ($st.pending | transpose name seen) {
        let k = key $p.name
        if ($native | get --optional $k) != $p.name {
            continue
        }
        if $p.seen {
            $native = $native | reject $k
        } else {
            $pending = $pending | upsert $k true
        }
    }
    if $native != $env.config.abbreviations {
        $env.config.abbreviations = $native
    }
    $env.__NU_ABBR = $st | upsert pending $pending
}

# Write every abbreviation into `$env.config.abbreviations` while enabled.
#
# Runs on enable, on add, and before every prompt, so closures follow the
# current directory and entries come back after the record is reassigned.
# An entry the user changed after nu-abbr wrote it is left alone.
def --env sync []: nothing -> nothing {
    let st = state
    if not $st.enabled {
        return
    }
    mut native = $env.config.abbreviations
    mut written = $st.written
    mut saved = $st.saved
    mut pending = $st.pending
    for a in $st.abbrs {
        let k = key $a.name
        let current = $native | get --optional $k
        let mine = $written | get --optional $k
        let placeholder = ($pending | get --optional $k) != null and $current == $a.name
        if $current != null and $current != $mine and not $placeholder {
            if $mine != null {
                # Changed by the user after nu-abbr wrote it.
                continue
            }
            # The user's own entry for this name: replace it, restore it later.
            $saved = $saved | upsert $k $current
        }
        if ($pending | get --optional $k) != null {
            $pending = $pending | reject $k
        }
        let value = evaluate $a.name $a.expansion
        $native = $native | upsert $k $value
        $written = $written | upsert $k $value
    }
    if $native != $env.config.abbreviations {
        $env.config.abbreviations = $native
    }
    $env.__NU_ABBR = $st | upsert written $written | upsert saved $saved | upsert pending $pending
}

# Remove the hook once nu-abbr is disabled and no placeholder is left.
def --env retire []: nothing -> nothing {
    let st = state
    if not $st.enabled and ($st.pending | is-empty) {
        remove-hook
    }
}

def --env remove-hook []: nothing -> nothing {
    let hooks = $env.config.hooks.pre_prompt? | default []
    if ($hooks | any {|h| $h | is-ours }) {
        $env.config.hooks.pre_prompt = $hooks | where {|h| not ($h | is-ours) }
    }
}

def validate-name [name: string]: nothing -> nothing {
    if $name == "" or $name =~ '\s' {
        error make {msg: $"invalid abbreviation name '($name)': it must be non-empty and contain no whitespace"}
    }
}

# Add an abbreviation, or replace the one with the same name.
#
# The word expands when it is followed by Space or Enter, unless it is inside
# a string or an argument of an external command (Reedline's rule). With a
# closure, the expansion is its output, recomputed before every prompt; when
# the closure fails or returns null, the word does not expand.
@example "Expand `gs` to `git status --short`" {nu-abbr add gs "git status --short"}
@example "Expand `~~` to the relative path of the git repository root" {nu-abbr add "~~" {|| let p = (git rev-parse --show-cdup); if $p == "" { "." } else { $p } }}
export def --env add [
    name: string                           # Word to expand (no whitespace)
    expansion: oneof<string, closure>      # Replacement text, or a closure that returns it
]: nothing -> nothing {
    validate-name $name
    let st = state
    let entry = {name: $name, expansion: $expansion}
    let abbrs = if ($st.abbrs | any {|a| $a.name == $name }) {
        $st.abbrs | each {|a| if $a.name == $name { $entry } else { $a } }
    } else {
        $st.abbrs | append $entry
    }
    $env.__NU_ABBR = $st | upsert abbrs $abbrs
    sync
}

# Remove abbreviations added with `nu-abbr add`.
#
# Fails without changing anything when a name is unknown.
export def --env erase [
    ...names: string # Names to remove
]: nothing -> nothing {
    let known = state | get abbrs | each { $in.name }
    let unknown = $names | where $it not-in $known
    if ($unknown | is-not-empty) {
        error make {msg: $"no such abbreviation: ($unknown | str join ', ')"}
    }
    for name in $names {
        forget $name
    }
    let st = state
    $env.__NU_ABBR = $st | upsert abbrs ($st.abbrs | where name not-in $names)
}

# List the abbreviations added with `nu-abbr add`.
#
# `value` is what the word expands to right now: null while nu-abbr is
# disabled, when the closure failed or returned null, or when the entry in
# `$env.config.abbreviations` was changed by something else.
export def list []: nothing -> table<name: string, expansion: string, eval: bool, value: any> {
    let st = state
    $st.abbrs | each {|a|
        let k = key $a.name
        let mine = $st.written | get --optional $k
        let current = $env.config.abbreviations | get --optional $k
        let eval = ($a.expansion | describe) == closure
        {
            name: $a.name
            expansion: (if $eval { view source $a.expansion } else { $a.expansion })
            eval: $eval
            value: (if $st.enabled and $mine != null and $current == $mine and $current != $a.name { $current } else { null })
        }
    }
}

# Enable the abbreviations for the current session.
#
# Writes them into `$env.config.abbreviations` and installs a pre_prompt hook
# that keeps them there and recomputes closure expansions. Running it again
# replaces the previous installation instead of adding duplicates.
export def --env enable []: nothing -> nothing {
    if "abbreviations" not-in ($env.config | columns) {
        error make {msg: "this Nushell has no $env.config.abbreviations; nu-abbr needs Nushell 0.116 or newer"}
    }
    if (state).enabled { disable }

    let others = $env.config.hooks.pre_prompt? | default [] | where {|h| not ($h | is-ours) }
    $env.config.hooks.pre_prompt = $others | append (hook)
    $env.__NU_ABBR = state | upsert enabled true
    sync
}

# Disable the abbreviations and remove what enable added.
#
# Removes every entry nu-abbr wrote to `$env.config.abbreviations`, restoring
# entries of yours it replaced, and then the hook. Entries changed after
# nu-abbr wrote them are kept. The abbreviations stay defined for the next
# `nu-abbr enable`.
#
# In an interactive session the removal finishes at the second prompt after
# this: until then each entry maps the name to itself, because the line
# editor would keep expanding a deleted entry until Nushell restarts.
export def --env disable []: nothing -> nothing {
    if (state).enabled {
        for name in (state | get written | columns) {
            forget $name
        }
        $env.__NU_ABBR = state | upsert enabled false | upsert written {} | upsert saved {}
    }
    retire
}

# Show whether nu-abbr is enabled and what it installed.
export def status []: nothing -> record {
    let st = state
    let list = list
    {
        enabled: $st.enabled
        abbreviations: ($list | length)
        active: ($list | where value != null | length)
        replaced: ($st.saved | columns)
        pending_removal: ($st.pending | columns)
        hook: ($env.config.hooks.pre_prompt? | default [] | any {|h| $h | is-ours })
    }
}
