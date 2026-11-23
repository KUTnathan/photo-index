# Photo Index for Mac

Photo Index reads captions, keywords, credits, dates and other embedded metadata from a local photo folder. It writes the results to a CSV on the Desktop. The photos and folder structure stay in place. Photo scanning and CSV creation happen on the Mac.

## Run Photo Index

1. Open Terminal from Applications > Utilities.
2. Copy the command below, paste it into Terminal and press Return.
3. Choose the local photo folder, then click **Choose**.
4. Leave Terminal open while it works. A large archive may take a while.
5. When Terminal says **Done**, open the new CSV on the Desktop.

Keep this command on one line:

```bash
installer="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/KUTnathan/photo-index/main/install.sh -o "$installer" && bash "$installer" https://raw.githubusercontent.com/KUTnathan/photo-index/main && rm -f "$installer"
```

The command installs or updates Photo Index in `~/photo-index-tool` and opens the folder window. The first run also downloads a verified copy of ExifTool, which reads the metadata. Later runs reuse it. Git, Homebrew, Python and an administrator password are not needed.

macOS may ask whether Terminal can read the photo folder or write to the Desktop. Allow access so the scan can finish.

To run the installed copy again:

```bash
bash "$HOME/photo-index-tool/photo-index.sh"
```

Paste the longer command whenever you want to check for a tool update.

Press Control-C in Terminal to stop a scan. Photo Index removes the unfinished CSV and leaves the photos alone.

## Find a photo

Open the CSV in Excel or Numbers. Search with Command-F or use the spreadsheet filters.

Each row includes the filename, its folder relative to the folder you scanned and the relative path to the file. Caption, Alt text and Extended description have separate columns. Absolute Mac paths and usernames stay out of the CSV, so the same folder path can be followed after the files move somewhere else.

The CSV is a snapshot of the folder at scan time. Make a new one after photos are added, renamed or moved.

## Check a small batch first

Start with a folder that has several known photos and a couple of subfolders.  

Check the finished CSV for those values. Follow a few paths back to the right photos in Finder. Look at accented names and punctuation. If Terminal mentions a warning report, read it before relying on the index.

Photo Index can read metadata embedded in IPTC, XMP or EXIF fields. Metadata stored only in a catalog or database will be absent from the CSV. Some RAW files may also carry fewer fields than their finished JPEGs.

## Large local archives

Keep the local filenames and folder structure steady after making the CSV because its paths point to that exact arrangement.

For an archive that is too large for one dependable run, scan one top-level folder at a time. Each CSV gets a timestamped name. The public repository needs only the code and tests. Keep photos, CSVs and warning reports out of it.

Supported files include JPEG, TIFF, PNG, HEIC/HEIF, DNG, major Canon/Nikon/Sony/Fujifilm/Olympus/Panasonic/Pentax/Samsung RAW formats, PSD, WebP and AVIF. The scanner skips ZIP archives.

## When a run fails

Terminal prints a **What to do next** section and keeps a partial CSV off the Desktop.

- If the folder is missing, confirm that the copy finished and that the local drive is connected.
- For a permission error, open System Settings > Privacy & Security > Files and Folders and allow Terminal to read the folder. A managed Mac may need help from IT.
- If the first-run download fails, check the internet connection and access to GitHub, then paste the command again.
- If no supported photos are found, choose the folder that contains the exported image files rather than ZIP files or shortcuts.
- If a warning report appears beside the CSV, check the named files and compare their rows with the originals.
- Blank metadata usually means the field was not embedded in that photo. Check the original files before continuing.



```bash
bash photo-index.sh "/path/to/local/photos" "/path/to/output.csv"
```
