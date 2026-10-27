#!/bin/zsh
# Builds build/Flick.app; with --install, also replaces ~/Applications/Flick.app
# and relaunches it.
#
#   ./build.sh [--install]
#
# The bundle's FlickSourceRevision records the commit it was built from, with
# "-dirty" for uncommitted changes, so an installer can tell when the installed
# app is current:
#
#   plutil -extract FlickSourceRevision raw ~/Applications/Flick.app/Contents/Info.plist
#
# Signed with flick-local, a self-signed code-signing certificate this creates
# in the login keychain once. macOS keys the Accessibility grant to the
# signature's designated requirement — `identifier "info.junz.flick" and
# certificate leaf = H"..."` — which every rebuild still satisfies; an ad-hoc
# signature would lose the grant on each rebuild. The identity needs no trust
# setting: codesign signs with it and the requirement checks only the leaf hash.
set -euo pipefail
cd ${0:A:h}

identity=flick-local
app=build/Flick.app
installed=$HOME/Applications/Flick.app

install=
case ${1:-} in
    '') ;;
    --install) install=1 ;;
    *) print -u2 "usage: ./build.sh [--install]"; exit 2 ;;
esac

function has_identity {
    security find-identity -p codesigning 2>/dev/null | grep -qF "\"$identity\""
}

# A self-signed code-signing certificate, imported with its key into the login
# keychain with codesign allowed to use the key. macOS's LibreSSL writes the
# PKCS#12 encryption `security import` reads; OpenSSL 3+ would need -legacy.
function create_identity {
    local tmp
    tmp=$(mktemp -d ${TMPDIR:-/tmp}/flick.XXXXXX)
    {
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=$identity \
            -addext keyUsage=critical,digitalSignature \
            -addext extendedKeyUsage=critical,codeSigning \
            -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
        /usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem \
            -out $tmp/identity.p12 -passout pass:$identity
        security import $tmp/identity.p12 -P $identity -T /usr/bin/codesign >/dev/null
    } always {
        rm -rf -- $tmp
    }
}

swift build -c release --product Flick
bin=$(swift build -c release --show-bin-path)/Flick

rm -rf $app
mkdir -p $app/Contents/MacOS
cp $bin $app/Contents/MacOS/Flick
cp Resources/Info.plist $app/Contents/Info.plist
revision=$(git describe --always --dirty --abbrev=40 --match '' 2>/dev/null || print unknown)
plutil -insert FlickSourceRevision -string $revision $app/Contents/Info.plist
print -n 'APPL????' > $app/Contents/PkgInfo

if ! has_identity; then
    print "Creating the $identity signing identity in the login keychain"
    create_identity
fi
codesign --force --sign $identity $app 2>&1 | { grep -v 'replacing existing signature' >&2 || true }
print "Built $app"

[[ -n $install ]] || exit 0
for pid in $(pgrep -x Flick || true); do kill $pid; done
mkdir -p ${installed:h}
rm -rf $installed
ditto $app $installed
open $installed
print "Installed and launched $installed"
