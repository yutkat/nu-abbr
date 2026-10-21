# Test entry point: `nu tests/run.nu`. Exits non-zero when a test fails.
#
# These tests exercise nu-abbr on `$env.config` in-process, and run the
# pre_prompt hook by hand. The expansion itself is done by Reedline while
# editing a line, which needs an interactive session.

use std/assert

const ROOT = path self ..
use ($ROOT | path join nu-abbr)

const HOOK_NAME = "nu_abbr_sync"

def ours []: list -> list { where {|h| ($h | describe | str starts-with "record") and $h.name? == $HOOK_NAME } }

# The entry for a name in `$env.config.abbreviations`, or null.
def native [name: string]: nothing -> any {
    $env.config.abbreviations | get --optional ([$name] | into cell-path)
}

# Run nu-abbr's pre_prompt hook as Nushell would before a prompt.
def --env run-hook [] {
    let hook = $env.config.hooks.pre_prompt | ours
    assert equal ($hook | length) 1 "exactly one nu-abbr hook"
    do --env $hook.0.code
}

def --env with-temp-dir [body: closure] {
    let dir = mktemp --directory
    let cwd = pwd
    let err = try { do --env $body $dir; null } catch {|err| $err }
    cd $cwd
    rm --recursive $dir
    if $err != null { error make $err }
}

# --- lifecycle --------------------------------------------------------------

def --env "test use alone does not change config" [] {
    let before = $env.config
    assert equal ($env.__NU_ABBR? | default null) null
    nu-abbr status | ignore
    nu-abbr list | ignore
    assert equal $env.config $before
}

def --env "test add before enable does not change config" [] {
    let before = $env.config
    nu-abbr add gs "git status --short"
    assert equal $env.config $before
    assert equal (nu-abbr list | get name) [gs]
    assert equal (nu-abbr list | get value) [null]
}

def --env "test enable writes abbreviations and one hook" [] {
    nu-abbr add gs "git status --short"
    nu-abbr add G "| grep"
    nu-abbr enable
    assert equal ($env.config.abbreviations | select gs G) {gs: "git status --short", G: "| grep"}
    assert equal ($env.config.hooks.pre_prompt | ours | length) 1
    assert equal (nu-abbr status | select enabled abbreviations active hook) {enabled: true, abbreviations: 2, active: 2, hook: true}
}

def --env "test enable is idempotent" [] {
    nu-abbr add gs "git status --short"
    nu-abbr enable
    let once = $env.config
    nu-abbr enable
    assert equal $env.config.abbreviations $once.abbreviations
    assert equal ($env.config.hooks.pre_prompt | length) ($once.hooks.pre_prompt | length)
    assert equal ($env.config.hooks.pre_prompt | ours | length) 1
}

def --env "test add while enabled writes immediately" [] {
    nu-abbr enable
    nu-abbr add gc "git commit"
    assert equal $env.config.abbreviations.gc "git commit"
    nu-abbr add gc "git commit --verbose"
    assert equal $env.config.abbreviations.gc "git commit --verbose"
    assert equal (nu-abbr list | length) 1 "replacing keeps one entry"
}

def --env "test disable restores config" [] {
    $env.config.abbreviations = {mine: "my own"}
    $env.config.hooks.pre_prompt = [{|| null }]
    let before = $env.config
    nu-abbr add gs "git status --short"
    nu-abbr add "~~" {|| "." }
    nu-abbr enable
    nu-abbr disable
    assert equal $env.config $before
    assert equal (nu-abbr status | select enabled hook active) {enabled: false, hook: false, active: 0}
    assert equal (nu-abbr list | get name) [gs "~~"] "abbreviations stay defined"
}

def --env "test disable restores the user entry an abbreviation replaced" [] {
    $env.config.abbreviations = {gs: "git status"}
    nu-abbr add gs "git status --short"
    nu-abbr enable
    assert equal $env.config.abbreviations.gs "git status --short"
    assert equal (nu-abbr status | get replaced) [gs]
    nu-abbr disable
    assert equal $env.config.abbreviations {gs: "git status"}
}

def --env "test disable keeps entries the user changed after enable" [] {
    nu-abbr add gs "git status --short"
    nu-abbr add gd "git diff HEAD"
    nu-abbr enable
    $env.config.abbreviations.gs = "git status"
    nu-abbr disable
    assert equal $env.config.abbreviations {gs: "git status"}
}

def --env "test disable keeps hooks the user added after enable" [] {
    nu-abbr enable
    $env.config.hooks.pre_prompt ++= [{|| null }]
    nu-abbr disable
    assert equal ($env.config.hooks.pre_prompt | ours | length) 0
    assert equal ($env.config.hooks.pre_prompt | length) 1
}

