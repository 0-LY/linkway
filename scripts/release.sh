#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
export IDENTITY_RELEASE=1
source "$root/scripts/identity.sh"
if missing="$(identity_placeholders)"; then
  print "Set these in identity.env before releasing:"
  print -r -- "$missing" | sed 's/^/  - /'
  print "Then run scripts/apply-identity.sh, commit, and release again."
  exit 1
fi
security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1 \
  || { print "Signing certificate '$SIGN_IDENTITY' not found. Run scripts/make-cert.sh first."; exit 1; }
"$root/scripts/apply-identity.sh" --check \
  || { print "README/LICENSE/SECURITY.md are out of date with identity.env. Run scripts/apply-identity.sh and commit."; exit 1; }
app_name="$APP_NAME"
zip_base="$ZIP_BASE"
slug="$GITHUB_OWNER/$GITHUB_REPO"
account="$SPARKLE_ACCOUNT"
sparkle_bin="$root/vendor/Sparkle/bin"
remote="${RELEASE_REMOTE:-origin}"

usage() {
  print "usage: scripts/release.sh stable|beta [--version X.Y.Z] [--notes TEXT] [--publish]"
  print "       test only: [--allow-any-branch] [--allow-dirty]"
}

channel="${1:-}"
(( $# )) && shift
publish=0
allow_branch=0
allow_dirty=0
new_version=""
notes=""
while (( $# )); do
  case "$1" in
    --publish) publish=1 ;;
    --allow-any-branch) allow_branch=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    --version) new_version="$2"; shift ;;
    --notes) notes="$2"; shift ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[[ "$channel" == stable || "$channel" == beta ]] || { usage; exit 2; }
(( publish && (allow_branch || allow_dirty) )) && { print "--publish can't be combined with --allow-*"; exit 1; }

want=main
[[ "$channel" == beta ]] && want=beta
if [[ -n "$(git -C "$root" status --porcelain)" ]] && (( ! allow_dirty )); then
  print "The working tree has uncommitted changes."
  exit 1
fi
if (( ! allow_branch )); then
  git -C "$root" fetch -q "$remote" "$want" \
    || { print "Can't fetch '$want' from '$remote'. Run scripts/publish.sh $want first."; exit 1; }
  if [[ "$(git -C "$root" rev-parse 'HEAD^{tree}')" != "$(git -C "$root" rev-parse "$remote/$want^{tree}")" ]]; then
    print "Your checkout doesn't match $remote/$want. Run scripts/publish.sh $want first, then release."
    exit 1
  fi
fi

"$root/scripts/fetch-sparkle.sh"
source "$root/version.env"
version="${new_version:-$VERSION}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print "Bad version: $version"; exit 1; }

dist="$root/dist"
mkdir -p "$dist"
current="$dist/current-appcast.xml"
rm -f "$current"
stable_tag=""
if stable_tag="$(gh release view --repo "$slug" --json tagName --jq .tagName 2>/dev/null)" && [[ -n "$stable_tag" ]]; then
  gh release download "$stable_tag" --repo "$slug" --pattern appcast.xml --output "$current" --clobber 2>/dev/null || true
else
  stable_tag=""
fi
if [[ "$channel" == beta && -z "$stable_tag" ]] && (( publish )); then
  print "A beta needs a stable release first: its appcast.xml is the update feed. Release stable first."
  exit 1
fi
[[ -s "$current" ]] || cp "$root/docs/appcast.xml" "$current"
last="$(python3 -I - "$current" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
nums = [int(n) for n in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", xml)]
print(max(nums) if nums else 0)
PY
)"
build=$(( (last > BUILD ? last : BUILD) + 1 ))
if [[ "$channel" == stable ]]; then tag="v$version"; title="$app_name $version"; else tag="v$version-beta.$build"; title="$app_name $version beta $build"; fi
if (( publish )) && gh release view "$tag" --repo "$slug" >/dev/null 2>&1; then
  print "Release $tag already exists."
  exit 1
fi

work="$dist/$tag"
rm -rf "$work"
mkdir -p "$work/feed"
RELEASE_VERSION="$version" RELEASE_BUILD="$build" "$root/scripts/build-app.sh" >/dev/null
zip="$work/$zip_base-$version-$build.zip"
ditto -c -k --keepParent "$root/build/$app_name.app" "$zip"
cp "$zip" "$work/feed/"
cp "$current" "$work/feed/appcast.xml"
[[ -n "$notes" ]] && print -r -- "$notes" > "$work/feed/$zip_base-$version-$build.md"
channel_args=()
[[ "$channel" == beta ]] && channel_args=(--channel beta)
rm -rf "$HOME/Library/Caches/Sparkle_generate_appcast"
"$sparkle_bin/generate_appcast" --account "$account" \
  --download-url-prefix "https://github.com/$slug/releases/download/$tag/" \
  --link "$REPO_URL" --maximum-deltas 0 --maximum-versions 0 --embed-release-notes \
  "${channel_args[@]}" "$work/feed" >/dev/null
cp "$work/feed/appcast.xml" "$work/appcast.xml"

signature="$(python3 -I - "$work/appcast.xml" "$build" <<'PY'
import re, sys
xml = open(sys.argv[1]).read()
for item in re.findall(r"<item>.*?</item>", xml, re.S):
    if f"<sparkle:version>{sys.argv[2]}</sparkle:version>" in item:
        m = re.search(r'sparkle:edSignature="([^"]+)"', item)
        print(m.group(1) if m else "")
PY
)"
[[ -n "$signature" ]] || { print "The new appcast item is not signed."; exit 1; }
public_key="$(defaults read "$root/build/$app_name.app/Contents/Info.plist" SUPublicEDKey)"
swift "$root/scripts/verify-update.swift" "$public_key" "$zip" "$signature" \
  || { print "The update signature does not match the app's public key."; exit 1; }
codesign --verify --deep --strict "$root/build/$app_name.app"

print "Built   $zip"
print "Version $version (build $build), channel $channel, tag $tag"
print "Appcast $work/appcast.xml (EdDSA signature verified)"
stable_zip="$work/$zip_base.zip"
cp "$zip" "$stable_zip"
release_args=("$tag" --repo "$slug" --target "$want" --title "$title")
if [[ "$channel" == stable ]]; then
  release_args+=("$zip" "$stable_zip" "$work/appcast.xml" --latest)
else
  release_args+=("$zip" --prerelease)
fi
if [[ -n "$notes" ]]; then release_args+=(--notes "$notes"); else release_args+=(--generate-notes); fi

if (( ! publish )); then
  print ""
  print "Dry run. With --publish this would:"
  print -r -- "  gh release create ${(j: :)${(qq)release_args[@]}}"
  [[ "$channel" == beta ]] && print -r -- "  gh release upload ${stable_tag:-<latest stable tag>} $work/appcast.xml --repo $slug --clobber"
  exit 0
fi

gh release create "${release_args[@]}"
if [[ "$channel" == beta ]]; then
  gh release upload "$stable_tag" "$work/appcast.xml" --repo "$slug" --clobber
fi
print "Published $tag"
print "Feed    $FEED_URL"
