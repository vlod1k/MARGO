#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app="$root/apps/margo_flutter"
packaging="$root/packaging/flatpak"
id=io.github.vlod1k.MARGO
arch=x86_64
version=$(sed -nE 's/^version:[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)$/\1/p' "$app/pubspec.yaml")

if [[ $(uname -m) != "$arch" || -z "$version" ]]; then
  echo "Expected an x86_64 build host and a version in pubspec.yaml." >&2
  exit 1
fi

for tool in flatpak flatpak-builder; do
  if ! command -v "$tool" >/dev/null; then
    echo "Install $tool before building MARGO." >&2
    exit 1
  fi
done

mkdir -p "$root/dist" "$root/build/flatpak"
work=$(mktemp -d "$root/build/flatpak/package.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/app" "$work/metadata"

# Stage only Flutter inputs so an existing host build cannot change the package.
cp "$app/"{pubspec.yaml,pubspec.lock,analysis_options.yaml,.metadata} "$work/app/"
cp -R "$app/"{lib,test} "$work/app/"
tar -C "$app" --exclude=linux/flutter/ephemeral -cf - linux |
  tar -C "$work/app" -xf -
cp "$packaging/"{margo,"$id.desktop","$id.metainfo.xml"} "$work/metadata/"
cp "$packaging/$id.yml" "$work/"
cp "$packaging/icon.png" "$work/metadata/"

flatpak-builder --user --disable-rofiles-fuse --arch="$arch" --default-branch=stable \
  --state-dir="$root/build/flatpak/cache" --repo="$work/repo" \
  "$work/output" "$work/$id.yml"

bundle="MARGO-$version-$arch.flatpak"
flatpak build-bundle --arch="$arch" \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  "$work/repo" "$work/$bundle" "$id" stable
mv -- "$work/$bundle" "$root/dist/$bundle"
printf '%s\n' "$root/dist/$bundle"
