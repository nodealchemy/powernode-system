# frozen_string_literal: true

require "rails_helper"

# The resolver picks the NodeModule a CI publish targets. Its output is then
# handed straight to ManifestImportService, which REFUSES any target whose
# `name` differs from the manifest's `name:`. That coupling is the whole story
# here: a target resolved by OCI-repo binding alone, whose name happens to
# differ, is not merely suboptimal — it is guaranteed to 422, so resolving to it
# can never be right.
#
# Measured on ops-hub 2026-07-27: the canonical `powernode-system-base` (54
# assignments) carried NO repo binding, while a one-off
# `powernode-system-base-vm104-devpin` (1 assignment, named for a VMID that no
# longer exists — ops-hub moved 104 → 600) held "powernode/powernode-system-base".
# Repo-first resolution therefore selected the variant on every publish and the
# importer rejected it, so no module build had landed on that platform for days.
RSpec.describe System::ModulePublishTargetResolver do
  subject(:resolver) { described_class.new }

  let(:account)  { create(:account) }
  # Name left to the factory sequence: NodePlatform names collide across
  # examples, and resolve_publisher_node_platform falls back to any platform on
  # the account, so pinning "ubuntu-24.04-lts" buys nothing.
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, variety: "subscription") }

  def module_named(name, repo: nil)
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           name: name, variety: "subscription", gitea_repo_full_name: repo)
  end

  describe "#find_or_create_publish_target" do
    # THE regression.
    it "resolves the module whose NAME matches, not one merely holding the OCI repo binding" do
      canonical = module_named("powernode-system-base")
      variant   = module_named("powernode-system-base-vm104-devpin",
                               repo: "powernode/powernode-system-base")

      got = resolver.find_or_create_publish_target(
        "powernode/powernode-system-base", "powernode-system-base", account: account
      )

      expect(got).to eq(canonical)
      expect(got).not_to eq(variant)
    end

    # Restating the invariant as the importer sees it: whatever comes back must
    # be acceptable to ManifestImportService, i.e. its name must equal the
    # manifest name. This is the assertion that actually protects the pipeline —
    # any future reordering that reintroduces a mismatched target fails here.
    it "never returns a target whose name differs from the requested module name" do
      module_named("powernode-system-base")
      module_named("powernode-system-base-vm104-devpin",
                   repo: "powernode/powernode-system-base")

      got = resolver.find_or_create_publish_target(
        "powernode/powernode-system-base", "powernode-system-base", account: account
      )

      expect(got.name).to eq("powernode-system-base")
    end

    it "still resolves a repo-bound module when its name agrees — no regression" do
      bound = module_named("gitleaks", repo: "powernode/gitleaks")

      got = resolver.find_or_create_publish_target(
        "powernode/gitleaks", "gitleaks", account: account
      )

      expect(got).to eq(bound)
    end

    # The auto-create path is deliberate: it decouples CI publication cadence
    # from the platform's deploy state. A foreign repo binding must not suppress
    # it — that would leave the publish resolving to a doomed target instead.
    it "auto-creates when only a differently-named module holds the repo binding" do
      module_named("some-other-module", repo: "powernode/brand-new-module")
      category
      platform

      got = resolver.find_or_create_publish_target(
        "powernode/brand-new-module", "brand-new-module", account: account
      )

      expect(got).to be_present
      expect(got.name).to eq("brand-new-module")
      expect(got.account_id).to eq(account.id)
    end

    it "auto-creates when nothing matches at all" do
      category
      platform

      got = resolver.find_or_create_publish_target(
        "powernode/fresh-module", "fresh-module", account: account
      )

      expect(got.name).to eq("fresh-module")
    end

    # Multi-tenant safety is the other half of this method's contract and must
    # survive the reordering: a name match in ANOTHER account is not a match.
    it "never resolves across accounts" do
      other = create(:account)
      create(:system_node_module,
             account: other,
             node_platform: create(:system_node_platform, account: other),
             category: create(:system_node_module_category, account: other, variety: "subscription"),
             name: "powernode-system-base", variety: "subscription",
             gitea_repo_full_name: "powernode/powernode-system-base")
      category
      platform

      got = resolver.find_or_create_publish_target(
        "powernode/powernode-system-base", "powernode-system-base", account: account
      )

      expect(got.account_id).to eq(account.id)
    end

    it "returns nil without an account rather than resolving globally" do
      expect(resolver.find_or_create_publish_target("powernode/x", "x", account: nil)).to be_nil
    end

    # Drift that is otherwise invisible: the binding points at a module the
    # build no longer publishes to. It does not break this publish, but it is
    # exactly what hid the ops-hub breakage, so it must be surfaced.
    it "logs when a different module holds the repo binding" do
      module_named("powernode-system-base")
      module_named("powernode-system-base-vm104-devpin",
                   repo: "powernode/powernode-system-base")

      # allow/have_received rather than expect(...).to receive: a strict
      # message expectation would also fail on any UNRELATED Rails.logger.warn
      # during the example, making this brittle for reasons unrelated to it.
      allow(Rails.logger).to receive(:warn)

      resolver.find_or_create_publish_target(
        "powernode/powernode-system-base", "powernode-system-base", account: account
      )

      expect(Rails.logger).to have_received(:warn)
        .with(/vm104-devpin.*powernode\/powernode-system-base/m)
    end

    it "stays quiet when the repo binding sits on the module being published" do
      module_named("gitleaks", repo: "powernode/gitleaks")
      allow(Rails.logger).to receive(:warn)

      resolver.find_or_create_publish_target("powernode/gitleaks", "gitleaks", account: account)

      expect(Rails.logger).not_to have_received(:warn).with(/holds the OCI repo binding/)
    end
  end
end