def --env "test enable and disable keep other hooks in order" [] {
    # Unmarked hooks and hooks marked by other modules.
    let user = [
        {|| "plain" }
        {code: {|| "unnamed record" }}
        {name: "nu_git_auto_fetch", code: {|| "other module" }}
        "print 'string hook'"
    ]
    $env.config.hooks.pre_prompt = $user
    nu-abbr enable
    nu-abbr enable
    let hooks = $env.config.hooks.pre_prompt
    assert equal ($hooks | length) 5
    assert equal ($hooks | first 4) $user
    assert equal ($hooks | last | get name) $HOOK_NAME
    nu-abbr disable
    assert equal $env.config.hooks.pre_prompt $user
}

def --env "test disable without enable is a no-op" [] {
    let before = $env.config
    nu-abbr disable
    assert equal $env.config $before
}

# --- add / erase --------------------------------------------------------------

def --env "test invalid names are rejected" [] {
    assert error { nu-abbr add "" "x" }
    assert error { nu-abbr add "a b" "x" }
    assert error { nu-abbr add "a\tb" "x" }
    assert equal (nu-abbr list) []
}

def --env "test names are taken literally" [] {
    nu-abbr add "a.b" "dotted"
    nu-abbr add "0" "zero"
    nu-abbr add "~~" "tilde"
    nu-abbr enable
    assert equal (native "a.b") "dotted"
    assert equal (native "0") "zero"
    assert equal (native "~~") "tilde"
}

def --env "test erase removes the abbreviation" [] {
    $env.config.abbreviations = {gs: "git status"}
    nu-abbr add gs "git status --short"
    nu-abbr add gd "git diff HEAD"
    nu-abbr enable
    nu-abbr erase gs gd
    assert equal $env.config.abbreviations {gs: "git status"}
    assert equal (nu-abbr list) []
    run-hook
    assert equal $env.config.abbreviations {gs: "git status"} "the hook does not bring it back"
}

def --env "test erase of an unknown name changes nothing" [] {
    nu-abbr add gs "git status --short"
    nu-abbr enable
    let before = $env.config
    assert error { nu-abbr erase gs nope }
    assert equal $env.config $before
    assert equal (nu-abbr list | get name) [gs]
}

def --env "test erase while disabled" [] {
    nu-abbr add gs "git status --short"
    nu-abbr erase gs
    assert equal (nu-abbr list) []
}

# --- hook / closures ----------------------------------------------------------

def --env "test closure expansions are evaluated" [] {
    nu-abbr add today {|| "2026-10-18\n" }
    nu-abbr enable
    assert equal $env.config.abbreviations.today "2026-10-18" "trailing newline dropped"
    assert equal (nu-abbr list | get 0 | select eval value) {eval: true, value: "2026-10-18"}
    assert equal (nu-abbr list | get 0.expansion) '{|| "2026-10-18\n" }'
}

def --env "test failing closures do not expand" [] {
    nu-abbr add bad {|| error make {msg: boom} }
    nu-abbr add none {|| null }
    nu-abbr add ext {|| ^nu -n -c "print -e noise; exit 3" }
    nu-abbr enable
    assert equal ($env.config.abbreviations | select bad none ext) {bad: bad, none: none, ext: ext} "the name expands to itself"
    assert equal (nu-abbr status | get active) 0
    assert equal (nu-abbr list | get value) [null null null]
}

def --env "test closure that starts failing stops expanding" [] {
    $env.config.abbreviations = {flaky: "user value"}
    $env.FLAKY = "ok"
    nu-abbr add flaky {|| if $env.FLAKY == "ok" { "expanded" } else { error make {msg: fail} } }
    nu-abbr enable
    assert equal $env.config.abbreviations.flaky "expanded"
    $env.FLAKY = "fail"
    run-hook
    assert equal $env.config.abbreviations.flaky "flaky"
    nu-abbr disable
    assert equal $env.config.abbreviations.flaky "user value"
}

def --env "test hook recomputes closures in the current directory" [] {
    nu-abbr add here {|| pwd | path basename }
    nu-abbr enable
    with-temp-dir {|dir|
        cd $dir
        run-hook
        assert equal $env.config.abbreviations.here ($dir | path basename)
    }
}

def --env "test hook restores entries after the record is reassigned" [] {
    nu-abbr add gs "git status --short"
    nu-abbr enable
    $env.config.abbreviations = {other: "x"}
    run-hook
    assert equal $env.config.abbreviations {other: "x", gs: "git status --short"}
}

def --env "test hook keeps entries the user changed" [] {
    nu-abbr add gs "git status --short"
    nu-abbr enable
    $env.config.abbreviations.gs = "git status"
    run-hook
    assert equal $env.config.abbreviations.gs "git status"
    assert equal (nu-abbr list | get 0.value) null
}

