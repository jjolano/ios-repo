---
name: repo-release
description: Ship a new version of this iOS package repo (jjolano/ios-repo). Publishes .debs as GitHub Releases (either in this repo or in the source repos for individual packages), then regenerates the apt Packages index pointing at release URLs, commits and pushes so ios.jjolano.me updates. Use when releasing a new tweak version, adding a new package, or when the user says "release", "ship", "publish", or "push a new version" for this repo.
---

# Repo Release

This apt repo serves .debs from **GitHub Releases**; the git tree only holds the apt index files (`Packages*`, `Release`). Do NOT add .deb files to git — they are gitignored (`root/ rootless/ roothide/`).

## Sources

`update.sh` aggregates debs from multiple source repos (see the `SOURCE_REPOS` variable in `update.sh`). Each source repo's releases are downloaded into `.stage/<owner>/<repo>/<tag>/`, then scanned and rewritten to absolute release URLs.

Currently: `jjolano/ios-repo` (this repo, holds the `legacy` debs) and `jjolano/HookKit` (official HookKit releases). Add a source repo when a package publishes its debs on its own repo's releases.

## Layout

- `update.sh` — the whole pipeline: download all release debs into `.stage/`, `dpkg-scanpackages`, rewrite `Filename:` to release URLs, inject depiction fields, compress, build `Release` via `apt-ftparchive`, commit+push.
- Releases: one tag per tweak version (e.g. `hookkit-2.1.1-1`), .deb assets inside. The `legacy` release holds the pre-release migration debs.
- Depictions: `depictions/ios/<package-id>.{json,html}` → injected into the index as `SileoDepiction:`/`Depiction:` for that package id. See the `repo-website` skill for page updates.

## Release workflow

1. **Decide where the debs live**: if the package has its own GitHub repo (HookKit, Shadow), publish its debs there (`gh release create` on that repo). Otherwise publish on this repo's releases.
2. **Build** the .debs for all needed variants (rootful `iphoneos-arm`, rootless `iphoneos-arm64`, roothide `iphoneos-arm64e`).
3. **Create the release** (immutable tag — re-uploading an asset to the same tag breaks client checksums):
   ```sh
   gh release create <tag> <root.deb> <rootless.deb> <roothide.deb> --title <tag> --notes "<changelog>" -R <owner/repo>
   ```
   e.g. `gh release create v2.1.1-1 *.deb -R jjolano/HookKit`
4. **Regenerate the index**: `./update.sh`
   - `set -e` — abort if any scan/compress step fails.
   - Downloads every source repo's releases; a release missing its debs (partial download) **aborts** — it must fail loudly rather than ship a degraded index.
   - Only commits+pushes if there are staged changes.
5. **Verify** (see Verify below).

## Verify after update

- `Packages` has the new version: `grep -A3 "^Package: me.jjolano.fmwk.hookkit" Packages | head -8`
- Filenames are absolute release URLs: `grep -c "^Filename: https" Packages` (should equal total package count)
- `Release` checksums match `Packages`: `sha256sum Packages` vs `awk '/^SHA256:/{f=1;next} f && /Packages /{print $1; exit}' Release`
- Download works: `curl -sIL <first-release-url>` returns 200 via redirect
- Site live: `curl -sI https://ios.jjolano.me/Packages` returns 200
- Depiction fields injected: `grep -c "^SileoDepiction:" Packages` (should equal package count for depicted ids)

## Gotchas

- **Never `git add .`** — will stage the gitignored deb dirs if present. `update.sh` adds explicit paths only.
- **Immutable tags** — don't delete/recreate a release to fix an asset; bump the tag instead.
- **`dpkg-scanpackages` emits `Filename: .stage/...`** — `update.sh`'s sed rewrites `.stage/<owner>/<repo>/<tag>/` → `https://github.com/<owner>/<repo>/releases/download/<tag>/`. If you change the stage layout, update the sed.
- **`legacy` release** — contains all pre-migration debs; keep it, some users may still be on old versions.
- **Intentional asset removal** — removing debs from a release (premature release, etc.) is fine: the download guard only aborts on a *partial* download (fewer debs than the release lists), and the next `update.sh` run drops them from the index.
