#!/bin/zsh
# Publishes Flick VERSION as a GitHub Release with the notarized app attached.
#
#   ./release.sh VERSION        e.g. ./release.sh 0.2.0
#
# Sets CFBundleShortVersionString to VERSION and bumps CFBundleVersion, commits
# that, builds and notarizes with ./build.sh --release, and only then tags
# vVERSION, pushes the commit and tag, and creates the release with
# build/Flick-VERSION.zip and notes generated from the commits since the last
# release. A failed build leaves just the unpushed bump commit to fix or drop.
# Last, it starts the Homebrew tap's bump workflow so the cask follows the
# release now rather than at the tap's next daily check.
set -euo pipefail
cd ${0:A:h}

if (( $# != 1 )) || [[ $1 != <->.<->.<-> ]]; then
    print -u2 "usage: ./release.sh VERSION   (MAJOR.MINOR.PATCH)"
    exit 2
fi
version=$1 tag=v$1
plist=Resources/Info.plist

if [[ $(git branch --show-current) != main ]]; then
    print -u2 "error: release from main"
    exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
    print -u2 "error: the tree has uncommitted changes"
    exit 1
fi
if git rev-parse -q --verify refs/tags/$tag >/dev/null; then
    print -u2 "error: $tag already exists"
    exit 1
fi
git fetch -q origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
    print -u2 "error: main is behind origin/main; pull first"
    exit 1
fi

build=$(plutil -extract CFBundleVersion raw $plist)
plutil -replace CFBundleShortVersionString -string $version $plist
plutil -replace CFBundleVersion -string $(( build + 1 )) $plist
git commit -q -m "chore: release $tag" -- $plist

./build.sh --release

git tag -a $tag -m "Flick $version"
git push origin main $tag
gh release create $tag build/Flick-$version.zip --title "Flick $version" --generate-notes
gh workflow run bump-flick.yml -R junzh0u/homebrew-tap