def --env "test git root abbreviation" [] {
    nu-abbr add "~~" {|| let p = (git rev-parse --show-cdup); if $p == "" { "." } else { $p } }
    nu-abbr enable
    with-temp-dir {|dir|
        cd $dir
        run-hook
        assert equal (native "~~") "~~" "outside a repository"
        ^git init --quiet
        mkdir a/b
        cd a/b
        run-hook
        assert equal (native "~~") "../../"
        cd ../..
        run-hook
        assert equal (native "~~") "."
    }
}

# --- interactive sessions ----------------------------------------------------

# Run a script in an interactive `nu` (where removed entries become
# placeholders) and return what it prints as nuon.
def interactive [script: string]: nothing -> any {
    let module = $ROOT | path join nu-abbr
    let prelude = $"use '($module)'\n" + r#'
        def --env run-hook [] {
            let hook = $env.config.hooks.pre_prompt | where {|h| ($h | describe | str starts-with record) and $h.name? == nu_abbr_sync }
            do --env $hook.0.code
        }
    '#
    ^$nu.current-exe -n -i -c ($prelude + $script) | from nuon
}

def "test interactive disable maps names to themselves until swept" [] {
    let r = interactive '
        $env.config.abbreviations = {mine: "my own", gd: "git diff"}
        nu-abbr add gs "git status --short"
        nu-abbr add gd "git diff HEAD"
        nu-abbr enable
        nu-abbr disable
        let placeholder = $env.config.abbreviations
        let pending = nu-abbr status | select hook pending_removal
        run-hook
        let seen = $env.config.abbreviations
        run-hook
        {placeholder: $placeholder, pending: $pending, seen: $seen, done: $env.config.abbreviations, status: (nu-abbr status | select hook pending_removal)} | to nuon
    '
    assert equal $r.placeholder {mine: "my own", gd: "git diff", gs: gs}
    assert equal $r.pending {hook: true, pending_removal: [gs]}
    assert equal $r.seen $r.placeholder "kept for one prompt so the line editor sees it"
    assert equal $r.done {mine: "my own", gd: "git diff"}
    assert equal $r.status {hook: false, pending_removal: []}
}

def "test interactive erase maps the name to itself until swept" [] {
    let r = interactive '
        nu-abbr add gs "git status --short"
        nu-abbr add gc "git commit"
        nu-abbr enable
        nu-abbr erase gs
        let placeholder = $env.config.abbreviations
        run-hook
        run-hook
        {placeholder: $placeholder, done: $env.config.abbreviations, hook: (nu-abbr status | get hook)} | to nuon
    '
    assert equal $r.placeholder {gs: gs, gc: "git commit"}
    assert equal $r.done {gc: "git commit"}
    assert equal $r.hook true "still enabled"
}

def "test interactive add takes over its placeholder" [] {
    let r = interactive '
        nu-abbr add gs "git status --short"
        nu-abbr enable
        nu-abbr erase gs
        nu-abbr add gs "git status"
        run-hook
        run-hook
        {native: $env.config.abbreviations, status: (nu-abbr status | select active pending_removal)} | to nuon
    '
    assert equal $r.native {gs: "git status"}
    assert equal $r.status {active: 1, pending_removal: []}
}

def "test interactive placeholder changed by the user is left alone" [] {
    let r = interactive '
        nu-abbr add gs "git status --short"
        nu-abbr enable
        nu-abbr disable
        $env.config.abbreviations.gs = "mine"
        run-hook
        {native: $env.config.abbreviations, hook: (nu-abbr status | get hook)} | to nuon
    '
    assert equal $r.native {gs: mine}
    assert equal $r.hook false
}

def "test interactive disable twice keeps the hook until swept" [] {
    let r = interactive '
        nu-abbr add gs "git status --short"
        nu-abbr enable
        nu-abbr disable
        nu-abbr disable
        let hook = nu-abbr status | get hook
        run-hook
        run-hook
        {hook: $hook, native: $env.config.abbreviations, after: (nu-abbr status | get hook)} | to nuon
    '
    assert equal $r {hook: true, native: {}, after: false}
}

def "test interactive closures are first evaluated by the hook" [] {
    let r = interactive '
        $env.config.abbreviations = {here: "my own"}
        nu-abbr add gs "git status --short"
        nu-abbr add here {|| "now" }
        nu-abbr enable
        let enabled = $env.config.abbreviations
        nu-abbr add later {|| "later" }
        let added = $env.config.abbreviations
        run-hook
        let hooked = $env.config.abbreviations
        let replaced = nu-abbr status | get replaced
        nu-abbr disable
        {enabled: $enabled, added: $added, hooked: $hooked, replaced: $replaced, disabled: $env.config.abbreviations} | to nuon
    '
    assert equal $r.enabled {here: "my own", gs: "git status --short"}
    assert equal $r.added $r.enabled
    assert equal $r.hooked {here: now, gs: "git status --short", later: later}
    assert equal $r.replaced [here]
    assert equal $r.disabled {here: "my own", gs: gs, later: later}
}

