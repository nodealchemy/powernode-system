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

.PHONY: stage-agent stage-agent-amd64 stage-agent-arm64 tarball clean

stage-agent: stage-agent-$(ARCH)

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
	rm -rf $(DIST_DIR)
