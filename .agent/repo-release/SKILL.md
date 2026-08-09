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

## Un-release (pull a release)

Releases are picked up automatically (see Gotchas), but **un-releasing is manual**. Removing release assets or deleting a release fires **no event** on this repo, so the index goes stale until the next poll — always run the poll manually after an un-release.

**If debs are in THIS repo's releases** (e.g. legacy):
```sh
# remove the debs (or delete release + tag)
gh release delete-asset legacy <deb> --yes
# or: gh release delete <tag> --yes --cleanup-tag

# update the index NOW (don't wait for the 6h poll)
gh workflow run poll-sources.yml
```

**If debs are in an OFFICIAL repo's releases** (HookKit/Shadow):
```sh
gh release delete <tag> -R jjolano/Shadow --yes --cleanup-tag
gh workflow run poll-sources.yml   # in this repo
```

The poll re-runs `update.sh`, which lists current releases from all sources; the removed release's stanzas drop from the index and its URLs 404. If the same version also exists in another source (e.g. legacy), the dedupe keeps the other — which is the right behavior.

**Verify after un-release**: `grep -c "^Filename:.*<version>" Packages` → 0, and `curl -sIL <removed-url>` → 404.

## Gotchas

- **Never `git add .`** — will stage the gitignored deb dirs if present. `update.sh` adds explicit paths only.
- **Immutable tags** — don't delete/recreate a release to fix an asset; bump the tag instead.
- **`dpkg-scanpackages` emits `Filename: .stage/...`** — `update.sh`'s sed rewrites `.stage/<owner>/<repo>/<tag>/` → `https://github.com/<owner>/<repo>/releases/download/<tag>/`. If you change the stage layout, update the sed.
- **`legacy` release** — contains all pre-migration debs; keep it, some users may still be on old versions.
- **Intentional asset removal** — removing debs from a release (premature release, etc.) is fine: the download guard only aborts on a *partial* download (fewer debs than the release lists), and the next `update.sh` run drops them from the index.
- **Auto-update on official releases** — `update repo` fires on releases published in THIS repo; `poll sources` (every 15 min + manual) catches releases in official repos. For instant updates, `repository_dispatch` from the source repos would be needed (bigger lift, not currently done).
- **Poll interval** — `.github/workflows/poll-sources.yml` schedules `poll sources` at `*/15 * * * *` (GitHub schedule minimum is `*/5 * * * *`). 15 min is the zero-maintenance sweet spot (96 runs/day, negligible cost on a public repo). Only go to 5 min for a hot release cadence; only add `repository_dispatch` if users hit the <15-min window.
