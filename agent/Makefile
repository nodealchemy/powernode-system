# Powernode Agent — Makefile
#
# Targets:
#   build        cross-compile static binaries for amd64 + arm64 → dist/
#   build-amd64  amd64 only
#   build-arm64  arm64 only
#   test         go test ./...
#   lint         golangci-lint run
#   vet          go vet ./...
#   clean        rm -rf dist/

VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GIT_COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS := -s -w \
  -X main.Version=$(VERSION) \
  -X main.GitCommit=$(GIT_COMMIT) \
  -X main.BuildDate=$(BUILD_DATE)

.PHONY: build build-amd64 build-arm64 build-acme build-acme-amd64 build-acme-arm64 vendor-traefik vendor-traefik-amd64 vendor-traefik-arm64 clean-traefik bump-traefik test lint vet clean

build: build-amd64 build-arm64 build-acme vendor-traefik

build-amd64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/powernode-agent-linux-amd64 \
	  ./cmd/powernode-agent

build-arm64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/powernode-agent-linux-arm64 \
	  ./cmd/powernode-agent

# powernode-acme — self-contained ACME client (P2.5.7). Sibling binary
# that Rails (Acme::LegoClient) shells out to for cert issuance. Built
# alongside powernode-agent so the platform ships everything it needs
# without host-side installs.
build-acme: build-acme-amd64 build-acme-arm64

build-acme-amd64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/powernode-acme-linux-amd64 \
	  ./cmd/powernode-acme

build-acme-arm64:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
	  -ldflags='$(LDFLAGS)' -trimpath \
	  -o dist/powernode-acme-linux-arm64 \
	  ./cmd/powernode-acme

# Traefik — vendored as the platform's reverse proxy (P2.5.11). We don't
# build it from source (Traefik's a complete program, not a library); we
# download the upstream release binary and ship it alongside our own Go
# binaries. The pinned version is reviewed + bumped via the
# `bump-traefik` target.
TRAEFIK_VERSION ?= v3.3.2
TRAEFIK_BASE_URL = https://github.com/traefik/traefik/releases/download/$(TRAEFIK_VERSION)

vendor-traefik: vendor-traefik-amd64 vendor-traefik-arm64

vendor-traefik-amd64:
	mkdir -p dist
	@if [ ! -f dist/powernode-reverse-proxy-linux-amd64 ]; then \
	  echo "Downloading Traefik $(TRAEFIK_VERSION) linux/amd64..."; \
	  tmp=$$(mktemp -d) && \
	  curl -sSL "$(TRAEFIK_BASE_URL)/traefik_$(TRAEFIK_VERSION)_linux_amd64.tar.gz" -o $$tmp/t.tar.gz && \
	  tar -xzf $$tmp/t.tar.gz -C $$tmp traefik && \
	  install -m 0755 $$tmp/traefik dist/powernode-reverse-proxy-linux-amd64 && \
	  rm -rf $$tmp; \
	else \
	  echo "dist/powernode-reverse-proxy-linux-amd64 already present (version unverified — run 'make clean-traefik' to refresh)"; \
	fi

vendor-traefik-arm64:
	mkdir -p dist
	@if [ ! -f dist/powernode-reverse-proxy-linux-arm64 ]; then \
	  echo "Downloading Traefik $(TRAEFIK_VERSION) linux/arm64..."; \
	  tmp=$$(mktemp -d) && \
	  curl -sSL "$(TRAEFIK_BASE_URL)/traefik_$(TRAEFIK_VERSION)_linux_arm64.tar.gz" -o $$tmp/t.tar.gz && \
	  tar -xzf $$tmp/t.tar.gz -C $$tmp traefik && \
	  install -m 0755 $$tmp/traefik dist/powernode-reverse-proxy-linux-arm64 && \
	  rm -rf $$tmp; \
	fi

clean-traefik:
	rm -f dist/powernode-reverse-proxy-linux-amd64 dist/powernode-reverse-proxy-linux-arm64

# Bump the pinned Traefik version. Verifies the upstream release exists,
# rewrites TRAEFIK_VERSION in this Makefile, removes the old vendored
# binaries, and re-vendors. Run a smoke test after.
#
# Usage:   make bump-traefik NEW=v3.3.3
# Runbook: ../docs/runbooks/vendored-binary-bump.md
bump-traefik:
	@[ -n "$(NEW)" ] || (echo "Usage: make bump-traefik NEW=vX.Y.Z"; exit 1)
	@echo "Bumping Traefik $(TRAEFIK_VERSION) → $(NEW)"
	@curl -fsSL "https://github.com/traefik/traefik/releases/download/$(NEW)/traefik_$(NEW)_checksums.txt" -o /tmp/traefik-bump-checksums.txt \
	  || (echo "FATAL: upstream release $(NEW) not found at github.com/traefik/traefik/releases"; exit 1)
	@grep -q "traefik_$(NEW)_linux_amd64.tar.gz" /tmp/traefik-bump-checksums.txt \
	  || (echo "FATAL: linux/amd64 asset missing from $(NEW) release"; exit 1)
	@grep -q "traefik_$(NEW)_linux_arm64.tar.gz" /tmp/traefik-bump-checksums.txt \
	  || (echo "FATAL: linux/arm64 asset missing from $(NEW) release"; exit 1)
	@sed -i.bak 's/^TRAEFIK_VERSION ?=.*/TRAEFIK_VERSION ?= $(NEW)/' Makefile && rm -f Makefile.bak
	@$(MAKE) clean-traefik
	@$(MAKE) vendor-traefik
	@rm -f /tmp/traefik-bump-checksums.txt
	@echo ""
	@echo "✓ Bumped to $(NEW). Next steps:"
	@echo "  1. file dist/powernode-reverse-proxy-linux-{amd64,arm64}"
	@echo "  2. Smoke test: deploy powernode-reverse-proxy module to a NodeInstance"
	@echo "  3. Commit Makefile + run 'git diff' to confirm only TRAEFIK_VERSION changed"

# Add powernode-reverse-proxy to the top-level `make build` so the
# platform's build artifact is complete without separate steps.

test:
	go test -race ./...

lint:
	golangci-lint run

vet:
	go vet ./...

clean:
	rm -rf dist/
