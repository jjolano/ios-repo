---
name: repo-website
description: Update or review the ios.jjolano.me landing page (index.html in jjolano/ios-repo). Use when the user wants to change the website, fix page content, add packages to the page, review what's displayed, or asks to touch the repo's landing page.
---

# Repo Website

The landing page is a single self-contained `index.html` (inline CSS, no build step) served from the `release` branch via GitHub Pages. It advertises the packages in this repo.

## Hard invariants — never break

1. **The three deep-link hrefs must stay byte-identical** (they are the whole point of the page):
   - `zbra://sources/add/https://ios.jjolano.me`
   - `sileo://source/https://ios.jjolano.me`
   - `cydia://url/https://cydia.saurik.com/api/share#?source=https://ios.jjolano.me`
   After any edit, verify with:
   ```sh
   grep -o 'href="[^"]*"' index.html | grep -v github.com
   ```
2. **Every claim about packages must be verified against `Packages`** (the live index) — do not invent IDs, descriptions, versions, or arch support:
   ```sh
   grep "^Package:" Packages | sort -u
   awk '/^Package: <id>$/{f=1} f&&/^Description:/{print; exit}' Packages
   awk '/^Package: <id>$/{f=1} f&&/^Architecture:/{print; exit}' Packages
   ```
3. **Keep the existing visual design intact** for content-only edits — the design is intentional (dark theme, chips, cards, reveal animation). Preserve it.

## Workflow

1. **Read first**: `index.html` + skim `Packages` for the package ids/descriptions/arches.
2. **Content edits** (copy fixes, package list updates, factual corrections): edit directly, verify with the invariant checks above.
3. **Visual/UX redesign**: delegate to @designer with the current index.html + ground truth (package list, variants, deep links). After designer work, review the copy yourself — designer copy can be weak or invent facts; check every description against `Packages` and fix without changing visual intent.
4. **Known accuracy traps** (from past reviews):
   - Package managers (Zebra/Sileo/Cydia) are NOT arch-specific — don't tag buttons with arches.
   - Not everything supports all three variants: HookKit ships roothide (iphoneos-arm64e), Shadow is rootful/rootless only. Check `Architecture:` per package before claiming — don't overclaim.
   - Roothide = rootless-style layout that *hides the jailbreak from apps* — not just "keeps rootfs intact".
   - Don't claim packages are "signed" — there is no Release.gpg. Say "hosted via GitHub Releases and Pages".
   - The repo serves exactly two packages: `me.jjolano.fmwk.hookkit` and `me.jjolano.shadow`. The `legacy` release (modulous, rootbridge, hkmodules, shadow.legacy, sileorespring) was deleted on 2026-08-10 and those debs are gone — never re-add them to the page.
5. **Ship**:
   ```sh
   git add index.html && git commit -m "<what changed>" && git push origin release
   ```
   Then wait for the Pages build (`gh run list --limit 1`) and verify the live site:
   ```sh
   sleep 50; curl -s https://ios.jjolano.me/ | grep -c "<expected-marker>"
   ```
   A run marked `[time]` is usually benign (post-success cleanup hang) — check its log for "Reported success!" before assuming failure.

## When to add packages to the page

- New package releases (see `repo-release` skill for the release flow) that users should discover.
- Keep the two featured cards (HookKit, Shadow) + the compact `.pkg-more` secondary list for the rest.
