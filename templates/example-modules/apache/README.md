# apache

Apache 2.4 (mpm_event) example service module for the Powernode smoke-test stack.

| File | Purpose |
|---|---|
| `/etc/apache2/sites-available/000-powernode.conf` | Default vhost on port 80, secure headers, no indexes |
| `/var/www/html/index.html` | Welcome page proving the module attached |

Depends on `system-base@^1.0` (provides systemd, networkd, sshd).

## License

MIT
