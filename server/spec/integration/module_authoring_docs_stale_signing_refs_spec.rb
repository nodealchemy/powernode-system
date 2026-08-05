# frozen_string_literal: true

require "rails_helper"

# Repo-hygiene check: module-authoring docs must not describe keyless
# Sigstore Fulcio/OIDC signing as the mechanism the bundled Gitea module-repo
# template uses. Gitea Actions was never on Fulcio's trusted-issuer list (see
# the comment in module_oci_ingest_service.rb's OrasOciAdapter#verify_signature),
# and templates/module-repo/.gitea/workflows/build.yaml signs with a static
# cosign key (POWERNODE_COSIGN_PRIVATE_KEY / POWERNODE_COSIGN_PUBLIC_KEY) in
# its `assemble` job. Keyless/Fulcio signing only verifies for modules built
# on an actually Fulcio-trusted CI (e.g. GitHub Actions) — not this template.
#
# Reproduces IMP-dccab83db4ac — docs/runbooks/module-authoring.md and
# docs/tutorials/02-first-module.md still described the worked example as
# keyless-via-Fulcio.
RSpec.describe "module-authoring docs stale keyless-signing references" do
  ext_root = File.expand_path("../../..", __dir__)
  # Scoped to the two docs the finding names — NOT all of docs/**. The
  # sibling disk-image-CI docs (docs/runbooks/disk-image-ci.md,
  # docs/tutorials/12-disk-image-ci.md) describe a structurally different
  # pipeline that genuinely attempts keyless cosign sign-blob today; whether
  # that's also stale is a separate, untriaged question (queued, not fixed
  # here — see IMP-dccab83db4ac follow-up).
  target_docs = [
    File.join(ext_root, "docs", "runbooks", "module-authoring.md"),
    File.join(ext_root, "docs", "tutorials", "02-first-module.md")
  ]

  # Single-line-safe patterns — matched line-by-line so violations report a
  # precise line number.
  forbidden = {
    /Cosign keyless signing/ => "runbook intro still describes the worked example as keyless signing",
    /Sign with Cosign \(keyless\)/ => "worked CI snippet still shows a keyless cosign sign step",
    /keyless signing via Sigstore Fulcio/ => "still describes keyless-via-Fulcio as what the bundled template does",
    /ephemeral OIDC-bound certs tied to the Gitea Actions OIDC issuer/ => "still claims ephemeral OIDC certs are how the bundled template signs",
    /Verify the Gitea Actions OIDC URL matches your regexp/ => "troubleshooting still assumes the OIDC/keyless path is the default",
    /keyless via Fulcio/ => "diagram/prose still labels the sign step as keyless via Fulcio"
  }

  # Prose that wraps across lines in the source Markdown — matched against
  # the whole file with runs of whitespace collapsed, so a mid-phrase line
  # break can't hide a still-stale claim.
  forbidden_wrapped = {
    /Sigstore Fulcio issues an ephemeral cert bound to the Gitea Actions OIDC token/ => "still describes Fulcio-issued ephemeral certs as what the bundled template does",
    /Edit the module record's regex fields to match the Gitea Actions OIDC subject/ => "troubleshooting still treats the OIDC identity/issuer regex as the default-path fix"
  }

  it "does not describe the bundled Gitea template's signing as keyless/Fulcio" do
    violations = []

    target_docs.sort.each do |md_path|
      rel = md_path.delete_prefix("#{ext_root}/")
      content = File.read(md_path)

      content.each_line.with_index do |line, idx|
        forbidden.each do |pattern, desc|
          violations << "#{rel}:#{idx + 1} — #{desc}" if line.match?(pattern)
        end
      end

      normalized = content.gsub(/\s+/, " ")
      forbidden_wrapped.each do |pattern, desc|
        violations << "#{rel} — #{desc}" if normalized.match?(pattern)
      end
    end

    expect(violations).to(
      be_empty,
      "Module-authoring docs still describe keyless/Fulcio signing as the bundled " \
      "template's mechanism (it signs with a static cosign key — see " \
      "templates/module-repo/.gitea/workflows/build.yaml's `assemble` job):\n" \
      "#{violations.join("\n")}"
    )
  end

  # ---------------------------------------------------------------------------
  # SECOND AXIS — the BUILD ARCHITECTURE (IMP-b57eaf3017f2).
  #
  # These same two documents were found stale a second time, independently of
  # signing: they described a buildah/mkcomposefs pipeline built from a
  # `ghcr.io/powernode/module-builder` base image. None of that is what runs.
  # The platform pipeline is mmdebstrap + mkfs.erofs:
  #   .gitea/workflows/build-platform-modules.yaml:85-90 — "mmdebstrap replaces
  #     buildah for the rootfs build step" (buildah needed CLONE_NEWUSER, which
  #     the Gitea Actions container cannot grant)
  #   :228 Stage 1 → scripts/module-build/stage1-rootfs.sh (mmdebstrap)
  #   :256 Stage 2 → rsync filter + mkfs.erofs + fs-verity
  # and templates/module-repo/Containerfile — the THIRD-PARTY per-repo path —
  # is `FROM docker.io/library/ubuntu@${UBUNTU_DIGEST}` with apt, not a
  # powernode-published builder image with an entrypoint.
  #
  # Deliberately a second example rather than more entries in the map above:
  # the two axes fail with different explanations, and a third axis should be
  # added here rather than as a third spec file.
  #
  # SCOPED TO THE DOCS ONLY, NOT the workflow. build-platform-modules.yaml
  # names buildah legitimately — in the comment explaining why it was
  # abandoned — and forbidding a word that is needed to explain its own
  # absence would make the guard unmaintainable.
  forbidden_build = {
    /buildah/ => "still names buildah; the rootfs step is mmdebstrap (see the workflow's own :85-90 note)",
    /mkcomposefs/ => "still names mkcomposefs; Stage 2 runs mkfs.erofs",
    %r{ghcr\.io/powernode/module-builder} => "still points at a powernode-published builder image that does not exist",
    %r{/usr/local/bin/build-module} => "still shows a build-module entrypoint; the builder image has no entrypoint"
  }

  it "does not describe the module build as buildah/mkcomposefs from a published builder image" do
    violations = []

    target_docs.sort.each do |md_path|
      rel = md_path.delete_prefix("#{ext_root}/")

      File.read(md_path).each_line.with_index do |line, idx|
        forbidden_build.each do |pattern, desc|
          violations << "#{rel}:#{idx + 1} — #{desc}" if line.match?(pattern)
        end
      end
    end

    expect(violations).to(
      be_empty,
      "Module-authoring docs still describe a build architecture the pipeline does " \
      "not use (it is mmdebstrap + mkfs.erofs — see " \
      ".gitea/workflows/build-platform-modules.yaml:85-90, :228, :256):\n" \
      "#{violations.join("\n")}"
    )
  end
end
