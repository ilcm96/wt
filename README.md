# wt

A single Bash script for creating and managing Git worktrees. Customize it directly-no build step required.

## Installation

Requires Bash and Git. Clone the repository and link the script:

```bash
git clone https://github.com/ilcm96/wt.git
cd wt
mkdir -p "$HOME/.local/bin"
ln -s "$PWD/wt.sh" "$HOME/.local/bin/wt"
```

Add the following to your shell configuration (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"

wt() {
  if [[ "${1:-}" == "switch" ]]; then
    shift
    local target_dir
    target_dir="$(command wt switch --print-path "$@")" || return
    cd -- "$target_dir"
  else
    command wt "$@"
  fi
}
```

Open a new terminal to start using `wt`. The function lets `wt switch` change the current shell's directory. Without it, the script only displays information about the target worktree.

## Usage

Run commands from inside a Git repository.

```bash
wt list
wt new feature/login main
wt new feature/existing
wt switch feature/login
wt rename feature/login feature/sign-in
wt sync
```

| Command                             | Description                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------- |
| `wt list`                           | Show each worktree's branch, status, and path                                |
| `wt switch <target>`                | Change to a worktree                                                         |
| `wt new <branch> [base-branch]`     | Create a worktree for an existing local branch, or create a new branch       |
| `wt track <branch> [remote]`        | Create a new local tracking branch and worktree; remote defaults to `origin` |
| `wt rename <target> <new-branch>`   | Rename the local branch without moving its directory                         |
| `wt remove [--force] <target>`      | Remove a worktree and its local branch                                       |
| `wt sync`                           | Copy matching files from the current worktree to other worktrees             |
| `wt code <target>`                  | Open in VS Code; requires the `code` command                                 |
| `wt codex <target>`                 | Open in the Codex app; macOS only                                            |
| `wt -h` / `wt -v`                   | Show help / version                                                          |

A `<target>` can be a branch name, a worktree directory name, or a full path.

`wt new feature/existing` uses the existing local branch and preserves its commits. If the branch does not exist, `wt new` creates it from the current branch or the supplied base branch. A base branch cannot be supplied for an existing branch, and a branch already checked out in another worktree must be switched away from first.

New worktrees are created next to the main repository as `<repo>-<branch>`. Characters outside `A–Z`, `a–z`, `0–9`, `.`, `_`, and `-` are replaced with `-`. For example, `feature/login` in `my-app` becomes `my-app-feature-login`.

`remove` deletes the local branch even if it has not been merged. `--force` also allows removing a worktree with modified or untracked files. The current and main worktrees cannot be removed.

## File sync settings

Edit the arrays at the top of `wt.sh`:

```bash
SYNC_FILE_PATTERNS=(
  '.env'
  '.env.*'
  'AGENTS.override.md'
  'secret.yaml'
)
```

`new` and `track` copy files to the newly created worktree. `sync` copies them to all other worktrees.

- Matches file names recursively and preserves relative paths.
- Overwrites existing files at the same path. Files missing from the source are not deleted from the destination.
- Skips files whose relative paths contain `sample`, regardless of case.
- Skips directories listed in `SYNC_EXCLUDE_DIRS` at any depth.

The exclusion list includes `.git`, `node_modules`, `.venv`, `.gradle`, `target`, and `build`, among others. Adjust it for your project. Run `wt -h` to see the current settings.

## Completion

Add the appropriate snippet to your shell configuration:

```bash
# Zsh: skip the first line if compinit is already configured.
autoload -Uz compinit && compinit
eval "$(wt completion zsh)"
```

```bash
# Bash 4 or later
eval "$(wt completion bash)"
```

## License

[MIT](LICENSE)
