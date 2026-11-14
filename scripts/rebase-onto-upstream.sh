#!/bin/sh
# Rebase the local topic branch onto the upstream default branch.
#
# Usage: scripts/rebase-onto-upstream.sh [branch]
#
# The upstream remote defaults to "upstream" and can be overridden with
# $UPSTREAM_REMOTE.  This script never pushes; it only moves the local
# branch.  Push the result to the fork's "origin" remote yourself.

set -eu

upstream=${UPSTREAM_REMOTE:-upstream}
branch=${1:-$(git rev-parse --abbrev-ref HEAD)}

git fetch --prune "$upstream"

default=$(git ls-remote --symref "$upstream" HEAD |
	sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p')
if [ -z "$default" ]; then
	echo "rebase-onto-upstream: cannot determine $upstream default branch" >&2
	exit 1
fi

echo "rebase-onto-upstream: rebasing $branch onto $upstream/$default" >&2
git checkout "$branch"
git rebase "$upstream/$default"
