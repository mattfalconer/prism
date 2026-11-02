#!/bin/zsh
# Ships the build that scripts/release.sh left in dist/: pushes main, makes the GitHub release (Prism.dmg for
# the website, Prism-<version>.zip for the updater) and adds it to docs/appcast.xml, which Prism checks daily.
#
#   scripts/publish.sh notes.md
#
# notes.md is plain Markdown (paragraphs and "- " bullets); it's the release's notes on GitHub and in the
# update window.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?usage: scripts/publish.sh notes.md}
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' Prism/project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION/{print $2; exit}' Prism/project.yml)
for f in dist/Prism-$VERSION.dmg dist/Prism-$VERSION.zip dist/Prism-$VERSION.sig; do
  [[ -f $f ]] || { echo "Missing $f: run scripts/release.sh first." >&2; exit 1; }
done
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first." >&2; exit 1; }

echo "▸ Pushing main"
git push -q origin HEAD:main

echo "▸ Creating release v$VERSION"
STAGE=$(mktemp -d)
cp "dist/Prism-$VERSION.dmg" "$STAGE/Prism.dmg"
gh release create "v$VERSION" "$STAGE/Prism.dmg" "dist/Prism-$VERSION.zip" --target main \
  --title "Prism $VERSION" --notes-file "$NOTES"
rm -rf "$STAGE"

echo "▸ Adding $VERSION to the update feed"
python3 -I scripts/appcast.py docs/appcast.xml "$VERSION" "$BUILD" "dist/Prism-$VERSION.sig" "$NOTES"
git add docs/appcast.xml
git commit -q -m "Offer Prism $VERSION as an update"
git push -q origin HEAD:main
echo "✓ Prism $VERSION is out: https://github.com/mattfalconer/prism/releases/tag/v$VERSION"
