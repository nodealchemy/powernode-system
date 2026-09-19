# frozen_string_literal: true

require "rails_helper"
require "yaml"

# IMP-94977647c24c — the shipped root-user-exceptions registry, checked
# against the real manifests it documents. System::ModuleRootUserPolicy
# itself is unit-tested (fixture-based, both arms) in
# spec/services/system/module_root_user_policy_spec.rb; this spec proves
# the REAL registry + REAL shipped manifests actually comply today, the
# same "checked against shipped files" shape module_manifest_verify_spec.rb
# uses for the verify: block.
RSpec.describe "module manifest: root-user-exceptions registry" do
  extension_root     = File.expand_path("../../..", __dir__)
  exceptions_path    = File.join(extension_root, "modules/.schema/root-user-exceptions.yml")
  hub_worker_path    = File.join(extension_root, "modules/powernode-hub-worker/manifest.yaml")
  hub_backend_path   = File.join(extension_root, "modules/powernode-hub-backend/manifest.yaml")

  let(:exceptions) { YAML.safe_load(File.read(exceptions_path)) }

  it "is present and shaped as module -> service -> {reason, task, review_by}" do
    expect(exceptions).to be_a(Hash)
    expect(exceptions).to have_key("powernode-hub-worker")
  end

  # Every review_by in the shipped registry, checked with a message that
  # names what actually needs re-checking — not just "a date failed a
  # comparison". A bare `violations` assertion would already catch an
  # expired date; this makes the CI failure legible without opening the
  # registry file first.
  describe "no exception's review_by has passed" do
    it "hub-worker (sidekiq, worker-web): re-verify the polkit prerequisite (systemd-run via polkit-granted org.freedesktop.systemd1.manage-units) is still unmet before renewing" do
      manifest = YAML.safe_load(File.read(hub_worker_path))
      violations = System::ModuleRootUserPolicy.violations(manifest, exceptions).select { |v| v.include?("review_by") }

      expect(violations).to be_empty, violations.join("; ")
    end
  end

  describe "powernode-hub-worker (the recorded, standing exception)" do
    manifest = YAML.safe_load(File.read(hub_worker_path))

    it "declares user: root on both services (sidekiq, worker-web) — the exception is FOR something real" do
      root_services = manifest["services"].select { |s| s["user"] == "root" }.map { |s| s["name"] }
      expect(root_services).to contain_exactly("sidekiq", "worker-web")
    end

    it "passes System::ModuleRootUserPolicy with the shipped registry" do
      expect(System::ModuleRootUserPolicy.violations(manifest, exceptions)).to be_empty
    end

    it "would fail the moment the exception entries are removed (registry, not just root usage, is load-bearing)" do
      expect(System::ModuleRootUserPolicy.violations(manifest, {})).not_to be_empty
    end
  end

  # TRANSIENT, mirrors the powernode-hub-backend entry in
  # root-user-exceptions.yml: part (A) is implemented and under review but
  # not yet landed, so rails still runs as root today. This whole
  # `describe` — and the registry entry it checks — is removed in the
  # same commit that switches rails' `user:` away from root.
  describe "powernode-hub-backend (TRANSIENT exception, pending part A)" do
    manifest = YAML.safe_load(File.read(hub_backend_path))

    it "still declares user: root on rails (remove this whole example when part A lands)" do
      root_services = manifest["services"].select { |s| s["user"] == "root" }.map { |s| s["name"] }
      expect(root_services).to include("rails")
    end

    it "passes System::ModuleRootUserPolicy with the shipped registry" do
      expect(System::ModuleRootUserPolicy.violations(manifest, exceptions)).to be_empty
    end
  end
end
