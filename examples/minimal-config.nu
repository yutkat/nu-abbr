# Minimal config to try nu-abbr without any other customization:
#
#   nu --config examples/minimal-config.nu
#
# In your own config.nu, replace the path below with where you cloned the repo,
# or put the clone's parent directory in $env.NU_LIB_DIRS and `use nu-abbr`.

$env.config.show_banner = false

use ../nu-abbr

nu-abbr add gc "git commit"
nu-abbr add ga "git add ."
nu-abbr add gb "git branch"
nu-abbr add gd "git diff HEAD"
nu-abbr add gs "git status --short"
# zsh's `gh pr view -w || gh pr create -w`; Nushell has no `||`.
nu-abbr add pr "try { gh pr view -w } catch { gh pr create -w }"
nu-abbr add G "| grep"
# Recomputed before every prompt; "." at the repository root, no expansion
# outside a repository.
nu-abbr add "~~" {|| let p = (git rev-parse --show-cdup); if $p == "" { "." } else { $p } }

nu-abbr enable
