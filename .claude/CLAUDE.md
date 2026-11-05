# GitHub Worktree Workspace

## Repository Structure

This is a **workspace wrapper repo** that manages worktrees from one or more upstream GitHub repos.

- **`origin`** -> this wrapper repo (devcontainer, CLAUDE.md, worktree scripts)
- Upstream repos are configured via `UPSTREAM_REPO_<NAME>` environment variables in `.devcontainer/.env`

**CRITICAL: NEVER merge, rebase, or pull upstream remotes into this parent repo.** Upstream remotes exist only so worktrees can track upstream branches. Only `origin` commits belong in this repo's history.

- Each upstream repo gets its own folder: `worktrees/<name>/`
  - `worktrees/<name>/.bare/` -- the bare clone
  - `worktrees/<name>/<branch>/` -- worktree checkouts

## Worktree Workflow

- Worktrees are created automatically by `.devcontainer/setup-worktrees.sh` on container creation.
- **NEVER `git checkout` or `git switch` inside an existing worktree.** Each worktree folder is named for its branch and must stay on that branch. Always create a new worktree for a new branch.
- To add a new upstream repo, add `UPSTREAM_REPO_<NAME>=<url>` to `.devcontainer/.env` and re-run `.devcontainer/setup-worktrees.sh`.
- To create a feature branch worktree:
  ```
  cd worktrees/<name>/.bare
  git worktree add ../<branch> -b <branch> origin/main
  ```
- Push from the worktree directory, not the repo root.
- To fetch latest from an upstream: `cd worktrees/<name>/.bare && git fetch origin`

## GitHub Conventions

- Use the `gh` CLI (pre-installed via the `github-cli` devcontainer feature) for issues, PRs, and CI checks -- run it from inside the relevant worktree, not the wrapper repo root.
- Label anything Claude creates (issues/PRs) consistently, e.g. `ai-generated`, so it's distinguishable in the repo's history.
- Open PRs from the worktree branch against the upstream repo's default branch; never push directly to a shared default branch.
