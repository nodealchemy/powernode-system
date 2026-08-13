# frozen_string_literal: true

require "rails_helper"

# IMP-7aedb6f1a5f1 — the :system_node_instance factory backfills a
# cloud_instance_id for cloud/dynamic varieties so specs cannot accidentally
# fabricate the F1 phantom shape (a cloud instance the provider never created).
#
# `cloud_instance_id` is a store_accessor into the config JSONB and a nil store
# write drops the key, so an explicit `cloud_instance_id: nil` used to be
# indistinguishable from omission: it was silently backfilled. Four specs
# reached for that idiom to probe the identity-less state and silently got the
# WITH-identity branch instead — three of them sat red for months asserting a
# negative that could never hold, and the fourth (the drift sensor's
# "never stampable" fixture) had its premise quietly voided.
#
# These pin BOTH halves of the contract: the backfill still defaults a valid
# cloud instance, and an explicit nil is now HONOURED — no backfill, and any id
# smuggled in through an explicit `config:` hash is cleared — so the natural
# spelling produces the shape it names and there is no second flag that can
# disagree with it.
#
# NOTE: this lives under spec/models/, NOT spec/factories/. rails_helper loads
# every .rb under an extension's spec/factories/ as a factory-DEFINITION file,
# so a spec placed there is re-executed at definition time on every suite run
# and registers its examples twice.
RSpec.describe "system_node_instance factory — provider identity", type: :model do
  describe "the backfill (load-bearing: it stops specs fabricating the F1 phantom)" do
    it "defaults a cloud instance to a present cloud_instance_id" do
      expect(create(:system_node_instance, variety: "cloud").cloud_instance_id).to be_present
    end

    it "defaults a dynamic instance to a present cloud_instance_id" do
      expect(create(:system_node_instance, variety: "dynamic").cloud_instance_id).to be_present
    end

    it "leaves an explicitly supplied cloud_instance_id alone" do
      instance = create(:system_node_instance, variety: "cloud", cloud_instance_id: "dna/qemu/4242")

      expect(instance.cloud_instance_id).to eq("dna/qemu/4242")
      expect(instance.reload.config["cloud_instance_id"]).to eq("dna/qemu/4242")
    end

    it "leaves an id supplied through an explicit config hash alone" do
      instance = create(:system_node_instance, variety: "cloud",
                                               config: { "cloud_instance_id" => "i-from-config" })

      expect(instance.cloud_instance_id).to eq("i-from-config")
    end

    it "does not backfill a physical instance" do
      expect(create(:system_node_instance, variety: "physical").cloud_instance_id).to be_nil
    end
  end

  describe "explicit cloud_instance_id: nil — the identity-less shape" do
    it "is honoured for a cloud instance rather than backfilled over" do
      instance = create(:system_node_instance, variety: "cloud", cloud_instance_id: nil)

      expect(instance.cloud_instance_id).to be_nil
      expect(instance.config).not_to have_key("cloud_instance_id")
    end

    it "is honoured for a dynamic instance" do
      expect(create(:system_node_instance, variety: "dynamic", cloud_instance_id: nil)
               .cloud_instance_id).to be_nil
    end

    # provision_verifier_spec passes exactly this shape to assert the
    # physical-variety path, where nil is the honest, surviving value.
    it "is honoured for a physical instance" do
      expect(create(:system_node_instance, variety: "physical", cloud_instance_id: nil)
               .cloud_instance_id).to be_nil
    end

    # An explicit nil beats an id smuggled in through the config hash —
    # otherwise the identity-less request is silently overridden by the very
    # column it is about, which is the whole defect this factory contract
    # exists to prevent.
    it "clears an id supplied through an explicit config hash" do
      instance = create(:system_node_instance, variety: "cloud", cloud_instance_id: nil,
                                               config: { "cloud_instance_id" => "i-smuggled" })

      expect(instance.cloud_instance_id).to be_nil
      expect(instance.reload.config).not_to have_key("cloud_instance_id")
    end

    it "leaves the rest of an explicit config hash intact while clearing the id" do
      instance = create(:system_node_instance, variety: "cloud", cloud_instance_id: nil,
                                               config: { "cloud_instance_id" => "i-smuggled",
                                                         "admin_user" => "operator" })

      expect(instance.cloud_instance_id).to be_nil
      expect(instance.reload.config["admin_user"]).to eq("operator")
    end

    it "survives the round trip to the database" do
      instance = create(:system_node_instance, variety: "cloud", cloud_instance_id: nil)

      expect(instance.reload.cloud_instance_id).to be_nil
      # The F1 phantom shape, by the model's own predicate — which is the one
      # mark_running guards on.
      expect(instance.reload.provider_identity_present?).to be false
    end
  end
end
