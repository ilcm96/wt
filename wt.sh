#!/usr/bin/env bash

set -euo pipefail

VERSION='1.0.0'

# File name patterns to sync at any depth below the worktree root.
SYNC_FILE_PATTERNS=(
  '.env'
  '.env.*'
  'AGENTS.override.md'
  'secret.yaml'
)

# Directory names to skip at any depth below the worktree root.
SYNC_EXCLUDE_DIRS=(
  # Version control
  '.git'
  # JavaScript / TypeScript
  'node_modules'
  '.npm'
  '.pnpm-store'
  # Python
  '.venv'
  'venv'
  '__pycache__'
  '.pytest_cache'
  '.ruff_cache'
  # Java / Kotlin
  '.gradle'
  '.m2'
  'target'
  'build'
)

worktree_paths=()
worktree_branches=()
resolved_worktree_path=""
resolved_worktree_branch=""
copied_file_counts=()

usage() {
  local sync_file_patterns='none'
  local sync_exclude_dirs='none'

  if [[ "${#SYNC_FILE_PATTERNS[@]}" -gt 0 ]]; then
    printf -v sync_file_patterns '%s, ' "${SYNC_FILE_PATTERNS[@]}"
    sync_file_patterns="${sync_file_patterns%, }"
  fi

  if [[ "${#SYNC_EXCLUDE_DIRS[@]}" -gt 0 ]]; then
    printf -v sync_exclude_dirs '%s, ' "${SYNC_EXCLUDE_DIRS[@]}"
    sync_exclude_dirs="${sync_exclude_dirs%, }"
  fi

  printf 'wt %s\n\n' "$VERSION"
  cat <<EOF
Usage:
  wt list
  wt switch <branch-or-worktree>
  wt new <new-branch> [base-branch]
  wt track <branch> [remote]
  wt rename <branch-or-worktree> <new-branch>
  wt remove [--force] <branch-or-worktree>
  wt sync
  wt code <branch-or-worktree>
  wt codex <branch-or-worktree>
  wt completion bash|zsh

Commands:
  list
    Show worktrees for the current repository.

  switch
    Switch to a worktree shown by wt list.

  new
    Create a new branch and worktree from a base branch.
    Uses the current branch when [base-branch] is omitted.

  track
    Create a new tracking branch and worktree from a remote branch.
    Default remote: origin

  rename
    Rename the local branch of a worktree without moving its directory.

  remove
    Remove a worktree and delete the linked local branch.
    Use --force to remove a worktree with modified or untracked files.

  sync
    Propagate matching files from the current worktree to other worktrees.
    File patterns: $sync_file_patterns
    Excluded directory names (at any depth): $sync_exclude_dirs

  code
    Open a worktree in VSCode.

  codex
    Open a worktree in Codex App.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

run_quiet() {
  local output_file
  local status

  output_file="$(mktemp "${TMPDIR:-/tmp}/wt.XXXXXX")" || return 1

  if "$@" >"$output_file" 2>&1; then
    rm -f "$output_file"
    return 0
  else
    status=$?
    cat "$output_file" >&2
    rm -f "$output_file"
    return "$status"
  fi
}

slugify_branch() {
  printf '%s' "$1" | sed 's#/#-#g; s#[^A-Za-z0-9._-]#-#g'
}

display_path() {
  local path="$1"

  if [[ "$path" == "$HOME" ]]; then
    printf '~'
  elif [[ "$path" == "$HOME/"* ]]; then
    printf '~/%s' "${path#"$HOME"/}"
  else
    printf '%s' "$path"
  fi
}

url_encode() {
  local value="$1"

  URL_ENCODE_VALUE="$value" /usr/bin/osascript -l JavaScript \
    -e 'ObjC.import("stdlib"); encodeURIComponent($.getenv("URL_ENCODE_VALUE"))'
}

print_kv() {
  local label="$1"
  local value="$2"

  printf '  %-6s %s\n' "$label" "$value"
}

print_worktree_plan() {
  local mode="$1"
  local branch="$2"
  local path="$3"

  printf '[%s] %s\n\n' "$mode" "$branch"
  print_kv "repo" "$repo_name"
  print_kv "branch" "$branch"
  print_kv "path" "$path"
  printf '\n'
}

setup_repo_context() {
  current_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "must be run inside a Git repository."

  common_dir="$(git -C "$current_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "failed to resolve the common Git directory."

  main_root="$(dirname "$common_dir")"
  repo_name="$(basename "$main_root")"
  parent_dir="$(dirname "$main_root")"
}

target_dir_for_branch() {
  local branch="$1"
  local slug

  slug="$(slugify_branch "$branch")"
  printf '%s/%s-%s' "$parent_dir" "$repo_name" "$slug"
}

ensure_target_absent() {
  local target_dir="$1"

  [[ ! -e "$target_dir" ]] || die "target directory already exists: $target_dir"
}

branch_exists() {
  local branch="$1"

  git -C "$current_root" show-ref --verify --quiet "refs/heads/$branch"
}

ensure_branch_absent() {
  local branch="$1"

  ! branch_exists "$branch" || die "local branch already exists: $branch"
}

current_branch_name() {
  local branch

  branch="$(git -C "$current_root" branch --show-current)"
  [[ -n "$branch" ]] || die "cannot infer the base branch in detached HEAD state."
  printf '%s\n' "$branch"
}

remote_fetches_branch() {
  local remote="$1"
  local branch="$2"
  local refspec
  local source_ref
  local target_ref

  while IFS= read -r refspec; do
    refspec="${refspec#+}"
    source_ref="${refspec%%:*}"
    target_ref="${refspec#*:}"

    if [[ "$source_ref" == "refs/heads/*" && "$target_ref" == "refs/remotes/$remote/*" ]]; then
      return 0
    fi

    if [[ "$source_ref" == "refs/heads/$branch" && "$target_ref" == "refs/remotes/$remote/$branch" ]]; then
      return 0
    fi
  done < <(git -C "$current_root" config --get-all "remote.$remote.fetch" 2>/dev/null || true)

  return 1
}

ensure_remote_fetches_branch() {
  local remote="$1"
  local branch="$2"

  remote_fetches_branch "$remote" "$branch" \
    || run_quiet git -C "$current_root" remote set-branches --add "$remote" "$branch"
}

add_worktree_entry() {
  local worktree_path="$1"
  local branch="${2:-}"

  [[ -n "$worktree_path" ]] || return 0
  [[ -n "$branch" ]] || branch='(detached)'

  worktree_paths+=("$worktree_path")
  worktree_branches+=("$branch")
}

load_worktrees() {
  local worktree_path=""
  local branch=""
  local line

  worktree_paths=()
  worktree_branches=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        add_worktree_entry "$worktree_path" "$branch"
        worktree_path="${line#worktree }"
        branch=""
        ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        ;;
      branch\ *)
        branch="${line#branch }"
        ;;
      detached)
        branch=""
        ;;
      "")
        add_worktree_entry "$worktree_path" "$branch"
        worktree_path=""
        branch=""
        ;;
    esac
  done < <(git -C "$current_root" worktree list --porcelain)

  add_worktree_entry "$worktree_path" "$branch"
}

