#!/bin/sh
set -e
STAGE=.stage
rm -rf "$STAGE" && mkdir -p "$STAGE"

# Source repos that publish .deb releases for this apt repo.
# Format: "owner/repo" — debs are pulled from each repo's releases.
# Order matters: project repos first so they win the dedupe below.
SOURCE_REPOS="jjolano/HookKit jjolano/Shadow"

: > "$STAGE/releases.ndjson"
for repo in $SOURCE_REPOS; do
  found=0
  for tag in $(gh release list -R "$repo" --json tagName -q '.[].tagName'); do
    # skip releases with no .deb assets (e.g. source-only releases)
    meta=$(gh release view "$tag" -R "$repo" --json tagName,publishedAt,body,assets)
    total=$(printf '%s' "$meta" | jq -r '[.assets[] | select(.name | endswith(".deb"))] | length')
    [ "$total" -gt 0 ] || continue
    # keep release metadata (publishedAt, notes) for the Changelog depiction tab
    printf '%s' "$meta" | jq -c --arg repo "$repo" \
      '{repo: $repo, tag: .tagName, publishedAt: .publishedAt, body: .body}' \
      >> "$STAGE/releases.ndjson"
    mkdir -p "$STAGE/$repo/$tag"
    gh release download "$tag" -R "$repo" --dir "$STAGE/$repo/$tag" --pattern '*.deb'
    # guard: every release must yield its .deb assets; a partial download means
    # a degraded index — abort instead of publishing one.
    got=$(ls "$STAGE/$repo/$tag"/*.deb 2>/dev/null | wc -l)
    [ "$got" -eq "$total" ] || { echo "error: $repo $tag: expected $total debs, downloaded $got" >&2; exit 1; }
    found=$((found + total))
  done
  # guard: a listed source repo yielding nothing means its release list came back
  # empty — a transient API or auth failure, not a deliberate prune. Publishing
  # then would silently drop every package that repo provides. Pruning versions
  # is fine; a repo going to zero is not. Drop it from SOURCE_REPOS to retire it.
  [ "$found" -gt 0 ] || { echo "error: $repo: no releases with .deb assets" >&2; exit 1; }
done

# guard: abort if nothing was downloaded
if [ -z "$(ls -A "$STAGE" 2>/dev/null)" ]; then
  echo "error: no debs found in any release" >&2
  exit 1
fi

# Scan per repo in SOURCE_REPOS order so earlier sources (official repos) emit
# stanzas first — the dedupe below keeps the first occurrence per version.
: > Packages
for repo in $SOURCE_REPOS; do
  [ -d "$STAGE/$repo" ] || continue
  dpkg-scanpackages --multiversion "$STAGE/$repo" >> Packages
done
# map .stage/<owner>/<repo>/<tag>/ -> https://github.com/<owner>/<repo>/releases/download/<tag>/
sed -E "s|^Filename: $STAGE/([^/]+/[^/]+)/([^/]+)/|Filename: https://github.com/\1/releases/download/\2/|" Packages > Packages.tmp && mv Packages.tmp Packages

# Dedupe: drop later stanzas whose (Package, Version, Architecture) triple was
# already seen. SOURCE_REPOS order decides the winner — first source wins.
# Paragraph mode (RS="") reads one stanza per record; a stanza is dropped whole.
# Then sort stanzas canonically: dpkg-scanpackages leaves same-version stanzas
# in directory-walk order, which varies per CI runner, so identical deb sets
# would otherwise produce a different Packages each run (and a spurious commit).
awk '
  BEGIN { RS="" }
  {
    pkg=""; ver=""; arch=""
    n=split($0, lines, "\n")
    for (i=1; i<=n; i++) {
      if (lines[i] ~ /^Package: /)      pkg = substr(lines[i], 10)
      else if (lines[i] ~ /^Version: /) ver = substr(lines[i], 10)
      else if (lines[i] ~ /^Architecture: /) arch = substr(lines[i], 16)
    }
    key = pkg "\034" ver "\034" arch
    if (!seen[key]++) { print; print "" }
  }
' Packages \
  | awk 'BEGIN { RS=""; ORS="" }
         { gsub(/\n/, "\001", $0); print $0 "\n" }' \
  | LC_ALL=C sort \
  | awk 'BEGIN { n = 0 }
         { if (n++ && $0 ~ /^Package: /) print ""; print }' \
  | tr '\001' '\n' \
  > Packages.tmp && mv Packages.tmp Packages

# Inject depiction fields for packages with a depictions/ios/<id>.{json,html} file.
# Sileo reads SileoDepiction (JSON), Cydia reads Depiction (HTML).
DEPIC_BASE="https://ios.jjolano.me/depictions/ios"
for f in depictions/ios/*.json; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .json)
  awk -v id="$id" -v db="$DEPIC_BASE" '
    $0 == "Package: " id { want=1 }
    want && /^Description:/ { print; print "Depiction: " db "/" id ".html"; print "SileoDepiction: " db "/" id ".json"; want=0; next }
    { print }
  ' Packages > Packages.tmp && mv Packages.tmp Packages
done

# Generate a Changelog tab in each depiction from source release notes. Map
# each stanza back to the release it came from via its Filename URL, join with
# the release metadata collected above, and rebuild the tab. Deterministic for
# a given release set (sorted by date/version, stable jq output), so unchanged
# releases churn nothing. Packages without notes (or without stanzas) are left
# untouched — including Cydia users' HTML depictions.
awk '
  BEGIN { RS="" }
  {
    pkg=""; ver=""; file=""
    n=split($0, lines, "\n")
    for (i=1; i<=n; i++) {
      if (lines[i] ~ /^Package: /)       pkg  = substr(lines[i], 10)
      else if (lines[i] ~ /^Version: /)  ver  = substr(lines[i], 10)
      else if (lines[i] ~ /^Filename: /) file = substr(lines[i], 11)
    }
    if (file ~ /^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\/[^/]+\//) {
      repo = file; sub(/\/releases\/download\/.*/, "", repo); sub(/^https:\/\/github\.com\//, "", repo)
      tag  = file; sub(/^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\//, "", tag); sub(/\/.*/, "", tag)
      printf "{\"pkg\":\"%s\",\"ver\":\"%s\",\"repo\":\"%s\",\"tag\":\"%s\"}\n", pkg, ver, repo, tag
    }
  }
