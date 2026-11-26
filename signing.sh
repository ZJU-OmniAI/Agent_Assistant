#!/bin/bash
# Sign an app bundle with a long-lived local identity.
#
# macOS stores the Accessibility grant against the app's designated requirement.
# An ad-hoc signature makes that requirement a cdhash, so every rebuild silently
# loses the grant while System Settings still shows the switch as on. A fixed
# self-signed certificate keeps the requirement stable across rebuilds.
set -euo pipefail

bundle=$1
name="Agent Assistant Local Signing"
dir="${AGENT_ASSISTANT_SIGNING_DIR:-$HOME/.agent-assistant/signing}"
keychain="$dir/signing.keychain-db"
secret="$dir/keychain-password"

if [ ! -f "$keychain" ]; then
    mkdir -p "$dir"
    chmod 700 "$dir"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    (umask 077 && openssl rand -hex 24 >"$secret")
    cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$name
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    transport=$(openssl rand -hex 12)
    openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/id.p12" -passout "pass:$transport" 2>/dev/null ||
        openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
            -out "$work/id.p12" -passout "pass:$transport"
    security create-keychain -p "$(cat "$secret")" "$keychain"
    security set-keychain-settings "$keychain"
    security unlock-keychain -p "$(cat "$secret")" "$keychain"
    security import "$work/id.p12" -k "$keychain" -P "$transport" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$secret")" "$keychain" >/dev/null
    rm -rf "$work"
    trap - EXIT
    echo "已创建本机签名证书：${name}（${keychain}）"
fi

security unlock-keychain -p "$(cat "$secret")" "$keychain"
identity=$(security find-identity -p codesigning "$keychain" | awk -v n="\"$name\"" 'index($0, n) {print $2; exit}')
[ -n "$identity" ] || { echo "签名证书缺失：${keychain}" >&2; exit 1; }

# codesign resolves the certificate through the user search list. Add the
# signing keychain only for this call and put the original list back.
list=()
while IFS= read -r line; do
    line=${line#*\"}
    list+=("${line%\"*}")
done < <(security list-keychains -d user)
restore() { security list-keychains -d user -s "${list[@]}"; }
trap restore EXIT
security list-keychains -d user -s "${list[@]}" "$keychain"
codesign --force --keychain "$keychain" --sign "$identity" "$bundle"
