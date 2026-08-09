#!/bin/sh
set -e
STAGE=.stage
rm -rf "$STAGE" && mkdir -p "$STAGE"

# Source repos that publish .deb releases for this apt repo.
# Format: "owner/repo" — debs are pulled from each repo's releases.
# Order matters: project repos first so they win the dedupe below.
SOURCE_REPOS="jjolano/HookKit jjolano/Shadow jjolano/ios-repo"

for repo in $SOURCE_REPOS; do
  for tag in $(gh release list -R "$repo" --json tagName -q '.[].tagName'); do
    # skip releases with no .deb assets (e.g. source-only releases)
    total=$(gh release view "$tag" -R "$repo" --json assets -q '[.assets[] | select(.name | endswith(".deb"))] | length')
    [ "$total" -gt 0 ] || continue
    mkdir -p "$STAGE/$repo/$tag"
    gh release download "$tag" -R "$repo" --dir "$STAGE/$repo/$tag" --pattern '*.deb'
    # guard: every release must yield its .deb assets; a partial download means
    # a degraded index — abort instead of publishing one.
    got=$(ls "$STAGE/$repo/$tag"/*.deb 2>/dev/null | wc -l)
    [ "$got" -eq "$total" ] || { echo "error: $repo $tag: expected $total debs, downloaded $got" >&2; exit 1; }
  done
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
' Packages > Packages.tmp && mv Packages.tmp Packages

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

# stamp the website footer with the index update time (UTC, ISO)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sed -i "s|\(>Last updated <span id=\"last-updated\">\)[^<]*\(</span>\)|\1$STAMP\2|" index.html

# Only commit if something meaningful changed. Release always differs (fresh
# Date/checksums), so only Packages* and index.html count as meaningful.
git add Packages Packages.bz2 Packages.gz Packages.lzma Packages.xz Packages.zst Release update.sh index.html
if git diff --cached --quiet HEAD -- Packages Packages.bz2 Packages.gz Packages.lzma Packages.xz Packages.zst index.html; then
  echo "no meaningful change; skipping commit"
else
  git commit -m "update repo"
  git push
fi
