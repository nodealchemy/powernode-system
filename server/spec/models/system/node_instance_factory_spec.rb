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
# cloud instance, and the idiom that silently defeated it is now a loud error
# naming the supported opt-out.
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

  describe "provider_identity: false — the supported opt-out" do
    it "yields an identity-less cloud instance" do
      instance = create(:system_node_instance, variety: "cloud", provider_identity: false)

      expect(instance.cloud_instance_id).to be_nil
      expect(instance.config).not_to have_key("cloud_instance_id")
    end

    it "yields an identity-less dynamic instance" do
      expect(create(:system_node_instance, variety: "dynamic", provider_identity: false)
               .cloud_instance_id).to be_nil
    end
  end

  describe "explicit cloud_instance_id: nil" do
    it "raises for a cloud instance, naming the opt-out, instead of silently backfilling" do
      expect { create(:system_node_instance, variety: "cloud", cloud_instance_id: nil) }
        .to raise_error(ArgumentError, /provider_identity: false/)
    end

    it "raises for a dynamic instance" do
      expect { create(:system_node_instance, variety: "dynamic", cloud_instance_id: nil) }
        .to raise_error(ArgumentError, /provider_identity: false/)
    end

    # Negative control: the raise must fire ONLY where the nil would have been
    # silently overridden. A blanket raise would have removed real coverage —
    # provision_verifier_spec passes exactly this shape to assert the
    # physical-variety path, where nil is the honest, surviving value.
    it "does NOT raise for a physical instance, where nil is honest and survives" do
      instance = nil
      expect { instance = create(:system_node_instance, variety: "physical", cloud_instance_id: nil) }
        .not_to raise_error
      expect(instance.cloud_instance_id).to be_nil
    end

    # The caller has stated the intent the raise exists to demand, so it is
    # not ambiguous and must be accepted.
    it "does NOT raise when paired with provider_identity: false" do
      instance = nil
      expect do
        instance = create(:system_node_instance, variety: "cloud",
                                                 cloud_instance_id: nil, provider_identity: false)
      end.not_to raise_error
      expect(instance.cloud_instance_id).to be_nil
    end
  end
end
