# chrony module

NTP client for Powernode nodes. Priority 30 (between system-base and service tier).

## Why protected_spec?

`/etc/chrony/chrony.conf` defines the NTP trust anchor — i.e., which servers
this node believes when adjusting its clock. A higher-priority service module
that shipped a different `chrony.conf` could silently redirect the node to a
malicious time source, which is a classic stepping stone for attacking
TLS validity windows, log integrity, and Kerberos tickets.

Putting `chrony.conf` on the `protected_spec` list ensures the build pipeline
refuses to ship that path inside any higher-priority neighbor's blob.
The only legitimate way to override it is via a dependant child module
(`parent_module_id` -> this module's id) which goes through the operator's
explicit approval surface.
