#!/usr/bin/env bash
set -euo pipefail

PKGNAME=${PKGNAME:?PKGNAME is required}
UPDATE_METADATA=${UPDATE_METADATA:-false}
HOST_UID=${HOST_UID:-0}
HOST_GID=${HOST_GID:-0}
WORKSPACE=${WORKSPACE:-/workspace}

SRCDIR=$WORKSPACE/$PKGNAME
BUILDDIR=/home/builder/pkg

if [ "$(id -u)" -eq 0 ]; then
	SUDO=()
else
	SUDO=(sudo)
fi

echo "::group::Installing build tooling"
# sandbox does not work inside a container, so disable it
if ! grep -qx 'DisableSandboxFilesystem' /etc/pacman.conf; then
	if grep -q '^#DisableSandboxFilesystem' /etc/pacman.conf; then
		sed -i 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' /etc/pacman.conf
	else
		sed -i '/^\[options\]/a DisableSandboxFilesystem' /etc/pacman.conf
	fi
fi
pkgs=(base-devel git sudo)
if [ "$UPDATE_METADATA" = true ]; then
	# updpkgsums
	pkgs+=(pacman-contrib)
fi
"${SUDO[@]}" pacman -Syu --noconfirm --needed "${pkgs[@]}"
echo "::endgroup::"

echo "::group::Adding unprivileged user"
id -u builder >/dev/null 2>&1 || useradd -m builder
mkdir -p /etc/sudoers.d
echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder
echo "::endgroup::"

echo "::group::Staging package"
# build in a temp copy
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
cp -a "$SRCDIR"/. "$BUILDDIR"/
chown -R builder "$BUILDDIR"
echo "::endgroup::"

if [ "$UPDATE_METADATA" = true ]; then
	echo "::group::Checking if pkgrel should be reset because of version bump"
	git config --global --add safe.directory "$WORKSPACE" >/dev/null 2>&1 || true
	old_pkgver=''
	if [ -z "${BASE_SHA:-}" ]; then
		echo "no usable base commit, skipping pkgver comparison"
	elif base_pkgbuild=$(git -C "$WORKSPACE" show "${BASE_SHA}:${PKGNAME}/PKGBUILD" 2>/dev/null); then
		old_pkgver=$(printf '%s\n' "$base_pkgbuild" | grep -oP '^pkgver=\K\S+' || true)
	else
		echo "::warning::base commit ${BASE_SHA} is not available locally, so a pkgver change cannot be detected"
	fi

	new_pkgver=$(grep -oP '^pkgver=\K\S+' "$BUILDDIR/PKGBUILD" || true)
	echo "old pkgver: '${old_pkgver}'"
	echo "new pkgver: '${new_pkgver}'"
	if [ -n "$old_pkgver" ] && [ -n "$new_pkgver" ] && [ "$old_pkgver" != "$new_pkgver" ]; then
		echo "pkgver changed, resetting pkgrel to 1"
		sed -i 's/^pkgrel=.*/pkgrel=1/' "$BUILDDIR/PKGBUILD"
	fi
	echo "::endgroup::"

	echo "::group::Updating checksums"
	chown builder "$BUILDDIR/PKGBUILD"
	su builder -c "cd $BUILDDIR && updpkgsums"
	echo "::endgroup::"
fi

echo "::group::Building package"
su builder -c "cd $BUILDDIR && makepkg -s -f --noconfirm"
echo "::endgroup::"

main_pkg=$(find "$BUILDDIR" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*-debug-*' ! -name '*.sig' -print -quit)
[ -n "$main_pkg" ] || {
	echo "::error::no package produced in $BUILDDIR"
	ls -1 "$BUILDDIR"
	exit 1
}

echo "::group::Verifying package architecture"
arch=$(bsdtar -xOf "$main_pkg" .PKGINFO | sed -n 's/^arch = //p' | sort -u)
expected=$(uname -m)
echo "built for: $arch (expected $expected)"
[ "$arch" = "$expected" ] || {
	echo "::error::expected $expected, got $arch"
	exit 1
}
echo "::endgroup::"

echo "::group::Installing built package"
"${SUDO[@]}" pacman -U --noconfirm "$main_pkg"
echo "::endgroup::"

if [ "$UPDATE_METADATA" = true ]; then
	echo "::group::Writing regenerated metadata back to the workspace"
	su builder -c "cd $BUILDDIR && makepkg --printsrcinfo" >"$BUILDDIR/.SRCINFO"
	install -o "$HOST_UID" -g "$HOST_GID" -m644 "$BUILDDIR/PKGBUILD" "$SRCDIR/PKGBUILD"
	install -o "$HOST_UID" -g "$HOST_GID" -m644 "$BUILDDIR/.SRCINFO" "$SRCDIR/.SRCINFO"
	echo "::endgroup::"
fi
