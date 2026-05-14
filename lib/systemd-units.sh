# Shared parser for ExecStart= directives across systemd unit files.
# Single source of truth for the "what *.sh scripts does production
# launch?" question — install.sh sources it to know what to symlink;
# install-smoke + prompt-contracts-smoke source it to know what to
# fence. Adding a new unit means landing one .service file; the three
# call sites pick it up without parallel hand-maintained lists drifting.
#
# Parse contract: command-token split (drops everything after the first
# whitespace) THEN basename. Without that order, a future
# `ExecStart=/home/odio/.pr-reviewer/review.sh --repo cncorp/plow`
# would basename to "plow" (greedy `.*/` eats through the last `/` in
# `cncorp/plow`) and silently drop review.sh from the managed list.

# _iter_execstart_scripts <unit_files...>
#
# Private emitter. Walks every ExecStart= line in the given unit files
# and emits the *.sh basenames (one per line). Pure parse — no
# file-existence test. The public functions below wrap this with the
# tests they need.
_iter_execstart_scripts() {
    local execstart cmd_path script
    while IFS= read -r execstart; do
        cmd_path="${execstart#ExecStart=}"
        cmd_path="${cmd_path%% *}"
        script="${cmd_path##*/}"
        [[ -n "$script" ]] || continue
        [[ "$script" == *.sh ]] || continue
        echo "$script"
    done < <(grep -h "^ExecStart=" "$@" | sort -u)
}

# list_execstart_shell_scripts <repo_dir> <unit_files...>
#
# Emit one *.sh basename per line for every ExecStart= that resolves
# to an existing file under <repo_dir>. Missing files are silently
# skipped — callers that need strict drift-detection use
# assert_execstart_shell_scripts_present instead.
list_execstart_shell_scripts() {
    local repo_dir="$1"; shift
    local script
    while IFS= read -r script; do
        [[ -f "$repo_dir/$script" ]] && echo "$script"
    done < <(_iter_execstart_scripts "$@")
}

# assert_execstart_shell_scripts_present <repo_dir> <unit_files...>
#
# Returns 1 (with error on stderr) when any ExecStart= references a
# .sh basename that doesn't exist in <repo_dir>. install.sh uses this
# to surface unit/script drift at install time — silently dropping a
# missing .sh would ship a broken systemd unit.
assert_execstart_shell_scripts_present() {
    local repo_dir="$1"; shift
    local script
    while IFS= read -r script; do
        [[ -f "$repo_dir/$script" ]] || {
            echo "unit ExecStart references '$script' but $repo_dir/$script doesn't exist" >&2
            return 1
        }
    done < <(_iter_execstart_scripts "$@")
}
