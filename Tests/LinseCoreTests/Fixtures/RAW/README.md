# RAW camera regression matrix

`samples.json` pins nine independent, unmodified camera files from https://raw.pixls.us/ by URL and SHA-256. Every selected file is CC0-1.0 in the source catalog. The files cover Apple Bayer DNG and ProRAW, Canon CR2 and compressed/cropped CR3, Nikon compressed NEF, Sony compressed ARW, Fujifilm X-Trans RAF, Olympus ORF and Panasonic RW2.

The large originals are not checked into Git. Fetch and verify them with:

```sh
python3 scripts/fetch-raw-samples.py
swift test --filter ImageImportTests
```

Downloads go into ignored `build/raw-samples/`. `LINSE_RAW_SAMPLES_DIR` can point tests at an existing verified copy. Camera tests explicitly skip when the file is absent; network access is never implicit during `swift test`.

Tests require true RAW decoding, more than one million output pixels, nonblank previews, and correct handling of TIFF-based RAW containers even without filenames. Separate regressions cover ordinary JPEG/TIFF, invalid/truncated files, orientation, source-file lifetime, 16-bit input textures, original-size 16-bit TIFF export, and preserving existing edits on failure.

A passing matrix proves these exact samples on the tested OS, not every model, compression mode, operating system version or future camera. New formats need additional independent fixtures; never replace a failing sample with a re-encoded image to make it pass.
