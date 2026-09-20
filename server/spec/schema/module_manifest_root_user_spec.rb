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

  # IMP-94977647c24c part A landed: rails runs as the dedicated
  # powernode-rails user (see the manifest's users:/services:), not root
  # — no exception needed, and none is recorded for this module anymore.
  describe "powernode-hub-backend (root dropped, part A)" do
    manifest = YAML.safe_load(File.read(hub_backend_path))

    it "does not declare user: root on any service" do
      root_services = manifest["services"].select { |s| s["user"] == "root" }.map { |s| s["name"] }
      expect(root_services).to be_empty
    end

    it "declares rails running as the dedicated powernode-rails user" do
      rails_service = manifest["services"].find { |s| s["name"] == "rails" }
      expect(rails_service["user"]).to eq("powernode-rails")
    end

    it "declares the powernode-rails user with traefik as a supplementary group" do
      user = manifest["users"].find { |u| u["name"] == "powernode-rails" }
      expect(user).to be_present
      expect(user["supplementary_groups"]).to include("traefik")
    end

    # Review round (blocker 2): supplementary_groups: [traefik] alone is
    # not enough on a FRESH/golden-origin seed import. ManifestImportService
    # only accepts a reference to a group that is EITHER already live OR
    # declared in THIS SAME manifest's own `groups:` — and modules import
    # in name order, so powernode-hub-backend would run before
    # reverse-proxy-traefik with no traefik group live yet. Declaring it
    # here too is safe: GroupAllocator.allocate! is idempotent find-or-create
    # by groupname, so whichever module's import runs first creates the row
    # and the other just adopts it — no duplicate group, no duplicate GID.
    it "declares its own groups: entry for traefik (fresh-seed import order safety)" do
      group_names = manifest["groups"].map { |g| g["name"] }
      expect(group_names).to include("traefik", "powernode-rails")
    end

    it "passes System::ModuleRootUserPolicy even with an EMPTY registry — it needs no exception at all" do
      expect(System::ModuleRootUserPolicy.violations(manifest, {})).to be_empty
    end

    it "orders rails after rails-setup (start_before)" do
      rails_service = manifest["services"].find { |s| s["name"] == "rails" }
      edge = rails_service["dependencies"]&.find { |d| d["service"] == "rails-setup" }
      expect(edge).to be_present
      expect(edge["kind"]).to eq("start_before")
    end
  end
end
