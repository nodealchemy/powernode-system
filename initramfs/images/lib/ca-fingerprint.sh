#!/usr/bin/env bash
# ca_fingerprint_from_pem FILE
#
# Prints the powernode-provision CA pin ("sha256:<64 lowercase hex>") of FILE:
# sha256 over the DER of the LAST certificate of the bundle, which must be a
# self-signed CA. This is the same rule as System::ProvisioningDocument
# (fingerprint_for) and the agent's pin (identity.CertFingerprint), so a pin
# baked into BOOT identity.cfg equals the pin in every provisioning document.
# Returns non-zero (message on stderr, nothing on stdout) when the bundle holds
# no certificate or the last one is not a self-signed CA.
ca_fingerprint_from_pem() {
  local f="${1:-}" tmp last fp subj iss
  [[ -n "$f" && -f "$f" ]] || { echo "ca_fingerprint_from_pem: no such file: $f" >&2; return 1; }
  command -v openssl >/dev/null || { echo "ca_fingerprint_from_pem: openssl is required" >&2; return 1; }
  tmp="$(mktemp -d)" || return 1
  awk -v d="$tmp" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/c%04d.pem", d, n) }
    out { print > out }
    /-----END CERTIFICATE-----/   { out = "" }' "$f"
  last="$(find "$tmp" -name 'c*.pem' | sort | tail -n 1)"
  if [[ -z "$last" ]]; then
    rm -rf "$tmp"; echo "ca_fingerprint_from_pem: no certificate in $f" >&2; return 1
  fi
  subj="$(openssl x509 -in "$last" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject= *//')"
  iss="$(openssl x509 -in "$last" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer= *//')"
  if [[ -z "$subj" || "$subj" != "$iss" ]] \
     || ! openssl x509 -in "$last" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
     || ! openssl verify -CAfile "$last" "$last" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "ca_fingerprint_from_pem: the last certificate of $f must be a self-signed CA (bundle ordered anchor-last)" >&2
    return 1
  fi
  fp="$(openssl x509 -in "$last" -outform DER | sha256sum | cut -d' ' -f1)"
  rm -rf "$tmp"
  printf 'sha256:%s\n' "$fp"
}
