# nginx

nginx 1.24 example service module for the Powernode smoke-test stack.

| File | Purpose |
|---|---|
| `/etc/nginx/sites-available/default` | HTTP vhost on port 80, secure headers, `/healthz` endpoint |
| `/var/www/html/index.html` | Welcome page proving the module attached |

Depends on `system-base@^1.0` (provides systemd, networkd, sshd). Conflicts with `apache` (both expose `http.port:80`) — the dependency resolver enforces single-server-per-template.

## License

MIT
