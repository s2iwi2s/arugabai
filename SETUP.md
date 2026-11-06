# Setup Guide: GitHub Worktree Devcontainer

This walks through getting `arugabai_devcontainer` running end-to-end: installing the right VS
Code pieces, configuring credentials, opening the devcontainer, and verifying the worktree setup
actually materialized your repos.

## 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| **VS Code** | Hosts the Dev Containers experience | `code --version` |
| **Dev Containers extension** (`ms-vscode-remote.remote-containers`) | Builds/attaches to the devcontainer | Extensions panel → search "Dev Containers" |
| **Docker Desktop** (Mac/Windows) or **Docker Engine** (Linux) | Actually runs the container | `docker --version`, and the Docker daemon must be running |
| **Git** | Cloning, worktrees | `git --version` |
| **A GitHub account + token** | Pulling/pushing the upstream repos you'll work on | see §3 below |

**Windows-specific:** use the **WSL2 backend** for Docker Desktop, and make sure WSL integration
is enabled for your distro (Docker Desktop → Settings → Resources → WSL Integration). Cloning the
wrapper repo *inside* your WSL filesystem (e.g. `~/code/...`), not under `/mnt/c/...`, avoids slow
bind-mount I/O.

## 2. Install the VS Code pieces

1. Install VS Code: https://code.visualstudio.com/
2. Open the Extensions panel (`Ctrl+Shift+X` / `Cmd+Shift+X`) and install **Dev Containers**
   (publisher: Microsoft, id `ms-vscode-remote.remote-containers`).
3. Install Docker Desktop (Mac/Windows) from https://www.docker.com/products/docker-desktop/, or
   Docker Engine on Linux, and make sure it's running (`docker ps` should not error).

## 3. Get the wrapper repo and set your GitHub token

You have two options — pick one.

### Option A: Clone normally, then open in container

```bash
git clone https://github.com/johnperion/arugabai_devcontainer.git
code arugabai_devcontainer
```

Then in VS Code: Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`) → **Dev Containers: Reopen in
Container**. (VS Code will also pop up a "Reopen in Container" toast automatically when it detects
`.devcontainer/` in a folder you open.)

### Option B: Clone straight into a container volume (skips the local clone entirely)

Command Palette → **Dev Containers: Clone Repository in Container Volume...** → paste
`https://github.com/johnperion/arugabai_devcontainer` → pick `main`. VS Code clones the repo
*inside* a Docker volume and opens it in the container directly — nothing touches your local disk.
Good default on Windows, since it sidesteps bind-mount performance entirely.

### Set up `.devcontainer/.env`

Either way, before (or right after) the container builds, create your `.env`:

```bash
cd arugabai_devcontainer   # if using Option A
cp .devcontainer/.env.example .devcontainer/.env
```

Edit `.devcontainer/.env`:

```bash
# One line per upstream repo you want materialized as a worktree.
# NAME becomes the folder under worktrees/. Optional #branch picks the branch (default: main).
UPSTREAM_REPO_MYPROJECT=https://github.com/org/repo
UPSTREAM_REPO_OTHERPROJECT=https://github.com/org/other-repo#develop

DEFAULT_BRANCH=main

# A GitHub token with access to the repos above.
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Generating the token** (GitHub → Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token):
- **Resource owner:** the org/user that owns the repos you listed.
- **Repository access:** "Only select repositories" → pick exactly the repos in your
  `UPSTREAM_REPO_*` lines (least privilege).
- **Permissions:** `Contents: Read and write` (clone/push); add `Pull requests: Read and write` and
  `Issues: Read and write` if you want `gh pr create` / `gh issue create` to work from inside the
  container.

Save `.env` with **LF line endings**. (If you edit it on Windows and it ends up CRLF, the
devcontainer's `onCreateCommand` strips the `\r` automatically before anything sources it — but LF
from the start avoids relying on that.)

> `.env` is gitignored by this repo (see `.gitignore`) — it never gets committed, and
> `initializeCommand` in `devcontainer.json` creates an empty one automatically on first clone so
> the `--env-file` flag doesn't fail on a fresh checkout.

## 4. Build and open the container

If you haven't already: Command Palette → **Dev Containers: Reopen in Container**.

First build takes a few minutes — it's pulling the base image and installing the
`docker-in-docker`, `github-cli`, and Java 21 features. Subsequent opens are fast (image layers are
cached).

### What happens automatically on first boot

`postCreateCommand` in `devcontainer.json` runs three things in sequence:

1. `git config --global --add safe.directory ...` — needed because of how VS Code mounts the
   workspace.
2. Makes the persistent `~/.claude` volume writable by the container user, then installs the
   Claude Code CLI (`curl -fsSL https://claude.ai/install.sh | bash`).
3. `setup-git-credentials.sh` then `setup-worktrees.sh`:
   - **`setup-git-credentials.sh`** writes a git credential (`~/.git-credentials`, scoped to
     `github.com`) with your `GITHUB_TOKEN` as the password and prioritizes it over VS Code's
     system credential helper. An invalid credential from that helper otherwise prevents Git from
     trying the valid token. If no `GITHUB_TOKEN` is configured, Git continues to rely on VS Code's
     session helper.
   - **`setup-worktrees.sh`** reads every `UPSTREAM_REPO_<NAME>` variable, bare-clones each one
     into `worktrees/<name>/.bare/`, and checks out a worktree at `worktrees/<name>/<branch>/`.

