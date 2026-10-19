#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
remote="${PUBLISH_REMOTE:-origin}"
branch="${1:-}"
message="${2:-}"
[[ "$branch" == main || "$branch" == beta ]] || { print "usage: scripts/publish.sh main|beta [message]"; exit 2; }
cd "$root"
[[ -z "$(git status --porcelain)" ]] || { print "Commit your work first (the working tree has changes)."; exit 1; }
scripts/apply-identity.sh --check || { print "Run scripts/apply-identity.sh and commit first."; exit 1; }
git fetch -q "$remote"
login="$(gh api user --jq .login)"
uid="$(gh api user --jq .id)"
export GIT_AUTHOR_NAME="$login" GIT_COMMITTER_NAME="$login"
export GIT_AUTHOR_EMAIL="$uid+$login@users.noreply.github.com" GIT_COMMITTER_EMAIL="$uid+$login@users.noreply.github.com"
tree="$(git rev-parse 'HEAD^{tree}')"
if git rev-parse -q --verify "$remote/$branch" >/dev/null; then
  parent="$remote/$branch"
  if [[ "$(git rev-parse "$parent^{tree}")" == "$tree" ]]; then
    print "$remote/$branch already matches this checkout."
    exit 0
  fi
  [[ -n "$message" ]] || message="Update from $(git rev-parse --short HEAD)"
  commit="$(git commit-tree "$tree" -p "$parent" -m "$message")"
else
  [[ -n "$message" ]] || message="Initial public release"
  commit="$(git commit-tree "$tree" -m "$message")"
fi
git push "$remote" "${commit}:refs/heads/${branch}"
print "Published $(git rev-parse --short "$commit") to $remote/$branch"
