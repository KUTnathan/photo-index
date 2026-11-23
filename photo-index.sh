#!/bin/bash
# Build a searchable CSV from metadata embedded in local photo files on macOS.
# Usage: bash photo-index.sh [PHOTO_FOLDER] [OUTPUT.csv]

set -u
umask 077

TOOL_NAME="Photo Index"
EXIFTOOL_COMMIT="3d7a0538324e9b04aa8930201b007009491321d2"
EXIFTOOL_SHA256="1c890a0324d5ad5aae6e17c1b57c620e420d2846fcfa17bbf34407a5441efbbd"
EXIFTOOL_URL="https://codeload.github.com/exiftool/exiftool/tar.gz/$EXIFTOOL_COMMIT"

partial_csv=""
metadata_json=""
raw_messages=""
scan_pid=""
download_dir=""
used_folder_chooser=0
output_lock=""
cache_setup_lock=""
messages_dir=""
messages_pipe=""
progress_reader_pid=""

say() { printf '%s\n' "$*"; }

fail() {
  printf '\n%s could not finish.\n%s\n' "$TOOL_NAME" "$1" >&2
  if [ "${2:-}" != "" ]; then
    printf '\nWhat to do next:\n%s\n' "$2" >&2
  fi
  exit 1
}

cleanup() {
  [ "$partial_csv" = "" ] || rm -f "$partial_csv"
  [ "$metadata_json" = "" ] || rm -f "$metadata_json"
  [ "$raw_messages" = "" ] || rm -f "$raw_messages"
  [ "$download_dir" = "" ] || rm -rf "$download_dir"
  [ "$output_lock" = "" ] || rmdir "$output_lock" 2>/dev/null || true
  [ "$cache_setup_lock" = "" ] || rmdir "$cache_setup_lock" 2>/dev/null || true
  [ "$messages_pipe" = "" ] || rm -f "$messages_pipe"
  [ "$messages_dir" = "" ] || rmdir "$messages_dir" 2>/dev/null || true
}

read_scan_messages() {
  local message current total showed_progress
  showed_progress=0
  while IFS= read -r message; do
    if [[ "$message" == ========* ]] \
      && [[ "$message" =~ \[([0-9]+)/([0-9]+)\]$ ]]; then
      current=${BASH_REMATCH[1]}
      total=${BASH_REMATCH[2]}
      if [ -t 1 ]; then
        printf '\rReading photos: %s of %s   ' "$current" "$total"
        showed_progress=1
      fi
    else
      printf '%s\n' "$message" >> "$raw_messages"
    fi
  done < "$messages_pipe"
  if [ "$showed_progress" -eq 1 ]; then
    printf '\n'
  fi
}

cache_is_ready() {
  [ -f "$cache_dir/exiftool" ] \
    && [ -d "$cache_dir/lib" ] \
    && [ -f "$cache_marker" ] \
    && [ "$(cat "$cache_marker" 2>/dev/null)" = "$EXIFTOOL_COMMIT" ]
}

stop_scan() {
  if [ "$scan_pid" != "" ]; then
    kill "$scan_pid" 2>/dev/null || true
    wait "$scan_pid" 2>/dev/null || true
  fi
  if [ "$progress_reader_pid" != "" ]; then
    wait "$progress_reader_pid" 2>/dev/null || true
    progress_reader_pid=""
  fi
  printf '\nStopped. No photo was changed and no incomplete CSV was kept.\n' >&2
  exit 130
}

trap cleanup EXIT
trap stop_scan INT TERM

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'HELP'
Photo Index makes a searchable CSV from embedded photo metadata.

Normal Mac use:
  bash photo-index.sh

Optional command-line use:
  bash photo-index.sh "/path/to/photos" "/path/to/photo-index.csv"

The scanner reads embedded metadata from local photos and writes a CSV.
HELP
  exit 0
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) \
  || fail "I could not locate the Photo Index tool folder." \
    "Move the whole tool folder somewhere you can access, then try again."
formatter="$script_dir/photo-index-format.pl"
[ -f "$formatter" ] \
  || fail "A required file named photo-index-format.pl is missing." \
    "Run the installation command from the README again. It will restore all tool files."

say "Photo Index"
say "-----------"
say "Choose a local photo folder. Your photos will stay where they are."

if [ "${1:-}" != "" ]; then
  photo_folder=$1
else
  [ "$(uname -s)" = "Darwin" ] \
    || fail "No photo folder was provided, and the folder chooser is available only on a Mac." \
      "Run the script again with the photo folder path as its first argument."
  photo_folder=$(/usr/bin/osascript \
    -e 'POSIX path of (choose folder with prompt "Choose the folder containing the photos to index")' \
    2>/dev/null) || {
      say "No folder was chosen. Nothing was changed."
      exit 0
    }
  used_folder_chooser=1
