#!/usr/bin/env bash
# Self-test for lib/ca-fingerprint.sh: bash initramfs/images/lib/test-ca-fingerprint.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ca-fingerprint.sh
source "$HERE/ca-fingerprint.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mk() { # name signer(optional)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
    -subj "/CN=$1" -addext basicConstraints=critical,CA:TRUE -keyout "$T/$1.key" -out "$T/$1.pem" 2>/dev/null
}
mk root
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=inter" -keyout "$T/inter.key" -out "$T/inter.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE\n' >"$T/ext"
openssl x509 -req -in "$T/inter.csr" -CA "$T/root.pem" -CAkey "$T/root.key" -CAcreateserial -days 2 -extfile "$T/ext" -out "$T/inter.pem" 2>/dev/null

want="sha256:$(openssl x509 -in "$T/root.pem" -outform DER | sha256sum | cut -d' ' -f1)"
got="$(ca_fingerprint_from_pem "$T/root.pem")" || fail "single root"
[[ "$got" == "$want" ]] || fail "single root: $got != $want"
[[ "$got" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "format $got"

cat "$T/inter.pem" "$T/root.pem" >"$T/chain.pem"            # anchor-last
got="$(ca_fingerprint_from_pem "$T/chain.pem")" || fail "anchor-last chain"
[[ "$got" == "$want" ]] || fail "anchor-last chain pin is not the root's"

cat "$T/root.pem" "$T/inter.pem" >"$T/rev.pem"              # anchor-first: last is not self-signed
if ca_fingerprint_from_pem "$T/rev.pem" >/dev/null 2>&1; then fail "anchor-first bundle must be refused"; fi
: >"$T/empty.pem"
if ca_fingerprint_from_pem "$T/empty.pem" >/dev/null 2>&1; then fail "empty bundle must be refused"; fi
echo "ok"
