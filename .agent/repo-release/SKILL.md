---
name: repo-release
description: Ship a new version of this iOS package repo (jjolano/ios-repo). Creates a GitHub release with .deb assets, regenerates the apt Packages index pointing at release URLs, commits and pushes so ios.jjolano.me updates. Use when releasing a new tweak version, adding a new package, or when the user says "release", "ship", "publish", or "push a new version" for this repo.
---

# Repo Release

This repo serves .debs from **GitHub Releases**; the git tree only holds the apt index files (`Packages*`, `Release`). Do NOT add .deb files to git — they are gitignored (`root/ rootless/ roothide/`).

## Layout

- `update.sh` — the whole pipeline: download all release debs into `.stage/`, `dpkg-scanpackages`, rewrite `Filename:` to release URLs, compress, build `Release` via `apt-ftparchive`, commit+push.
- Releases: one tag per tweak version (e.g. `hookkit-2.1.1-1`), .deb assets inside. The `legacy` release holds the pre-release migration debs.

## Release workflow

1. **Build** the .debs for all needed variants (rootful `iphoneos-arm`, rootless `iphoneos-arm64`, roothide `iphoneos-arm64e`).
2. **Create the release** (immutable tag — re-uploading an asset to the same tag breaks client checksums):
   ```sh
   gh release create <tag> <root.deb> <rootless.deb> <roothide.deb> --title <tag> --notes "<changelog>"
   ```
   e.g. `gh release create hookkit-2.1.1-1 root/*.deb rootless/*.deb roothide/*.deb --title hookkit-2.1.1-1`
3. **Regenerate the index**: `./update.sh`
   - `set -e` — abort if any scan/compress step fails.
   - Only commits+pushes if there are staged changes.
   - Requires `gh` auth and the debs to exist on the release.
4. **Verify** (see Verify below).

## Verify after update

- `Packages` has the new version: `grep -A3 "^Package: me.jjolano.fmwk.hookkit" Packages | head -8`
- Filenames are absolute release URLs: `grep -c "^Filename: https" Packages` (should equal total package count)
- `Release` checksums match `Packages`: `sha256sum Packages` vs `awk '/^SHA256:/{f=1;next} f && /Packages /{print $1; exit}' Release`
- Download works: `curl -sIL <first-release-url>` returns 200 via redirect
- Site live: `curl -sI https://ios.jjolano.me/Packages` returns 200

## Gotchas

- **Never `git add .`** — will stage the gitignored deb dirs if present. `update.sh` adds explicit paths only.
- **Immutable tags** — don't delete/recreate a release to fix an asset; bump the tag instead.
- **`dpkg-scanpackages` emits `Filename: .stage/...`** — `update.sh`'s sed strips the `.stage/` prefix to build the absolute URL. If you change the stage dir, update the sed.
- **`legacy` release** — contains all pre-migration debs; keep it, some users may still be on old versions.
