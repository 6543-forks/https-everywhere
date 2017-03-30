#!/usr/bin/env bash

# Build an HTTPS Everywhere .crx Chromium extension (for Chromium 17+)
#
# To build the current state of the tree:
#
#     ./makecrx.sh #
# To build a particular tagged release:
#
#     ./makecrx.sh <version number>
#
# eg:
#
#     ./makecrx.sh chrome-2012.1.26
#
# Note that .crx files must be signed; this script makes you a
# "dummy-chromium.pem" private key for you to sign your own local releases,
# but these .crx files won't detect and upgrade to official HTTPS Everywhere
# releases signed by EFF :/.  We should find a more elegant arrangement.

cd $(dirname $0)

if [ -n "$1" ]; then
  BRANCH=`git branch | head -n 1 | cut -d \  -f 2-`
  SUBDIR=checkout
  [ -d $SUBDIR ] || mkdir $SUBDIR
  cp -r -f -a .git $SUBDIR
  cd $SUBDIR
  git reset --hard "$1"
  git submodule update --recursive -f
fi

VERSION=`python2.7 -c "import json ; print(json.loads(open('chromium/manifest.json').read())['version'])"`

echo "Building chrome version" $VERSION

[ -d pkg ] || mkdir -p pkg
[ -e pkg/crx ] && rm -rf pkg/crx

# Clean up obsolete ruleset databases, just in case they still exist.
rm -f src/chrome/content/rules/default.rulesets src/defaults/rulesets.sqlite

sed -e "s/VERSION/$VERSION/g" chromium/updates-master.xml > chromium/updates.xml

mkdir -p pkg/crx/rules
cd pkg/crx
rsync -aL ../../chromium/ ./
# Turn the Firefox translations into the appropriate Chrome format:
rm -rf _locales/
mkdir _locales/
python2.7 ../../utils/chromium-translations.py ../../translations/ _locales/
python2.7 ../../utils/chromium-translations.py ../../src/chrome/locale/ _locales/
do_not_ship="*.py *.xml icon.jpg"
rm -f $do_not_ship
cd ../..

. ./utils/merge-rulesets.sh || exit 1

cp src/$RULESETS pkg/crx/rules/default.rulesets

sed -i -e "s/VERSION/$VERSION/g" pkg/crx/manifest.json

python2.7 -c "import json; m=json.loads(open('pkg/crx/manifest.json').read()); e=m['author']; m['author']={'email': e}; del m['applications']; open('pkg/crx/manifest.json','w').write(json.dumps(m,indent=4,sort_keys=True))"

#sed -i -e "s/VERSION/$VERSION/g" pkg/crx/updates.xml
#sed -e "s/VERSION/$VERSION/g" pkg/updates-master.xml > pkg/crx/updates.xml

if [ -n "$BRANCH" ] ; then
  crx="pkg/https-everywhere-$VERSION.crx"
  xpi="pkg/https-everywhere-$VERSION.xpi"
  key=../dummy-chromium.pem
else
  crx="pkg/https-everywhere-$VERSION~pre.crx"
  xpi="pkg/https-everywhere-$VERSION~pre.xpi"
  key=dummy-chromium.pem
fi
if ! [ -f "$key" ] ; then
  echo "Making a dummy signing key for local build purposes"
  openssl genrsa 2048 > "$key"
fi

## Based on https://code.google.com/chrome/extensions/crx.html

dir=pkg/crx
name=pkg/crx
pub="$name.pub"
sig="$name.sig"
zip="$name.zip"
trap 'rm -f "$pub" "$sig" "$zip"' EXIT

# zip up the crx dir
cwd=$(pwd -P)
(cd "$dir" && ../../utils/create_xpi.py -n "$cwd/$zip" -x "../../.build_exclusions" .)

# signature
openssl sha1 -sha1 -binary -sign "$key" < "$zip" > "$sig"

# public key
openssl rsa -pubout -outform DER < "$key" > "$pub" 2>/dev/null

byte_swap () {
  # Take "abcdefgh" and return it as "ghefcdab"
  echo "${1:6:2}${1:4:2}${1:2:2}${1:0:2}"
}

crmagic_hex="4372 3234" # Cr24
version_hex="0200 0000" # 2
pub_len_hex=$(byte_swap $(printf '%08x\n' $(ls -l "$pub" | awk '{print $5}')))
sig_len_hex=$(byte_swap $(printf '%08x\n' $(ls -l "$sig" | awk '{print $5}')))

# Case-insensitive matching is a GNU extension unavailable when using BSD sed.
if [[ "$(sed --version 2>&1)" =~ "GNU" ]]; then
  sed="sed"
elif [[ "$(gsed --version 2>&1)" =~ "GNU" ]]; then
  sed="gsed"
fi

(
  echo "$crmagic_hex $version_hex $pub_len_hex $sig_len_hex" | $sed -e 's/\s//g' -e 's/\([0-9A-F]\{2\}\)/\\\\\\x\1/gI' | xargs printf
  cat "$pub" "$sig" "$zip"
) > "$crx"

cp $crx $xpi

bash utils/android-push.sh "$xpi"

#rm -rf pkg/crx

#python2.7 githubhelper.py $VERSION

#git add chromium/updates.xml
#git commit -m "release $VERSION"
#git tag -s chrome-$VERSION -m "release $VERSION"
#git push
#git push --tags

echo >&2 "Total included rules: `find src/chrome/content/rules -name "*.xml" | wc -l`"
echo >&2 "Rules disabled by default: `find src/chrome/content/rules -name "*.xml" | xargs grep -F default_off | wc -l`"
echo >&2 "Created $crx"
if [ -n "$BRANCH" ]; then
  cd ..
  cp $SUBDIR/$crx pkg
  rm -rf $SUBDIR
fi
echo "$crx" # send to stdout so scripts can parse it
