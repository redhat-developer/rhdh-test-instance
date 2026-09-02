#!/bin/bash
# Resolve the parent workspace directory (main repo root's parent), even from a worktree.

resolve_workspace_dir() {
    local script_dir="$1"
    local git_common main_repo_root
    git_common="$(cd "$script_dir" && git rev-parse --git-common-dir 2>/dev/null)"
    main_repo_root="$(cd "$script_dir" && cd "$git_common/.." 2>/dev/null && pwd)"
    dirname "${main_repo_root:-$script_dir}"
}
