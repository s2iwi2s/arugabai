#!/bin/bash
set -euo pipefail

# Configuration
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
WORKTREES_DIR="${WORKSPACE_DIR}/worktrees"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

echo "=== Worktree Setup ==="
echo "Worktrees dir: ${WORKTREES_DIR}"

# Load .env file if present (resolve relative to this script's directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
    echo "Loading environment from ${ENV_FILE}"
    set -a
    source "${ENV_FILE}"
    set +a
fi

# Discover all UPSTREAM_REPO_<NAME> environment variables.
# Format: UPSTREAM_REPO_<NAME>=<git-url>[#<branch>]
# e.g.    UPSTREAM_REPO_MYPROJECT=https://github.com/org/repo#develop
repos=()
while IFS='=' read -r key value; do
    if [[ "${key}" =~ ^UPSTREAM_REPO_(.+)$ ]]; then
        name="${BASH_REMATCH[1],,}"  # lowercase the name
        repos+=("${name}=${value}")
    fi
done < <(env)

if [ ${#repos[@]} -eq 0 ]; then
    echo "WARNING: No UPSTREAM_REPO_<NAME> variables found."
    echo "Set one or more environment variables like:"
    echo "  UPSTREAM_REPO_MYPROJECT=https://github.com/org/repo"
    echo "Skipping worktree setup."
    exit 0
fi

echo "Found ${#repos[@]} upstream repo(s):"
for entry in "${repos[@]}"; do
    name="${entry%%=*}"
    full_url="${entry#*=}"
    url="${full_url%%#*}"
    if [[ "${full_url}" == *"#"* ]]; then
        branch="${full_url#*#}"
    else
        branch="${DEFAULT_BRANCH}"
    fi
    echo "  ${name} -> ${url} (branch: ${branch})"
done
echo ""

# Create base directory
mkdir -p "${WORKTREES_DIR}"

# Set up each upstream repo
for entry in "${repos[@]}"; do
    name="${entry%%=*}"
    full_url="${entry#*=}"
    # Parse optional #branch fragment from URL
    url="${full_url%%#*}"
    if [[ "${full_url}" == *"#"* ]]; then
        branch="${full_url#*#}"
    else
        branch="${DEFAULT_BRANCH}"
    fi
    repo_dir="${WORKTREES_DIR}/${name}"
    bare_dir="${repo_dir}/.bare"
    worktree_dir="${repo_dir}/${branch}"

    echo "--- Setting up: ${name} ---"
    echo "  Upstream: ${url}"
    echo "  Branch: ${branch}"

    # Create repo directory
    mkdir -p "${repo_dir}"

    # Clone bare repo if not already present
    if [ ! -d "${bare_dir}" ]; then
        echo "  Cloning bare repo..."
        git clone --bare "${url}" "${bare_dir}"

        cd "${bare_dir}"
        git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git fetch origin
    else
        echo "  Bare repo exists, fetching latest..."
        cd "${bare_dir}"
        git fetch origin --prune
    fi

    # Create worktree for the repo's branch if not present
    if [ ! -d "${worktree_dir}" ]; then
        echo "  Creating worktree for ${branch}..."
        git worktree add "${worktree_dir}" "${branch}"
    else
        echo "  Worktree already exists."
    fi

    echo ""
done

echo "=== Setup Complete ==="
echo ""
for entry in "${repos[@]}"; do
    name="${entry%%=*}"
    full_url="${entry#*=}"
    if [[ "${full_url}" == *"#"* ]]; then
        branch="${full_url#*#}"
    else
        branch="${DEFAULT_BRANCH}"
    fi
    echo "  ${name}: ${WORKTREES_DIR}/${name}/${branch}"
done
echo ""
echo "To create a new branch worktree for a repo:"
echo "  cd ${WORKTREES_DIR}/<name>/.bare"
echo "  git worktree add ../<branch> -b <branch> origin/${DEFAULT_BRANCH}"
echo ""
echo "To remove a worktree:"
echo "  cd ${WORKTREES_DIR}/<name>/.bare"
echo "  git worktree remove ../<branch>"
