# HashiCorp Vault — TEST instance configuration.
#
# PROTECTED FILE: listed in the module's protected_spec, so a module refresh
# will NOT overwrite operator edits made on the node. Edit it in place.
#
# This config starts Vault SEALED. There is deliberately no auto-unseal and no
# initialisation here: `vault operator init` emits unseal keys and a root
# token, which are key material and belong to the operator, never to a module,
# a script, a log line or a transcript.

ui = false

# LOOPBACK ONLY, and tls_disable is only defensible BECAUSE of that.
#
# To let the platform (ops-hub) reach this Vault you must change BOTH of these
# together, in this order:
#   1. obtain a real certificate for the node and set tls_cert_file /
#      tls_key_file below, REMOVING tls_disable;
#   2. change the address to the node's SDWAN/private address and add the
#      matching exposed_ports entry to the module manifest.
# Doing (2) without (1) publishes an unauthenticated plaintext secrets API onto
# the overlay network. There is no scenario in which that is the right order.
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1

  # tls_cert_file = "/persist/etc/vault/tls/vault.crt"
  # tls_key_file  = "/persist/etc/vault/tls/vault.key"
}

# File storage under /persist because that is what survives.
# /var is not shipped in the module erofs and materialises into the overlay's
# writable upper layer; a soft-reboot preserves only /run. Storage anywhere
# else means the seal state and every stored secret vanish on the next reboot,
# which would look exactly like data loss rather than a misconfiguration.
storage "file" {
  path = "/persist/var/lib/vault/data"
}

# Must match how a client actually addresses this node. Left at loopback to
# agree with the listener above; change it in the same edit that changes the
# listener, or Vault will advertise an address nothing can reach.
api_addr = "http://127.0.0.1:8200"

# mlock stays ENABLED (the module grants CAP_IPC_LOCK for it). Setting
# disable_mlock = true would let the kernel page Vault's in-memory secrets to
# swap; it is not a tuning knob, it is a downgrade.
disable_mlock = false

# Audit devices are NOT enabled here: `vault audit enable` is a post-unseal
# operation against a running, initialised Vault, so it cannot live in this
# file. Enabling one is a step in the runbook, and on a real deployment it is
# not optional.
