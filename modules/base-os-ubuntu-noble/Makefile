# system-base module — agent staging + module packaging
#
# The agent binary (/usr/sbin/powernode-agent in the rootfs) is built from
# extensions/system/agent/ and staged into this module's rootfs by the
# `stage-agent` target. The Gitea workflow .gitea/workflows/update-system-base.yaml
# runs this on every push that touches agent/** so the on-rootfs binary
# stays in lockstep with the agent source.
#
# Targets:
#   stage-agent[-ARCH]   build agent for ARCH (default amd64) + place at
#                        rootfs/usr/sbin/powernode-agent
#   tarball              produce a tar.gz of the rootfs + manifest under dist/
#                        (consumed by the platform's module ingest pipeline)
#   clean                rm staged binary + dist/
#
# The binary is gitignored — it's a build product, not source. Local dev:
#   make stage-agent && make tarball

MODULE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
AGENT_DIR  := $(abspath $(MODULE_DIR)/../../../agent)
ROOTFS_DIR := $(MODULE_DIR)/rootfs
DIST_DIR   := $(MODULE_DIR)/dist

ARCH ?= amd64

# Pinned cosign release staged at rootfs/usr/bin/cosign for on-node UKI signature
# verification (campaign 019f505f inc 2 — the upgrade_boot_image handler shells
# out to it). The fetch verifies the checksum and FAILS the build on mismatch: a
# node must never ship an unverified verifier. Bump COSIGN_VERSION + BOTH
# checksums together from the sigstore/cosign release (sha256 of the official
# cosign-linux-<arch> asset).
COSIGN_VERSION      ?= 3.0.6
COSIGN_SHA256_amd64 ?= c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
COSIGN_SHA256_arm64 ?= bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8

.PHONY: stage-agent stage-agent-amd64 stage-agent-arm64 stage-cosign tarball clean

# stage-agent also stages cosign so the existing CI (update-system-base.yaml),
# which invokes `make stage-agent`, ships both without a workflow change.
stage-agent: stage-agent-$(ARCH) stage-cosign

stage-cosign:
	@want=$(COSIGN_SHA256_$(ARCH)); \
	[ -n "$$want" ] || { echo "ERROR: no pinned cosign sha256 for ARCH=$(ARCH)"; exit 1; }; \
	mkdir -p $(ROOTFS_DIR)/usr/bin; \
	out=$(ROOTFS_DIR)/usr/bin/cosign; \
	url="https://github.com/sigstore/cosign/releases/download/v$(COSIGN_VERSION)/cosign-linux-$(ARCH)"; \
	echo "fetching cosign v$(COSIGN_VERSION) $(ARCH): $$url"; \
	curl -fsSL "$$url" -o "$$out"; \
	got=$$(sha256sum "$$out" | awk '{print $$1}'); \
	[ "$$got" = "$$want" ] || { echo "FATAL: cosign sha256 mismatch (want $$want got $$got)"; rm -f "$$out"; exit 1; }; \
	chmod +x "$$out"; \
	echo "staged cosign v$(COSIGN_VERSION) $(ARCH) → $$out"

stage-agent-amd64:
	$(MAKE) -C $(AGENT_DIR) build-amd64
	mkdir -p $(ROOTFS_DIR)/usr/sbin
	cp $(AGENT_DIR)/dist/powernode-agent-linux-amd64 \
	   $(ROOTFS_DIR)/usr/sbin/powernode-agent
	chmod +x $(ROOTFS_DIR)/usr/sbin/powernode-agent
	@echo "staged amd64 agent → $(ROOTFS_DIR)/usr/sbin/powernode-agent"

stage-agent-arm64:
	$(MAKE) -C $(AGENT_DIR) build-arm64
	mkdir -p $(ROOTFS_DIR)/usr/sbin
	cp $(AGENT_DIR)/dist/powernode-agent-linux-arm64 \
	   $(ROOTFS_DIR)/usr/sbin/powernode-agent
	chmod +x $(ROOTFS_DIR)/usr/sbin/powernode-agent
	@echo "staged arm64 agent → $(ROOTFS_DIR)/usr/sbin/powernode-agent"

# tarball assumes stage-agent has run (or the rootfs is otherwise complete).
# Output filename includes the agent version + arch so multiple builds can
# coexist in dist/ without clobbering.
tarball:
	@test -x $(ROOTFS_DIR)/usr/sbin/powernode-agent || \
	  (echo "ERROR: rootfs/usr/sbin/powernode-agent missing — run 'make stage-agent' first"; exit 1)
	mkdir -p $(DIST_DIR)
	AGENT_VER=$$(cd $(AGENT_DIR) && git describe --tags --always --dirty 2>/dev/null || echo dev); \
	TARBALL=$(DIST_DIR)/system-base-$$AGENT_VER-$(ARCH).tar.gz; \
	tar -czf $$TARBALL \
	  --owner=0 --group=0 \
	  -C $(MODULE_DIR) manifest.yaml rootfs; \
	sha256sum $$TARBALL | awk -v f=$$TARBALL '{print $$1"  "f".sha256"}' > $$TARBALL.sha256; \
	echo "tarball: $$TARBALL"; \
	echo "sha256:  $$(awk "{print \$$1}" $$TARBALL.sha256)"

clean:
	rm -f $(ROOTFS_DIR)/usr/sbin/powernode-agent
	rm -f $(ROOTFS_DIR)/usr/bin/cosign
	rm -rf $(DIST_DIR)
