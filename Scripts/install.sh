#!/bin/sh
set -eu

repository=eastriverlee/julia.swift
version=
install_root=${XDG_DATA_HOME:-"$HOME/.local/share"}/julia.swift
command_directory=${XDG_BIN_HOME:-"$HOME/.local/bin"}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --install-root) install_root=$2; shift 2 ;;
        --bin-dir) command_directory=$2; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

for command in curl unzip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

operating_system=$(uname -s)
architecture=$(uname -m)
case "$operating_system:$architecture" in
    Darwin:arm64) platform=macos-arm64 ;;
    Linux:x86_64|Linux:amd64) platform=linux-x86_64 ;;
    *) printf 'Unsupported platform: %s %s\n' "$operating_system" "$architecture" >&2; exit 1 ;;
esac

if [ -z "$version" ]; then
    version=$(curl -fsSL "https://api.github.com/repos/$repository/releases/latest" \
        | sed -n 's/^[[:space:]]*"tag_name": "\(v[^"]*\)".*/\1/p' | head -n 1)
fi
if [ -z "$version" ]; then
    printf 'Could not find the latest release.\n' >&2
    exit 1
fi
archive_name=julia-$version-$platform.zip
installation=$install_root/$version/$platform
mkdir -p "$install_root" "$command_directory"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/julia-install.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

release_url=https://github.com/$repository/releases/download/$version
curl -fL --retry 3 "$release_url/SHA256SUMS" -o "$temporary/SHA256SUMS"
model_name=$(awk '$2 ~ /^julia-1-model-[[:alnum:]]+\.zip$/ { print $2 }' "$temporary/SHA256SUMS" | head -n 1)
if [ -z "$model_name" ]; then
    printf 'Model asset is missing from %s\n' "$version" >&2
    exit 1
fi
curl -fL --retry 3 "$release_url/$archive_name" -o "$temporary/$archive_name"
model_archive=$temporary/$model_name
curl -fL --retry 3 "$release_url/$model_name" -o "$model_archive"

verify_checksum() {
    archive=$1
    expected=$(awk -v name="$(basename "$archive")" '$2 == name { print $1 }' "$temporary/SHA256SUMS")
    if [ -z "$expected" ]; then
        printf 'Checksum is missing for %s\n' "$archive" >&2
        exit 1
    fi
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
    else
        actual=$(sha256sum "$archive" | awk '{ print $1 }')
    fi
    if [ "$actual" != "$expected" ]; then
        printf 'Checksum mismatch for %s\n' "$archive" >&2
        exit 1
    fi
}

verify_checksum "$temporary/$archive_name"
verify_checksum "$model_archive"
unzip -q "$temporary/$archive_name" -d "$temporary/unpacked"
package_root=$temporary/unpacked/julia-$version-$platform
unzip -q "$model_archive" -d "$package_root"
chmod +x "$package_root/julia" "$package_root/bin/julia"

if [ ! -d "$installation" ]; then
    mkdir -p "$(dirname "$installation")"
    mv "$package_root" "$installation"
fi

launcher=$command_directory/julia
printf '#!/bin/sh\nexec "%s/julia" "$@"\n' "$installation" > "$temporary/launcher"
chmod +x "$temporary/launcher"
mv "$temporary/launcher" "$launcher"
printf 'Installed Julia %s to %s\n' "$version" "$installation"
printf 'Command: %s\n' "$launcher"
case ":$PATH:" in
    *":$command_directory:"*) ;;
    *) printf 'Add this directory to PATH: %s\n' "$command_directory" ;;
esac