# --- runner -----------------------------------------------------------------

# Each test runs in its own closure, so `$env` changes do not leak between
# tests.
const TESTS = [
    "test use alone does not change config"
    "test add before enable does not change config"
    "test enable writes abbreviations and one hook"
    "test enable is idempotent"
    "test add while enabled writes immediately"
    "test disable restores config"
    "test disable restores the user entry an abbreviation replaced"
    "test disable keeps entries the user changed after enable"
    "test disable keeps hooks the user added after enable"
    "test enable and disable keep other hooks in order"
    "test disable without enable is a no-op"
    "test invalid names are rejected"
    "test names are taken literally"
    "test erase removes the abbreviation"
    "test erase of an unknown name changes nothing"
    "test erase while disabled"
    "test closure expansions are evaluated"
    "test failing closures do not expand"
    "test closure that starts failing stops expanding"
    "test hook recomputes closures in the current directory"
    "test hook restores entries after the record is reassigned"
    "test hook keeps entries the user changed"
    "test git root abbreviation"
    "test interactive disable maps names to themselves until swept"
    "test interactive erase maps the name to itself until swept"
    "test interactive add takes over its placeholder"
    "test interactive placeholder changed by the user is left alone"
    "test interactive disable twice keeps the hook until swept"
    "test interactive closures are first evaluated by the hook"
]

def run-test [name: string]: nothing -> any {
    try {
        match $name {
            "test use alone does not change config" => { test use alone does not change config }
            "test add before enable does not change config" => { test add before enable does not change config }
            "test enable writes abbreviations and one hook" => { test enable writes abbreviations and one hook }
            "test enable is idempotent" => { test enable is idempotent }
            "test add while enabled writes immediately" => { test add while enabled writes immediately }
            "test disable restores config" => { test disable restores config }
            "test disable restores the user entry an abbreviation replaced" => { test disable restores the user entry an abbreviation replaced }
            "test disable keeps entries the user changed after enable" => { test disable keeps entries the user changed after enable }
            "test disable keeps hooks the user added after enable" => { test disable keeps hooks the user added after enable }
            "test enable and disable keep other hooks in order" => { test enable and disable keep other hooks in order }
            "test disable without enable is a no-op" => { test disable without enable is a no-op }
            "test invalid names are rejected" => { test invalid names are rejected }
            "test names are taken literally" => { test names are taken literally }
            "test erase removes the abbreviation" => { test erase removes the abbreviation }
            "test erase of an unknown name changes nothing" => { test erase of an unknown name changes nothing }
            "test erase while disabled" => { test erase while disabled }
            "test closure expansions are evaluated" => { test closure expansions are evaluated }
            "test failing closures do not expand" => { test failing closures do not expand }
            "test closure that starts failing stops expanding" => { test closure that starts failing stops expanding }
            "test hook recomputes closures in the current directory" => { test hook recomputes closures in the current directory }
            "test hook restores entries after the record is reassigned" => { test hook restores entries after the record is reassigned }
            "test hook keeps entries the user changed" => { test hook keeps entries the user changed }
            "test git root abbreviation" => { test git root abbreviation }
            "test interactive disable maps names to themselves until swept" => { test interactive disable maps names to themselves until swept }
            "test interactive erase maps the name to itself until swept" => { test interactive erase maps the name to itself until swept }
            "test interactive add takes over its placeholder" => { test interactive add takes over its placeholder }
            "test interactive placeholder changed by the user is left alone" => { test interactive placeholder changed by the user is left alone }
            "test interactive disable twice keeps the hook until swept" => { test interactive disable twice keeps the hook until swept }
            "test interactive closures are first evaluated by the hook" => { test interactive closures are first evaluated by the hook }
            _ => (error make {msg: $"no such test: ($name)"})
        }
        null
    } catch {|err| $err.msg }
}

def main [] {
    let results = $TESTS | each {|name| {name: $name, error: (do { run-test $name })} }
    for r in $results {
        if $r.error == null {
            print $"ok    ($r.name)"
        } else {
            print $"FAIL  ($r.name): ($r.error)"
        }
    }
    let failed = $results | where error != null | length
    print $"\n($results | length) tests, ($failed) failed"
    if $failed > 0 { exit 1 }
}
