#!/bin/zsh
# Builds build/Flick.app; with --install, also replaces ~/Applications/Flick.app
# and relaunches it; with --release, signs it for distribution and notarizes it.
#
#   ./build.sh [--install | --release]
#
# The bundle's FlickSourceRevision records the commit it was built from, with
# "-dirty" for uncommitted changes, so an installer can tell when the installed
# app is current:
#
#   plutil -extract FlickSourceRevision raw ~/Applications/Flick.app/Contents/Info.plist
#
# macOS keys the Accessibility grant to the signature's designated requirement,
# which every rebuild must keep satisfying; an ad-hoc signature would lose the
# grant on each rebuild. With a Developer ID Application identity in the
# keychain, the build is signed with it and the hardened runtime, like a
# release but without notarizing: its requirement names the team rather than
# one certificate, so a local build shares the grant with an installed release
# and can stand in for it (quit Flick, then open build/Flick.app). Without one,
# it is signed with flick-local, a self-signed code-signing certificate this
# creates in the login keychain once, whose requirement — `identifier
# "info.junz.flick" and certificate leaf = H"..."` — pins its leaf hash; it
# needs no trust setting.
#
# --release signs with the keychain's Developer ID Application identity instead,
# with the hardened runtime and a secure timestamp, has Apple notarize the app,
# staples the ticket, and leaves build/Flick-<version>.zip for a GitHub Release.
# It refuses a dirty tree, so the zip matches a commit. notarytool reads its
# credentials from the keychain profile $FLICK_NOTARY_PROFILE (default
# flick-notary), stored once with:
#
#   xcrun notarytool store-credentials flick-notary \
#       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#
# The hardened runtime needs no entitlements: the private WindowManagement
# framework Flick dlopens is Apple-signed, which library validation allows, and
# the event tap is gated by the Accessibility grant, not by an entitlement.
set -euo pipefail
cd ${0:A:h}

local_identity=flick-local
app=build/Flick.app
installed=$HOME/Applications/Flick.app

install= release=
case ${1:-} in
    '') ;;
    --install) install=1 ;;
    --release) release=1 ;;
    *) print -u2 "usage: ./build.sh [--install | --release]"; exit 2 ;;
esac

# The Developer ID identity, by its SHA-1 hash: a name could match several
# certificates.
developer_id=$(security find-identity -v -p codesigning \
    | awk '/"Developer ID Application: / { print $2; exit }')

if [[ -n $release ]]; then
    if [[ -n $(git status --porcelain) ]]; then
        print -u2 "error: --release needs a clean tree, so the build matches a commit"
        exit 1
    fi
    if [[ -z $developer_id ]]; then
        print -u2 "error: no Developer ID Application identity in the keychain; create one in"
        print -u2 "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
        exit 1
    fi
    profile=${FLICK_NOTARY_PROFILE:-flick-notary}
    if ! xcrun notarytool history --keychain-profile $profile &>/dev/null; then
        print -u2 "error: no notarytool credentials in keychain profile $profile; see build.sh's header"
        exit 1
    fi
fi

function has_identity {
    security find-identity -p codesigning 2>/dev/null | grep -qF "\"$local_identity\""
}

# A self-signed code-signing certificate, imported with its key into the login
# keychain with codesign allowed to use the key. macOS's LibreSSL writes the
# PKCS#12 encryption `security import` reads; OpenSSL 3+ would need -legacy.
function create_identity {
    local tmp
    tmp=$(mktemp -d ${TMPDIR:-/tmp}/flick.XXXXXX)
    {
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=$local_identity \
            -addext keyUsage=critical,digitalSignature \
            -addext extendedKeyUsage=critical,codeSigning \
            -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
        /usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem \
            -out $tmp/identity.p12 -passout pass:$local_identity
        security import $tmp/identity.p12 -P $local_identity -T /usr/bin/codesign >/dev/null
    } always {
        rm -rf -- $tmp
    }
}

swift build -c release --product Flick
bin=$(swift build -c release --show-bin-path)/Flick

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin $app/Contents/MacOS/Flick
# The Icon Composer icon compiles to Assets.car, plus AppIcon.icns for Finder's
# flat renditions. actool ships with Xcode only, so the command-line tools
# build an app without an icon. Every path is absolute: actool hands the work to
# a long-lived agent that resolves relative paths against its own working
# directory, wherever it was first started.
if ! icon_log=$(xcrun actool $PWD/Resources/AppIcon.icon --compile $PWD/$app/Contents/Resources \
        --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 \
        --output-partial-info-plist $PWD/.build/AppIcon.plist --errors --warnings 2>&1); then
    print -u2 "$icon_log"
    print -u2 "warning: actool failed, so Flick.app has no icon; it needs Xcode"
fi
cp Resources/Info.plist $app/Contents/Info.plist
revision=$(git describe --always --dirty --abbrev=40 --match '' 2>/dev/null || print unknown)
plutil -insert FlickSourceRevision -string $revision $app/Contents/Info.plist
print -n 'APPL????' > $app/Contents/PkgInfo

if [[ -n $release ]]; then
    codesign --force --options runtime --timestamp --sign $developer_id $app
    codesign --verify --strict --deep $app
elif [[ -n $developer_id ]]; then
    # No secure timestamp: only notarization needs one, and it takes a network
    # round trip.
    codesign --force --options runtime --timestamp=none --sign $developer_id $app 2>&1 \
        | { grep -v 'replacing existing signature' >&2 || true }
else
    if ! has_identity; then
        print "Creating the $local_identity signing identity in the login keychain"
        create_identity
    fi
    codesign --force --sign $local_identity $app 2>&1 | { grep -v 'replacing existing signature' >&2 || true }
fi
print "Built $app"

if [[ -n $release ]]; then
    version=$(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist)
    zip=build/Flick-$version.zip
    # notarytool takes a zip; ditto keeps the bundle's symlinks and metadata.
    ditto -c -k --keepParent $app $zip
    print "Submitting $zip for notarization"
    result=$(xcrun notarytool submit $zip --keychain-profile $profile --wait --output-format json)
    notary_status=$(plutil -extract status raw - <<< $result)
    if [[ $notary_status != Accepted ]]; then
        print -u2 "error: notarization $notary_status; the log says why:"
        xcrun notarytool log $(plutil -extract id raw - <<< $result) --keychain-profile $profile >&2
        exit 1
    fi
    # Staple the ticket so Gatekeeper accepts the app offline, then zip it again.
    xcrun stapler staple $app
    rm -f $zip
    ditto -c -k --keepParent $app $zip
    spctl --assess --type execute -vv $app
    print "Notarized $zip"
fi

[[ -n $install ]] || exit 0
for pid in $(pgrep -x Flick || true); do kill $pid; done
mkdir -p ${installed:h}
rm -rf $installed
ditto $app $installed
open $installed
print "Installed and launched $installed"
