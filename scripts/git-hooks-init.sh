#!/usr/bin/env bash

set -euo pipefail

if [ ! -d .git ]; then
    exit 0
fi

mkdir -p ".git/hooks"

if [ ! -L '.git/hooks/pre-push' ]; then
    ln -sf '../../scripts/git-hook-pre-push.sh' '.git/hooks/pre-push'
fi

if [ ! -L '.git/hooks/pre-commit' ]; then
    ln -sf '../../scripts/git-hook-pre-commit.sh' '.git/hooks/pre-commit'
fi