fi

[ -d "$photo_folder" ] \
  || fail "The selected photo folder does not exist or is not available." \
    "Check that the photos finished copying to this Mac or a connected local drive, then choose that folder again."
[ -r "$photo_folder" ] \
  || fail "The selected photo folder cannot be read by Terminal." \
    "Open System Settings > Privacy & Security > Files and Folders, allow Terminal to access the folder, and try again."

photo_folder=$(CDPATH= cd -- "$photo_folder" 2>/dev/null && pwd -P) \
  || fail "The selected photo folder could not be opened." \
    "Check that the folder is still connected and that Terminal has permission to read it."

if [ "${2:-}" != "" ]; then
  csv_file=$2
else
  destination="$HOME/Desktop"
  [ -d "$destination" ] || destination="$HOME"
  csv_file="$destination/photo-index-$(date +%Y-%m-%d-%H%M%S)-$$.csv"
fi

case "$csv_file" in
  *.csv|*.CSV) ;;
  *) csv_file="$csv_file.csv" ;;
esac

csv_parent=$(dirname -- "$csv_file")
[ -d "$csv_parent" ] \
  || fail "The folder for the CSV does not exist: $csv_parent" \
    "Choose an existing output folder, or leave off the second argument to save the index on the Desktop."
[ -w "$csv_parent" ] \
  || fail "The CSV cannot be saved in: $csv_parent" \
    "Choose a folder you can write to, or allow Terminal to access the Desktop in System Settings."

