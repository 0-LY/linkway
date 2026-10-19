#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
"$root/scripts/apply-identity.sh"
"$root/build.sh"
source "$root/scripts/identity.sh"
print ""
print -r -- "Now $APP_NAME ($BUNDLE_ID), published by $PUBLISHER at $REPO_URL."
print "Review and commit README.md, LICENSE, SECURITY.md and identity.env."
if missing="$(IDENTITY_RELEASE=1 zsh -fc 'source "$1/scripts/identity.sh"; identity_placeholders' _ "$root")"; then
  print "Still placeholders in identity.env (releases are blocked until set):"
  print -r -- "$missing" | sed 's/^/  - /'
fi
