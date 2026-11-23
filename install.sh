#!/bin/bash
# Download/update Photo Index and run it. The raw GitHub base URL is argument 1.

set -u
umask 077

raw_base=${1:-}
if [ "$raw_base" = "" ]; then
  printf 'The installation address is missing. Copy the complete command from the Photo Index README.\n' >&2
  exit 1
fi
raw_base=${raw_base%/}

command -v curl >/dev/null 2>&1 || {
  printf 'This Mac does not have curl. Ask your Mac administrator for help.\n' >&2
  exit 1
}
command -v perl >/dev/null 2>&1 || {
  printf 'This Mac does not have Perl, which Photo Index needs. Ask your Mac administrator for help.\n' >&2
  exit 1
}

install_dir="$HOME/photo-index-tool"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/photo-index-install.XXXXXXXX") || {
  printf 'Could not create a temporary download folder. Check free disk space and try again.\n' >&2
  exit 1
}
cleanup() { rm -rf "$staging_dir"; }
trap cleanup EXIT

printf 'Downloading Photo Index...\n'
for file in photo-index.sh photo-index-format.pl; do
  if ! curl --fail --location --silent --show-error \
    --connect-timeout 20 --retry 2 "$raw_base/$file" --output "$staging_dir/$file"; then
    printf '\nCould not download %s.\nCheck the internet connection and the GitHub address, then try again.\n' "$file" >&2
    exit 1
  fi
  [ -s "$staging_dir/$file" ] || {
    printf 'The downloaded file %s was empty. Nothing was installed.\n' "$file" >&2
    exit 1
  }
done

if ! bash -n "$staging_dir/photo-index.sh"; then
  printf 'The downloaded scanner did not pass its safety check. The working version was not changed.\n' >&2
  exit 1
fi
if ! perl -c "$staging_dir/photo-index-format.pl" >/dev/null 2>&1; then
  printf 'The downloaded formatter did not pass its safety check. The working version was not changed.\n' >&2
  exit 1
fi

mkdir -p "$install_dir/releases" || {
  printf 'Could not create %s. Check folder permissions and try again.\n' "$install_dir" >&2
  exit 1
}

release_name="release-$(date +%Y%m%d-%H%M%S)-$$"
release_dir="$install_dir/releases/$release_name"
mkdir "$release_dir" || {
  printf 'Could not prepare the new Photo Index version. The working version was not changed.\n' >&2
  exit 1
}
for file in photo-index.sh photo-index-format.pl; do
  mv "$staging_dir/$file" "$release_dir/$file" || {
    printf 'Could not prepare %s. The previous version is still available.\n' "$file" >&2
    exit 1
  }
done
chmod u+x "$release_dir/photo-index.sh" "$release_dir/photo-index-format.pl" 2>/dev/null || true

launcher_tmp="$staging_dir/photo-index-launcher.sh"
cat > "$launcher_tmp" <<'LAUNCHER'
#!/bin/bash
export PHOTO_INDEX_CACHE_DIR="$HOME/photo-index-tool/.photo-index-cache"
exec bash "$HOME/photo-index-tool/current/photo-index.sh" "$@"
LAUNCHER
bash -n "$launcher_tmp" || {
  printf 'Could not prepare the Photo Index launcher. The working version was not changed.\n' >&2
  exit 1
}

next_link="$install_dir/.current.$$"
ln -s "releases/$release_name" "$next_link" || {
  printf 'Could not prepare the Photo Index update. The working version was not changed.\n' >&2
  exit 1
}
mv -f -h "$next_link" "$install_dir/current" || {
  printf 'Could not activate the Photo Index update. The previous version is still available.\n' >&2
  exit 1
}
mv "$launcher_tmp" "$install_dir/photo-index.sh" || {
  printf 'The update was installed, but its launcher could not be saved. Ask the tool maintainer for help.\n' >&2
  exit 1
}
chmod u+x "$install_dir/photo-index.sh" 2>/dev/null || true

printf 'Photo Index is ready.\n\n'
if [ "${PHOTO_INDEX_INSTALL_ONLY:-0}" = "1" ]; then
  exit 0
fi
bash "$install_dir/photo-index.sh"
