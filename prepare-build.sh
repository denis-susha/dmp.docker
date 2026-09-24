#!/usr/bin/env bash
# Makes sure every repository used as a build context by the compose files is checked out
# next to this one (../dmp.api.web, ../dmp.client, ...). Missing ones are cloned from GitHub;
# existing checkouts are left untouched.
#
# Usage: ./prepare-build.sh [--pull]
#   --pull   also fast-forward existing checkouts to their upstream branch
set -euo pipefail

GITHUB_BASE="${GITHUB_BASE:-https://github.com/denis-susha}"
REPOS=(
    dmp.api.web
    dmp.job.invoiceworker
    dmp.job.trxworker
    dmp.job.server
    dmp.client
    dmp.seller
)

pull=false
[[ "${1:-}" == "--pull" ]] && pull=true

parent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for repo in "${REPOS[@]}"; do
    target="$parent_dir/$repo"
    if [[ -d "$target" ]]; then
        if $pull && [[ -d "$target/.git" ]]; then
            echo "Updating $repo"
            git -C "$target" pull --ff-only
        else
            echo "Found    $repo"
        fi
    else
        echo "Cloning  $repo"
        git clone "$GITHUB_BASE/$repo.git" "$target"
    fi
done
