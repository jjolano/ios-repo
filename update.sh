#!/bin/sh
set -e
BASE="https://github.com/jjolano/ios-repo/releases/download"
STAGE=.stage
rm -rf "$STAGE" && mkdir -p "$STAGE"

for tag in $(gh release list --json tagName -q '.[].tagName'); do
  mkdir -p "$STAGE/$tag"
  gh release download "$tag" --dir "$STAGE/$tag" --pattern '*.deb'
done

# guard: abort if nothing was downloaded
if [ -z "$(ls -A "$STAGE" 2>/dev/null)" ]; then
  echo "error: no debs found in any release" >&2
  exit 1
fi

dpkg-scanpackages --multiversion "$STAGE" > Packages
sed -i "s|^Filename: $STAGE/|Filename: $BASE/|" Packages

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

git add Packages Packages.bz2 Packages.gz Packages.lzma Packages.xz Packages.zst Release update.sh index.html
git diff --cached --quiet || { git commit -m "update repo"; git push; }