' Packages > "$STAGE/stanzas.ndjson"

for depic in depictions/ios/*.json; do
  [ -e "$depic" ] || continue
  id=$(basename "$depic" .json)
  jq -n --slurpfile stanzas "$STAGE/stanzas.ndjson" --slurpfile rels "$STAGE/releases.ndjson" \
    --arg id "$id" '
      [ $stanzas[] | select(.pkg == $id) | . as $s |
        ($rels[] | select(.repo == $s.repo and .tag == $s.tag)) as $r |
        {ver: $s.ver, date: $r.publishedAt[0:10], body: $r.body} ]
      | unique_by(.ver)
      | map(select((.body // "") != ""))
      | sort_by(.date, .ver) | reverse as $entries |
      if ($entries | length) == 0 then empty
      else
        $entries | map([ {class: "DepictionSubheaderView", title: .ver, subtitle: .date},
                         {class: "DepictionMarkdownView", markdown: .body} ])
        | add
        | {class: "DepictionStackView", tabname: "Changelog", views: .}
      end' > "$STAGE/changelog.json" || continue
  [ -s "$STAGE/changelog.json" ] || continue
  jq --slurpfile tab "$STAGE/changelog.json" '
    .tabs |= (map(select(.tabname != "Changelog")) + $tab)' \
    "$depic" > "$depic.tmp" && mv "$depic.tmp" "$depic"
done

cat Packages | xz > Packages.xz
cat Packages | bzip2 > Packages.bz2
cat Packages | gzip > Packages.gz
cat Packages | lzma > Packages.lzma
cat Packages | zstd > Packages.zst

apt-ftparchive\
 -o APT::FTPArchive::Release::Origin="jjolano"\
 -o APT::FTPArchive::Release::Label="jjolano"\
 -o APT::FTPArchive::Release::Suite="stable"\
 -o APT::FTPArchive::Release::Version="1.0"\
 -o APT::FTPArchive::Release::Codename="ios"\
 -o APT::FTPArchive::Release::Architectures="iphoneos-arm iphoneos-arm64 iphoneos-arm64e"\
 -o APT::FTPArchive::Release::Components="main"\
 -o APT::FTPArchive::Release::Description="personal tweak repository"\
 release . > Release

# Only commit if something meaningful changed. Release always differs (fresh
# Date/checksums), so only the canonical Packages (deterministic for identical
# deb sets) and the regenerated depictions (release notes) are meaningful.
# index.html is not touched here — it reads Packages and Release in the browser.
git add Packages Packages.bz2 Packages.gz Packages.lzma Packages.xz Packages.zst Release update.sh depictions/ios/*.json
if git diff --cached --quiet HEAD -- Packages depictions/ios/*.json; then
  echo "no meaningful change; skipping commit"
else
  git commit -m "update repo"
  git push
fi
