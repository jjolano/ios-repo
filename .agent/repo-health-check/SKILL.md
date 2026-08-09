---
name: repo-health-check
description: Audit this iOS package repo (jjolano/ios-repo) for index consistency, checksum integrity, and release-URL correctness. Use when the repo looks broken, when asked to "check the repo", "audit", "verify the index", or after a failed update.sh run.
---

# Repo Health Check

Read-only audit — do not modify files.

## 1. Index vs disk (only if debs exist locally)

```sh
ls root/*.deb rootless/*.deb roothide/*.deb 2>/dev/null | wc -l
grep -c "^Filename: " Packages
```
After the GitHub Releases migration, the git tree should contain **no .deb files** (they are gitignored). If debs exist locally, they are untracked leftovers — do not commit them.

## 2. Release URL integrity

Every `Filename:` must be an absolute release URL, none may leak `.stage/`:

```sh
grep -c "^Filename: https://github.com/jjolano/ios-repo/releases/download/" Packages
grep -c "^Filename: \.stage" Packages   # must be 0
```

## 3. Release checksums match Packages

```sh
sha256sum Packages
awk '/^SHA256:/{f=1;next} f && /Packages /{print $1; exit}' Release
```
The two must match. Also verify the package count: `grep -c "^Package:" Packages`.

## 4. Sample download

```sh
curl -sIL "$(grep -m1 '^Filename: https' Packages | cut -d' ' -f2)" | head -1   # expect 200
```

## 5. Site live

```sh
curl -sI https://ios.jjolano.me/Packages | head -1   # expect 200
```

## Common failure modes

- **`.stage/` leaked into Filenames** → sed in `update.sh` (`s|^Filename: $STAGE/|...|`) is wrong or stage dir renamed.
- **Empty Packages** → aborted `update.sh` run truncated it; re-run pipeline manually (download → scan → sed → compress → Release) or restore from git.
- **Checksum mismatch** → a release asset was re-uploaded to an existing immutable tag; create a new tag/version instead.
- **Site serving stale index** → commit+push happened but Pages cache; wait or re-trigger Pages build.
