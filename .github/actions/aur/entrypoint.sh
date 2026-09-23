#!/usr/bin/env bash
set -euo pipefail

echo "::group::Updating"
sudo pacman -Syu --noconfirm
echo "::endgroup::"

# Set path
WORKPATH=$GITHUB_WORKSPACE/$INPUT_PKGNAME
HOME=/home/builder
echo "::group::Copying files from $WORKPATH to $HOME/gh-action"
# Set path permision
cd $HOME
mkdir gh-action
cd gh-action
cp -rfv "$GITHUB_WORKSPACE"/.git ./
cp -fv "$WORKPATH"/* .
echo "::endgroup::"

echo "::group::Updating archlinux-keyring"
sudo pacman -S --noconfirm archlinux-keyring
echo "::endgroup::"

echo "::group::Updating checksums on PKGBUILD"
updpkgsums
git diff PKGBUILD
echo "::endgroup::"

echo "::group::Resetting pkgrel on version bump"
old_pkgver=$(git show HEAD^:"$INPUT_PKGNAME"/PKGBUILD 2>/dev/null | grep -oP '^pkgver=\K.*' || true)
new_pkgver=$(grep -oP '^pkgver=\K.*' PKGBUILD || true)
echo "old pkgver: '${old_pkgver}'"
echo "new pkgver: '${new_pkgver}'"
if [ -n "$old_pkgver" ] && [ -n "$new_pkgver" ] && [ "$old_pkgver" != "$new_pkgver" ]; then
  echo "pkgver changed, resetting pkgrel to 1"
  sed -i 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
fi
git diff PKGBUILD
echo "::endgroup::"

echo "::group::Installing depends using paru"
source PKGBUILD
paru -Syu --removemake --needed --noconfirm "${depends[@]:-}" "${makedepends[@]:-}"
echo "::endgroup::"

echo "::group::Running makepkg"
makepkg
echo "::endgroup::"

echo "::group::Installing built package"
sudo pacman -U --noconfirm ./*.pkg.tar.zst
goat --help >/dev/null
echo "::endgroup::"

echo "::group::Generating new .SRCINFO based on PKGBUILD"
makepkg --printsrcinfo >.SRCINFO
git diff .SRCINFO
echo "::endgroup::"

echo "::group::Copying files from $HOME/gh-action to $WORKPATH"
sudo cp -fv PKGBUILD "$WORKPATH"/PKGBUILD
sudo cp -fv .SRCINFO "$WORKPATH"/.SRCINFO
echo "::endgroup::"