match_worktree_target() {
  local target="$1"
  local path="$2"
  local branch="$3"
  local path_name
  local shown_path

  path_name="$(basename "$path")"
  shown_path="$(display_path "$path")"

  [[ "$branch" == "$target" || "$path" == "$target" || "$shown_path" == "$target" || "$path_name" == "$target" ]]
}

resolve_worktree_target() {
  local target="$1"
  local action_label="${2:-Target}"
  local matched_count=0
  local index

  resolved_worktree_path=""
  resolved_worktree_branch=""

  load_worktrees

  for ((index = 0; index < ${#worktree_paths[@]}; index++)); do
    if match_worktree_target "$target" "${worktree_paths[$index]}" "${worktree_branches[$index]}"; then
      resolved_worktree_path="${worktree_paths[$index]}"
      resolved_worktree_branch="${worktree_branches[$index]}"
      matched_count=$((matched_count + 1))
    fi
  done

  [[ "$matched_count" -gt 0 ]] || die "${action_label} worktree not found: $target"
  [[ "$matched_count" -eq 1 ]] || die "${action_label} target is ambiguous. Use a branch name or full path: $target"
}

worktree_state() {
  local path="$1"
  local status_output

  if ! status_output="$(git -C "$path" status --porcelain 2>/dev/null)"; then
    printf 'unknown'
  elif [[ -n "$status_output" ]]; then
    printf 'dirty'
  else
    printf 'clean'
  fi
}

print_worktree_row() {
  local path="$1"
  local branch="$2"
  local branch_width="$3"
  local marker=" "
  local state
  local shown_path

  [[ "$path" != "$current_root" ]] || marker="*"

  state="$(worktree_state "$path")"
  shown_path="$(display_path "$path")"

  printf '%s %-*s  %-7s  %s\n' "$marker" "$branch_width" "$branch" "$state" "$shown_path"
}

sync_files_to_target() {
  local source_dir="$1"
  local target_dir="$2"
  local source_file relative_path target_path file_name
  local index
  local find_args=("$source_dir" -mindepth 1)

  copied_file_counts=()
  for ((index = 0; index < ${#SYNC_FILE_PATTERNS[@]}; index++)); do
    copied_file_counts+=(0)
  done

  [[ "${#SYNC_FILE_PATTERNS[@]}" -gt 0 ]] || return 0

  if [[ "${#SYNC_EXCLUDE_DIRS[@]}" -gt 0 ]]; then
    find_args+=(-type d '(')
    for ((index = 0; index < ${#SYNC_EXCLUDE_DIRS[@]}; index++)); do
      [[ "$index" -eq 0 ]] || find_args+=(-o)
      find_args+=(-name "${SYNC_EXCLUDE_DIRS[$index]}")
    done
    find_args+=(')' -prune -o)
  fi
  find_args+=(-type f -print0)

  while IFS= read -r -d '' source_file; do
    relative_path="${source_file#"$source_dir"/}"
    case "$relative_path" in
      *[sS][aA][mM][pP][lL][eE]*)
        continue
        ;;
    esac

    file_name="${source_file##*/}"
    for ((index = 0; index < ${#SYNC_FILE_PATTERNS[@]}; index++)); do
      [[ "$file_name" == ${SYNC_FILE_PATTERNS[$index]} ]] || continue
      target_path="$target_dir/$relative_path"
      mkdir -p "$(dirname "$target_path")"
      cp -p "$source_file" "$target_path"
      copied_file_counts[$index]=$((copied_file_counts[$index] + 1))
      # Count overlapping patterns only once, under the first matching pattern.
      break
    done
  done < <(find "${find_args[@]}")
}

format_synced_file_summary() {
  local index
  local separator=""

  for ((index = 0; index < ${#SYNC_FILE_PATTERNS[@]}; index++)); do
    [[ "${copied_file_counts[$index]:-0}" -gt 0 ]] || continue
    printf '%s%s %s' "$separator" "${SYNC_FILE_PATTERNS[$index]}" "${copied_file_counts[$index]}"
    separator=", "
  done

  [[ -n "$separator" ]] || printf 'none'
}

print_synced_files() {
  printf 'synced files: %s\n' "$(format_synced_file_summary)"
}

cmd_list() {
  local index
  local branch
  local branch_column_width=6

  [[ $# -eq 0 ]] || die "Usage: wt list"

  load_worktrees

  if [[ "${#worktree_paths[@]}" -eq 0 ]]; then
    print_kv "target" "no worktrees found."
    return
  fi

  for ((index = 0; index < ${#worktree_branches[@]}; index++)); do
    branch="${worktree_branches[$index]}"
    (( ${#branch} <= branch_column_width )) || branch_column_width="${#branch}"
  done

  printf '  %-*s  %-7s  %s\n' "$branch_column_width" "BRANCH" "STATE" "PATH"
  printf '  %-*s  %-7s  %s\n' "$branch_column_width" "------" "-----" "----"

  for ((index = 0; index < ${#worktree_paths[@]}; index++)); do
    print_worktree_row "${worktree_paths[$index]}" "${worktree_branches[$index]}" "$branch_column_width"
  done
}

cmd_switch() {
  local print_path=0
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print-path)
        print_path=1
        ;;
      -*)
        die "Usage: wt switch <branch-or-worktree>"
        ;;
      *)
        [[ -z "$target" ]] || die "Usage: wt switch <branch-or-worktree>"
        target="$1"
        ;;
    esac
    shift
  done

  [[ -n "$target" ]] || die "switch requires <branch-or-worktree>."

  resolve_worktree_target "$target" "Switch"

  if [[ "$print_path" -eq 1 ]]; then
    printf '%s\n' "$resolved_worktree_path"
    return
  fi

  print_worktree_plan "switch" "$resolved_worktree_branch" "$resolved_worktree_path"
  print_kv "note" "Add the wt shell function to ~/.zshrc to change the current shell directory."
}

cmd_new() {
  local new_branch="${1:-}"
  local base_branch="${2:-}"
  local target_dir

  [[ -n "$new_branch" ]] || die "new requires <new-branch>."
  [[ $# -le 2 ]] || die "Usage: wt new <new-branch> [base-branch]"

  if [[ -z "$base_branch" ]]; then
    base_branch="$(current_branch_name)"
  fi

  ensure_branch_absent "$new_branch"
  target_dir="$(target_dir_for_branch "$new_branch")"
  ensure_target_absent "$target_dir"

  run_quiet git -C "$current_root" worktree add -b "$new_branch" "$target_dir" "$base_branch"
  sync_files_to_target "$current_root" "$target_dir"
  printf 'created branch %s from %s @ %s\n' "$new_branch" "$base_branch" "$(display_path "$target_dir")"
  print_synced_files
}

cmd_track() {
  local branch="${1:-}"
  local remote="${2:-origin}"
  local target_dir

  [[ -n "$branch" ]] || die "track requires <branch>."
  [[ $# -le 2 ]] || die "Usage: wt track <branch> [remote]"

  ensure_branch_absent "$branch"
  target_dir="$(target_dir_for_branch "$branch")"
  ensure_target_absent "$target_dir"

  ensure_remote_fetches_branch "$remote" "$branch"
  run_quiet git -C "$current_root" fetch "$remote" "$branch"
  run_quiet git -C "$current_root" worktree add --track -b "$branch" "$target_dir" "$remote/$branch"
  sync_files_to_target "$current_root" "$target_dir"
  printf 'created tracking branch %s from %s @ %s\n' "$branch" "$remote/$branch" "$(display_path "$target_dir")"
  print_synced_files
}

cmd_rename() {
  local target="${1:-}"
  local new_branch="${2:-}"
  local old_branch

  [[ $# -eq 2 && -n "$target" && -n "$new_branch" ]] \
    || die "Usage: wt rename <branch-or-worktree> <new-branch>"

  resolve_worktree_target "$target" "Rename"
  old_branch="$resolved_worktree_branch"
  [[ "$old_branch" != '(detached)' ]] || die "cannot rename a branch in detached HEAD state."
  git check-ref-format --branch "$new_branch" >/dev/null 2>&1 \
    || die "invalid branch name: $new_branch"
  ensure_branch_absent "$new_branch"

  run_quiet git -C "$resolved_worktree_path" branch -m -- "$new_branch"
  printf 'renamed branch %s to %s @ %s\n' "$old_branch" "$new_branch" "$(display_path "$resolved_worktree_path")"
}

cmd_remove() {
  local force=0
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=1
        ;;
      -*)
        die "Usage: wt remove [--force] <branch-or-worktree>"
        ;;
      *)
        [[ -z "$target" ]] || die "Usage: wt remove [--force] <branch-or-worktree>"
        target="$1"
        ;;
    esac
    shift
  done

  [[ -n "$target" ]] || die "remove requires <branch-or-worktree>."

  resolve_worktree_target "$target" "Remove"

  [[ "$resolved_worktree_path" != "$current_root" ]] || die "cannot remove the current worktree: $resolved_worktree_path"
  [[ "$resolved_worktree_path" != "$main_root" ]] || die "cannot remove the main worktree: $resolved_worktree_path"

  if [[ "$force" -eq 1 ]]; then
    run_quiet git -C "$current_root" worktree remove --force "$resolved_worktree_path"
  else
    run_quiet git -C "$current_root" worktree remove "$resolved_worktree_path"
  fi

  printf 'removed worktree @ %s\n' "$(display_path "$resolved_worktree_path")"

  if [[ "$resolved_worktree_branch" == '(detached)' ]]; then
    return
  fi

  run_quiet git -C "$main_root" branch -D "$resolved_worktree_branch"
  printf 'deleted branch %s\n' "$resolved_worktree_branch"
}

cmd_sync() {
  local index
  local synced_count=0

  [[ $# -eq 0 ]] || die "Usage: wt sync"

  load_worktrees

  for ((index = 0; index < ${#worktree_paths[@]}; index++)); do
    [[ "${worktree_paths[$index]}" != "$current_root" ]] || continue
    [[ -d "${worktree_paths[$index]}" ]] || continue

    sync_files_to_target "$current_root" "${worktree_paths[$index]}"
    synced_count=$((synced_count + 1))
  done

  if [[ "$synced_count" -eq 0 ]]; then
    printf 'no worktrees to propagate files to\n'
    return
  fi

  if [[ "$synced_count" -eq 1 ]]; then
    printf 'propagated files to 1 worktree: %s\n' "$(format_synced_file_summary)"
  else
    printf 'propagated files to %s worktrees: %s\n' "$synced_count" "$(format_synced_file_summary)"
  fi
}

cmd_open_editor() {
  local editor_command="$1"
  local target="${2:-}"

  [[ -n "$target" ]] || die "${editor_command} requires <branch-or-worktree>."
  [[ $# -eq 2 ]] || die "Usage: wt ${editor_command} <branch-or-worktree>"
  command -v "$editor_command" >/dev/null 2>&1 || die "${editor_command} command not found."

  resolve_worktree_target "$target" "Open"
  "$editor_command" "$resolved_worktree_path"
}

cmd_open_codex() {
  local target="${1:-}"
  local encoded_path

  [[ -n "$target" ]] || die "codex requires <branch-or-worktree>."
  [[ $# -eq 1 ]] || die "Usage: wt codex <branch-or-worktree>"

  resolve_worktree_target "$target" "Open"
  encoded_path="$(url_encode "$resolved_worktree_path")"
  /usr/bin/open "codex://threads/new?path=$encoded_path"
}

print_bash_completion() {
  cat <<'EOF'
_wt_reply() {
  local current="$1"
  shift
  local candidate

  COMPREPLY=()
  for candidate in "$@"; do
    [[ "$candidate" == "$current"* ]] || continue
    COMPREPLY+=("$candidate")
  done
}

_wt_unique_reply() {
  local current="$1"
  shift
  local candidate
  local -A seen=()
  local -a unique=()

  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    [[ -z "${seen[$candidate]:-}" ]] || continue
    seen["$candidate"]=1
    unique+=("$candidate")
  done

  _wt_reply "$current" "${unique[@]}"
}

_wt_worktree_targets() {
  local current="$1"
  local mode="${2:-all}"
  local line worktree_path branch current_root common_dir main_root
  local -a targets=()

  current_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  main_root="${common_dir%/.git}"

  _wt_add_worktree_target() {
    [[ -n "$worktree_path" ]] || return 0
    if [[ "$mode" == "removable" ]]; then
      [[ "$worktree_path" != "$current_root" ]] || return 0
      [[ "$worktree_path" != "$main_root" ]] || return 0
    fi

    if [[ -n "$branch" ]]; then
      targets+=("$branch")
    else
      targets+=("${worktree_path##*/}")
    fi
  }

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        _wt_add_worktree_target
        worktree_path="${line#worktree }"
        branch=""
        ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        ;;
      branch\ *)
        branch="${line#branch }"
        ;;
      detached)
        branch=""
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  _wt_add_worktree_target
  _wt_unique_reply "$current" "${targets[@]}"
}

_wt_remote_branches() {
  local current="$1"
  local remote="${2:-}"
  local ref branch
  local -a branches=()

  if [[ -n "$remote" ]]; then
    while IFS= read -r ref; do
      [[ "$ref" != refs/remotes/*/HEAD ]] || continue
      branch="${ref#refs/remotes/$remote/}"
      git show-ref --verify --quiet "refs/heads/$branch" && continue
      branches+=("$branch")
    done < <(git for-each-ref --format='%(refname)' "refs/remotes/$remote" 2>/dev/null)
  else
    while IFS= read -r ref; do
      [[ "$ref" != refs/remotes/*/HEAD ]] || continue
      branch="${ref#refs/remotes/}"
      branch="${branch#*/}"
      git show-ref --verify --quiet "refs/heads/$branch" && continue
      branches+=("$branch")
    done < <(git for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)
  fi

  _wt_unique_reply "$current" "${branches[@]}"
}

_wt_remote_names() {
  local current="$1"
  local remote
  local -a remotes=()

  while IFS= read -r remote; do
    remotes+=("$remote")
  done < <(git remote 2>/dev/null)

  _wt_unique_reply "$current" "${remotes[@]}"
}

_wt_base_branches() {
  local current="$1"
  local ref
  local -a branches=()

  while IFS= read -r ref; do
    [[ "$ref" != */HEAD ]] || continue
    branches+=("$ref")
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null)

  _wt_unique_reply "$current" "${branches[@]}"
}

_wt() {
  local current="${COMP_WORDS[COMP_CWORD]:-}"
  local command="${COMP_WORDS[1]:-}"

  case "$COMP_CWORD" in
    1)
      _wt_reply "$current" list switch new track rename remove sync code codex completion
      return
      ;;
  esac

  case "$command" in
    switch|rename)
      [[ "$COMP_CWORD" -eq 2 ]] && _wt_worktree_targets "$current"
      ;;
    new)
      [[ "$COMP_CWORD" -eq 3 ]] && _wt_base_branches "$current"
      ;;
    track)
      case "$COMP_CWORD" in
        2)
          _wt_remote_branches "$current"
          ;;
        3)
          _wt_remote_names "$current"
          ;;
      esac
      ;;
    remove)
      if [[ "$current" == -* ]]; then
        _wt_reply "$current" -f --force
        return
      fi
      _wt_worktree_targets "$current" removable
      ;;
    code|codex)
      [[ "$COMP_CWORD" -eq 2 ]] && _wt_worktree_targets "$current"
      ;;
    completion)
      [[ "$COMP_CWORD" -eq 2 ]] && _wt_reply "$current" bash zsh
      ;;
  esac
}

complete -F _wt wt
EOF
}

print_zsh_completion() {
  cat <<'EOF'
#compdef wt

_wt_worktree_targets() {
  local mode="${1:-all}"
  local line worktree_path branch current_root common_dir main_root
  local -a targets

  current_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main_root="${common_dir:h}"

  _wt_add_worktree_target() {
    [[ -n "$worktree_path" ]] || return 0
    if [[ "$mode" == "removable" ]]; then
      [[ "$worktree_path" != "$current_root" ]] || return 0
      [[ "$worktree_path" != "$main_root" ]] || return 0
    fi

    if [[ -n "$branch" ]]; then
      targets+=("$branch")
    else
      targets+=("${worktree_path:t}")
    fi
  }

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        _wt_add_worktree_target
        worktree_path="${line#worktree }"
        branch=""
        ;;
      branch\ refs/heads/*)
        branch="${line#branch refs/heads/}"
        ;;
      branch\ *)
        branch="${line#branch }"
        ;;
      detached)
        branch=""
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  _wt_add_worktree_target
  targets=("${(@u)targets}")
  (( ${#targets[@]} > 0 )) || return 1
  compadd -- "${targets[@]}"
}

_wt_remote_branches() {
  local remote="${1:-}"
  local ref branch
  local -a branches

  if [[ -n "$remote" ]]; then
    for ref in "${(@f)$(git for-each-ref --format='%(refname)' "refs/remotes/$remote" 2>/dev/null)}"; do
      [[ "$ref" != refs/remotes/*/HEAD ]] || continue
      branch="${ref#refs/remotes/$remote/}"
      git show-ref --verify --quiet "refs/heads/$branch" && continue
      branches+=("$branch")
    done
  else
    for ref in "${(@f)$(git for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)}"; do
      [[ "$ref" != refs/remotes/*/HEAD ]] || continue
      branch="${ref#refs/remotes/*/}"
      git show-ref --verify --quiet "refs/heads/$branch" && continue
      branches+=("$branch")
    done
  fi

  branches=("${(@u)branches}")
  (( ${#branches[@]} > 0 )) || return 1
  compadd -- "${branches[@]}"
}

_wt_remote_names() {
  local -a remotes

  remotes=("${(@f)$(git remote 2>/dev/null)}")
  (( ${#remotes[@]} > 0 )) || return 1
  compadd -- "${remotes[@]}"
}

_wt_base_branches() {
  local ref
  local -a branches

  for ref in "${(@f)$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null)}"; do
    [[ "$ref" != */HEAD ]] || continue
    branches+=("$ref")
  done

  branches=("${(@u)branches}")
  (( ${#branches[@]} > 0 )) || return 1
  compadd -- "${branches[@]}"
}

_wt_command_names() {
  local -a commands

  commands=(
    'list:Show worktrees for the current repository'
    'switch:Switch to a worktree shown by wt list'
    'new:Create a new branch and worktree from a base branch'
    'track:Create a tracking branch and worktree from a remote branch'
    'rename:Rename a local branch without moving its worktree'
    'remove:Remove a worktree and delete the linked local branch'
    'sync:Propagate files to other worktrees'
    'code:Open a worktree in VSCode'
    'codex:Open a worktree in Codex App'
  )

  _describe -V -t commands 'wt command' commands
}

_wt_switch() {
  _wt_worktree_targets
}

_wt_track() {
  case "$CURRENT" in
    3)
      _wt_remote_branches
      ;;
    4)
      _wt_remote_names
      ;;
  esac
}

_wt_new() {
  case "$CURRENT" in
    3)
      _message 'new branch name'
      ;;
    4)
      _wt_base_branches
      ;;
  esac
}

_wt_rename() {
  case "$CURRENT" in
    3)
      _wt_worktree_targets
      ;;
    4)
      _message 'new branch name'
      ;;
  esac
}

_wt_remove() {
  if [[ "$words[CURRENT]" == -* ]]; then
    compadd -- -f --force
    return
  fi

  _wt_worktree_targets removable
}

_wt_open_editor() {
  _wt_worktree_targets
}

_wt() {
  local command="${words[2]:-}"

  if (( CURRENT == 2 )); then
    _wt_command_names
    return
  fi

  case "$command" in
    switch)
      _wt_switch
      ;;
    new)
      _wt_new
      ;;
    track)
      _wt_track
      ;;
    rename)
      _wt_rename
      ;;
    remove)
      _wt_remove
      ;;
    code|codex)
      _wt_open_editor
      ;;
  esac
}

if (( $+functions[compdef] )); then
  compdef _wt wt
fi
EOF
}

cmd_completion() {
  local shell="${1:-}"

  [[ "$shell" == "bash" || "$shell" == "zsh" ]] || die "Usage: wt completion bash|zsh"
  [[ $# -eq 1 ]] || die "Usage: wt completion bash|zsh"

  case "$shell" in
    bash)
      print_bash_completion
      ;;
    zsh)
      print_zsh_completion
      ;;
  esac
}

main() {
  local command="${1:-}"

  case "$command" in
    -h)
      usage
      exit 0
      ;;
    -v)
      printf 'wt %s\n' "$VERSION"
      exit 0
      ;;
    "")
      usage
      exit 1
      ;;
  esac

  if [[ "$command" == "completion" ]]; then
    shift
    cmd_completion "$@"
    exit 0
  fi

  setup_repo_context

  shift
  case "$command" in
    list)
      cmd_list "$@"
      ;;
    switch)
      cmd_switch "$@"
      ;;
    new)
      cmd_new "$@"
      ;;
    track)
      cmd_track "$@"
      ;;
    rename)
      cmd_rename "$@"
      ;;
    remove)
      cmd_remove "$@"
      ;;
    sync)
      cmd_sync "$@"
      ;;
    code)
      cmd_open_editor code "$@"
      ;;
    codex)
      cmd_open_codex "$@"
      ;;
    *)
      usage
      printf '\n' >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