case "$csv_file" in
  /*) ;;
  *) csv_file="$(CDPATH= cd -- "$csv_parent" 2>/dev/null && pwd -P)/$(basename -- "$csv_file")" ;;
esac

if [ -e "$csv_file" ]; then
  fail "A file already exists at the requested CSV path: $csv_file" \
    "Choose a different name. Photo Index will not overwrite an existing file."
fi

output_lock="${csv_file}.photo-index-lock"
if ! mkdir "$output_lock" 2>/dev/null; then
  fail "Another scan may already be using this CSV name: $csv_file" \
    "Wait for the other scan to finish, or choose a different CSV name. If no scan is running, remove only the matching .photo-index-lock folder and try again."
fi

partial_csv=$(mktemp "$csv_parent/.photo-index-csv.XXXXXXXX") \
  || fail "A temporary CSV could not be created in: $csv_parent" \
    "Check that the destination has free space and that Terminal can write there."
metadata_json=$(mktemp "$csv_parent/.photo-index-data.XXXXXXXX") \
  || fail "A temporary data file could not be created in: $csv_parent" \
    "Check that the destination has free space and try again."
raw_messages=$(mktemp "$csv_parent/.photo-index-messages.XXXXXXXX") \
  || fail "A temporary message file could not be created in: $csv_parent" \
    "Check that the destination has free space and try again."
messages_dir=$(mktemp -d "$csv_parent/.photo-index-ipc.XXXXXXXX") \
  || fail "A temporary progress folder could not be created in: $csv_parent" \
    "Check that the destination has free space and try again."
messages_pipe="$messages_dir/messages"
mkfifo "$messages_pipe" \
  || fail "Live progress could not be prepared." \
    "Check that Terminal can write to the CSV destination, then try again."

if [ "${PHOTO_INDEX_EXIFTOOL:-}" != "" ]; then
  [ -x "$PHOTO_INDEX_EXIFTOOL" ] \
    || fail "The test ExifTool path is not executable." "Check PHOTO_INDEX_EXIFTOOL and try again."
  exiftool_runner=("$PHOTO_INDEX_EXIFTOOL")
else
  command -v perl >/dev/null 2>&1 \
    || fail "This Mac does not have Perl, which ExifTool needs." \
      "Ask the Mac administrator to make Perl available, then run Photo Index again."
  command -v curl >/dev/null 2>&1 \
    || fail "This Mac does not have curl, which is needed for the first-run download." \
      "Ask the Mac administrator to make curl available, then run Photo Index again."
  command -v shasum >/dev/null 2>&1 \
    || fail "This Mac cannot verify the ExifTool download." \
      "Ask the Mac administrator to make shasum available. Do not use an unverified download."
  command -v tar >/dev/null 2>&1 \
    || fail "This Mac cannot unpack the ExifTool download." \
      "Ask the Mac administrator to make tar available, then run Photo Index again."

  cache_parent="${PHOTO_INDEX_CACHE_DIR:-$script_dir/.photo-index-cache}"
  cache_dir="$cache_parent/exiftool-$EXIFTOOL_COMMIT"
  cache_marker="$cache_dir/.photo-index-complete"
  mkdir -p "$cache_parent" \
    || fail "The tool cache could not be created in: $cache_parent" \
      "Move the Photo Index tool folder somewhere you can write to and try again."

  if ! cache_is_ready; then
    cache_lock_path="$cache_parent/.photo-index-cache-setup-lock"
    cache_waited=0
    while true; do
      if cache_is_ready; then
        break
      fi
      if mkdir "$cache_lock_path" 2>/dev/null; then
        cache_setup_lock="$cache_lock_path"
        break
      fi
      if [ "$cache_waited" -eq 0 ]; then
        say "Another first run is preparing the metadata reader. Waiting for it to finish..."
      fi
      if [ "$cache_waited" -ge 120 ]; then
        fail "The metadata reader is still being prepared by another Photo Index run." \
          "Wait for the other run to finish, then try again. If no other run is open and this repeats, ask the tool maintainer to clear the cache setup lock."
      fi
      sleep 2
      cache_waited=$((cache_waited + 2))
    done

    if [ "$cache_setup_lock" != "" ] && ! cache_is_ready; then
      if [ -e "$cache_dir" ]; then
        rm -rf "$cache_dir" \
          || fail "An incomplete tool cache could not be cleared." \
            "Move the Photo Index tool folder somewhere you can write to and try again."
      fi
      download_dir=$(mktemp -d "$cache_parent/download.XXXXXXXX") \
        || fail "A temporary download folder could not be created." \
          "Check free space and permissions for the Photo Index tool folder."
      archive="$download_dir/exiftool.tar.gz"
      say "First run: downloading the verified ExifTool metadata reader..."
      if ! curl --fail --location --silent --show-error \
        --connect-timeout 20 --retry 2 \
        "$EXIFTOOL_URL" --output "$archive"; then
        fail "ExifTool could not be downloaded from GitHub." \
          "Check the internet connection and whether your network allows github.com, then try again. If GitHub is blocked, ask your IT staff for help."
      fi
      actual_sha=$(shasum -a 256 "$archive" 2>/dev/null | awk '{print $1}')
      [ "$actual_sha" = "$EXIFTOOL_SHA256" ] \
        || fail "The ExifTool download did not pass its safety check." \
          "Ask the tool maintainer to clear the Photo Index cache, then try again on a trusted network. Do not use the unverified download."
      if ! tar -xzf "$archive" -C "$download_dir"; then
        fail "The verified ExifTool download could not be unpacked." \
          "Check that the Mac has free disk space, then run Photo Index again."
      fi
      extracted_dir="$download_dir/exiftool-$EXIFTOOL_COMMIT"
      [ -f "$extracted_dir/exiftool" ] && [ -d "$extracted_dir/lib" ] \
        || fail "The ExifTool download was incomplete." \
          "Check free disk space and internet access, then run Photo Index again."
      printf '%s\n' "$EXIFTOOL_COMMIT" > "$extracted_dir/.photo-index-complete" \
        || fail "The verified ExifTool cache could not be completed." \
          "Check that you can write to the Photo Index tool folder and try again."
      mv "$extracted_dir" "$cache_dir" \
        || fail "ExifTool could not be saved for later runs." \
          "Check that you can write to the Photo Index tool folder and try again."
      rm -rf "$download_dir"
      download_dir=""
      rmdir "$cache_setup_lock" 2>/dev/null || true
      cache_setup_lock=""
    elif [ "$cache_setup_lock" != "" ]; then
      rmdir "$cache_setup_lock" 2>/dev/null || true
      cache_setup_lock=""
    fi
  fi
  exiftool_runner=(perl "$cache_dir/exiftool")
fi

say ""
say "Photo folder: $photo_folder"
say "Index file:   $csv_file"
say ""
say "Reading supported photos in this folder and all folders inside it."
say "Large photo libraries can take a while. Progress will appear below."

read_scan_messages &
progress_reader_pid=$!

"${exiftool_runner[@]}" -q -r -progress -j -G1 -a -sep '; ' \
  -charset filename=UTF8 \
  -ext jpg -ext jpeg -ext tif -ext tiff -ext png -ext heic -ext heif \
  -ext dng -ext cr2 -ext cr3 -ext nef -ext arw -ext raf -ext orf \
  -ext rw2 -ext pef -ext srw -ext psd -ext webp -ext avif \
  -FileName -Directory -FileType -FileSize# -ImageWidth -ImageHeight \
  -IPTC:Caption-Abstract -XMP-dc:Description -EXIF:ImageDescription \
  -XMP-iptcCore:AltTextAccessibility -XMP-iptcCore:ExtDescrAccessibility \
  -IPTC:Headline -XMP-photoshop:Headline \
  -IPTC:Keywords -XMP-dc:Subject \
  -IPTC:By-line -XMP-dc:Creator -EXIF:Artist \
  -IPTC:Credit -XMP-photoshop:Credit \
  -IPTC:CopyrightNotice -XMP-dc:Rights \
  -EXIF:DateTimeOriginal -IPTC:DateCreated -XMP-photoshop:DateCreated \
  -FileModifyDate \
  "$photo_folder" > "$metadata_json" 2> "$messages_pipe" &
scan_pid=$!
wait "$scan_pid"
scan_status=$?
scan_pid=""
wait "$progress_reader_pid" 2>/dev/null || true
progress_reader_pid=""
if [ "$scan_status" -ne 0 ]; then
  failure_log="${csv_file%.*}-failed-scan-$(date +%Y-%m-%d-%H%M%S)-$$.txt"
  saved_failure_log=""
  if [ -s "$raw_messages" ] && mv "$raw_messages" "$failure_log"; then
    chmod 600 "$failure_log" 2>/dev/null || true
    raw_messages=""
    saved_failure_log="$failure_log"
  fi
  if [ -s "$raw_messages" ]; then
    printf '\nDetails from the metadata reader:\n' >&2
    sed -n '1,12p' "$raw_messages" >&2
  fi
  if [ "$saved_failure_log" != "" ]; then
    fail "The photo scan stopped before it was complete. No CSV was saved. The full error report is at: $saved_failure_log" \
      "Check that the local drive is still connected, the photo copy finished, and Terminal can read the folder. Then run Photo Index again."
  else
    fail "The photo scan stopped before it was complete. No CSV was saved." \
      "Check that the local drive is still connected, the photo copy finished, and Terminal can read the folder. Then run Photo Index again."
  fi
fi

photo_count=$(perl "$formatter" "$metadata_json" "$partial_csv" "$photo_folder")
format_status=$?
if [ "$format_status" -eq 4 ]; then
  fail "No supported photos were found in the selected folder." \
    "Choose the folder that actually contains the exported photos. Supported types include JPEG, TIFF, PNG, HEIC, major camera RAW formats, PSD, WebP, and AVIF."
elif [ "$format_status" -ne 0 ]; then
  fail "The photo metadata was read, but the CSV could not be prepared." \
    "Check that the destination has free space, then run Photo Index again. If it repeats, give the Terminal message to the person maintaining this tool."
fi

[ ! -e "$csv_file" ] \
  || fail "Another file appeared at the requested CSV path while the scan was running: $csv_file" \
    "Your completed scan was not allowed to overwrite it. Choose a different CSV name and run Photo Index again."
mv "$partial_csv" "$csv_file" \
  || fail "The finished CSV could not be saved at: $csv_file" \
    "Check the destination's permissions and free space, then run Photo Index again."
partial_csv=""
rmdir "$output_lock" 2>/dev/null || true
output_lock=""

warning_count=0
if [ -s "$raw_messages" ]; then
  warning_file="${csv_file%.*}-warnings.txt"
  if [ -e "$warning_file" ]; then
    warning_file="${csv_file%.*}-warnings-$(date +%Y-%m-%d-%H%M%S)-$$.txt"
  fi
  if cp "$raw_messages" "$warning_file"; then
    chmod 600 "$warning_file" 2>/dev/null || true
    warning_count=$(wc -l < "$raw_messages" | tr -d ' ')
  else
    printf '\nThe CSV was saved, but the warning report could not be saved.\n' >&2
    printf 'Here are the first warning lines:\n' >&2
    sed -n '1,12p' "$raw_messages" >&2
  fi
fi

say ""
say "Done. Indexed $photo_count photo(s)."
say "CSV saved at:"
say "$csv_file"
if [ "$warning_count" -gt 0 ]; then
  say ""
  say "$warning_count warning line(s) were saved at:"
  say "$warning_file"
  say "The CSV is usable, but check that file before relying on the index."
fi
say ""
say "Open the CSV and check a few photos with known captions and credits before sharing it."
if [ "$used_folder_chooser" -eq 1 ] && [ "$(uname -s)" = "Darwin" ]; then
  /usr/bin/open -R "$csv_file" 2>/dev/null || true
fi
