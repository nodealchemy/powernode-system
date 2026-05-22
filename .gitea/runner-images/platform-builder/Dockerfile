# Gitea Actions runner image for build-platform-modules.yaml
#
# The Gitea runner ships a Debian-based default image without the
# supply-chain toolchain we need to assemble Powernode platform modules
# (buildah, mkcomposefs, fsverity, cosign, oras). Each per-matrix-entry
# `apt install` adds 30+ seconds of overhead and runs into checkout
# bootstrap issues (no git in the base image). A pre-baked image solves
# both: instant tool availability + working checkout.
#
# Build:
#   docker build -t git.ipnode.org/powernode/runner-platform-builder:latest \
#     extensions/system/.gitea/runner-images/platform-builder/
#
# Push:
#   docker login git.ipnode.org -u <gitea-user> -p <gitea-PAT-with-package:write>
#   docker push git.ipnode.org/powernode/runner-platform-builder:latest
#
# Reference from a workflow:
#   container:
#     image: git.ipnode.org/powernode/runner-platform-builder:latest

FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# Core: checkout deps (git, ca-certs), apt utilities, common scripting
# tools (jq, python3, rsync). Buildah + composefs + fsverity-utils from
# Ubuntu noble universe — these are why we ditched the bare runner image.
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      bash \
      coreutils \
      tar \
      gzip \
      buildah \
      composefs \
      fsverity-utils \
      jq \
      rsync \
      python3 \
      python3-yaml \
      iproute2 \
      && rm -rf /var/lib/apt/lists/*

# cosign — Sigstore keyless signing. Pinned to a known-good release.
ARG COSIGN_VERSION=2.4.1
RUN curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
      -o /usr/local/bin/cosign && \
    chmod +x /usr/local/bin/cosign

# oras — OCI Registry as Storage. Pin to 1.2.0 (matches the
# `oras push --artifact-type` flag shape the workflow uses).
ARG ORAS_VERSION=1.2.0
RUN curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin oras && \
    chmod +x /usr/local/bin/oras

# Buildah default storage driver — vfs is rootless-safe and CI-friendly
# (overlayfs needs kernel features the runner container may not have).
RUN mkdir -p /etc/containers && \
    printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf

# Sanity check — surface install failures at build time, not workflow time.
RUN git --version && \
    buildah --version && \
    mkcomposefs --version || true && \
    fsverity --version && \
    cosign version | head -1 && \
    oras version | head -1 && \
    jq --version && \
    python3 -c 'import yaml; print("yaml:", yaml.__version__)'

LABEL org.opencontainers.image.title="Powernode Gitea Runner — Platform Builder" \
      org.opencontainers.image.description="Base image for build-platform-modules workflow. Includes buildah, composefs, fsverity, cosign, oras." \
      org.opencontainers.image.source="https://github.com/nodealchemy/powernode-system" \
      org.opencontainers.image.licenses="MIT"
