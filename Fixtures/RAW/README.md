# RAW camera regression matrix

`samples.json` pins nine independent, unmodified camera files from https://raw.pixls.us/ by URL and SHA-256. Every selected file is CC0-1.0 in the source catalog. The files cover Apple Bayer DNG and ProRAW, Canon CR2 and compressed/cropped CR3, Nikon compressed NEF, Sony compressed ARW, Fujifilm X-Trans RAF, Olympus ORF and Panasonic RW2.

The large originals are not checked into Git. Fetch and verify them with:

```sh
python3 scripts/fetch-raw-samples.py
```

Downloads go into ignored `build/raw-samples/`. The automated camera regression suite was retired on 2026-11-08. Use these originals for the manual import smoke flow in `docs/smoke.md`, recording the exact camera, OS, dimensions and result. Missing or untried samples are unverified, not passed. No downloads occur implicitly during build or smoke checks.

A passing matrix proves these exact samples on the tested OS, not every model, compression mode, operating system version or future camera. New formats need additional independent fixtures; never replace a failing sample with a re-encoded image to make it pass.