Because `GITHUB_TOKEN` is injected via `runArgs: ["--env-file", ...]`, it's also present as a plain
environment variable inside every container shell — and the `gh` CLI automatically picks up
`GH_TOKEN`/`GITHUB_TOKEN` from the environment with no separate `gh auth login` needed *inside this
container*. (This is a different, container-local thing from any `gh auth login` you've done on
your host or in some other devcontainer — that session state does not carry over here.)

## 5. Verify it worked

Open the integrated terminal (`` Ctrl+` ``) inside the container:

```bash
ls worktrees/                      # one folder per UPSTREAM_REPO_<NAME>
ls worktrees/<name>/               # .bare/  and  <branch>/
cd worktrees/<name>/<branch> && git status
gh auth status                     # should show you're authenticated via GH_TOKEN
claude                             # launches Claude Code; it'll prompt its own separate login
```

If `worktrees/` is empty or missing a repo you expected: check `.env` was saved before the
container built (if you added a line *after* building, re-run `bash .devcontainer/setup-worktrees.sh`
manually — no rebuild needed), and check the terminal output from the `workspace` postCreate step
for clone errors (wrong URL, token missing repo access, etc.).

## 6. Day-to-day workflow

**Never `git checkout`/`switch` inside a worktree folder** — each one is pinned to its branch.
To work on something new, create a fresh worktree instead:

```bash
cd worktrees/<name>/.bare
git worktree add ../<branch> -b <branch> origin/main
cd ../<branch>
# ... make changes ...
git push -u origin <branch>
gh pr create
```

Always run `git push`/`gh pr create` from inside the worktree directory (`worktrees/<name>/<branch>/`),
not from the wrapper repo root — the wrapper repo's own `origin` is `arugabai_devcontainer` itself,
not your upstream project.

**Adding another upstream repo later:**

```bash
# add to .devcontainer/.env
UPSTREAM_REPO_SOMETHINGELSE=https://github.com/org/something-else
```

```bash
bash .devcontainer/setup-worktrees.sh   # re-run, no rebuild needed
```

**Removing a worktree:**

```bash
cd worktrees/<name>/.bare
git worktree remove ../<branch>
```

## 7. Customizing for your stack

`devcontainer.json` ships deliberately minimal (generic Ubuntu base + `docker-in-docker` +
`github-cli`). Add what your projects need under `"features"`, e.g.:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/docker-in-docker:2": {},
  "ghcr.io/devcontainers/features/github-cli:1": {},
  "ghcr.io/devcontainers/features/java:1": { "version": "21" },
  "ghcr.io/devcontainers/features/node:1": { "version": "24" },
  "ghcr.io/devcontainers/features/dotnet:2": { "version": "10.0" },
  "ghcr.io/devcontainers/features/python:1": {}
}
```

After editing `devcontainer.json`, Command Palette → **Dev Containers: Rebuild Container**. The API
worktree requires Java 21; after the rebuild, `java -version` should report version 21 and
`JAVA_HOME` should point to the installed JDK.

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `--env-file` error on container start | `.env` missing — shouldn't happen (`initializeCommand` creates it), but if it does: `touch .devcontainer/.env` on the host and rebuild. |
| `$'\r': command not found` during setup | A CRLF `.env` wasn't normalized in time — re-save it with LF endings and rebuild. |
| `fatal: could not read Username for 'https://github.com'` from a background process | `GITHUB_TOKEN` wasn't set when the container first booted, so `setup-git-credentials.sh` skipped the fallback. Set it in `.env` and either re-run `bash .devcontainer/setup-git-credentials.sh` or rebuild. |
| `worktrees/` is empty, script says "No UPSTREAM_REPO_<NAME> variables found" | `.env` has no `UPSTREAM_REPO_*` lines, or they were added after the container booted without a re-run. |
| `gh auth status` fails inside the container | `GITHUB_TOKEN` not set in `.env`, or the token's expired/revoked. `gh` reads it straight from the environment — no login flow needed here if the token is valid. |
| Clone fails with 403/404 for an `UPSTREAM_REPO_*` URL | Token's fine-grained repo-access list doesn't include that repo, or `Contents` permission isn't set to read/write. |
| Container build is slow every time | Make sure Docker's build cache isn't being cleared between opens (e.g. `docker system prune` elsewhere) — normal rebuilds should reuse cached layers. |

## Reference: directory layout

```
arugabai_devcontainer/            <- wrapper repo (this repo's "origin")
├── .devcontainer/
│   ├── devcontainer.json
│   ├── setup-worktrees.sh
│   ├── setup-git-credentials.sh
│   ├── .env                      <- you create this, gitignored
│   └── .env.example
├── .claude/CLAUDE.md
├── README.md
├── SETUP.md                      <- this file
└── worktrees/                    <- created at container boot, one folder per upstream repo
    └── <name>/
        ├── .bare/                <- bare clone
        └── <branch>/             <- your working checkout
```
