# frozen_string_literal: true

require "rails_helper"

# IMP-68d71157b68e (sweep arm) — the ROW-LEVEL oracle.
#
# StatusController#report's own clobber has its own request spec. This file
# proves the same property for the sites the sweep found: an operator/service
# path handed an instance object it loaded EARLIER must not erase the telemetry
# the node heartbeated in the interval.
#
# The interval is the whole point, so every example here constructs it
# literally: load the object, write a boot_lkg document behind its back (which
# is exactly what System::BootLkgStateWriter does from the heartbeat request
# cycle), then run the site's operation against the now-stale object.
#
# ASSERT THE ROW, NEVER THE RETURN VALUE. Every one of these sites returned
# success while destroying the document — a `{ success: true }` and an
# unraised exception are precisely what a clobber looks like from the caller's
# side. The assertions read `config` back out of Postgres.
RSpec.describe "NodeInstance config clobber sweep", type: :service do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let!(:instance) do
    # `physical`: NetbootService refuses cloud instances, and netboot is the
    # clearest of the swept sites — it takes a caller-supplied instance object
    # and does no I/O in test (write_pxe_config is gated on NETBOOT_ENABLED).
    create(:system_node_instance, node: node, status: "running", variety: "physical")
  end

  # The object the operator path is holding — loaded BEFORE the heartbeat.
  let(:stale) { ::System::NodeInstance.find(instance.id) }

  def row_config
    ::System::NodeInstance.where(id: instance.id).pick(:config) || {}
  end

  # Simulates the concurrent heartbeat: BootLkgStateWriter writes with its own
  # jsonb statement, so nothing `stale` holds knows this happened.
  def heartbeat_boot_lkg!
    ::System::BootLkgStateWriter.write!(
      instance: instance,
      payload: { "lkg_present" => true, "lkg_module_count" => 7 }
    )
    raise "fixture failed to seed boot_lkg" if row_config["boot_lkg"].blank?
  end

  describe "System::NetbootService.enable — an instance handed in by the caller" do
    it "leaves the boot_lkg document written after that instance was loaded" do
      stale.config # force the read, so the object really holds the pre-heartbeat document
      heartbeat_boot_lkg!

      result = ::System::NetbootService.enable(instance: stale, options: { boot_type: "localboot" })

      expect(result[:success]).to be(true)
      expect(row_config.dig("netboot", "enabled")).to be(true)
      expect(row_config.dig("boot_lkg", "arm_state")).to eq("armed")
      expect(row_config.dig("boot_lkg", "lkg_module_count")).to eq(7)
    end
  end

  describe "System::NetbootService.disable" do
    it "leaves the boot_lkg document alone while flipping its own key" do
      ::System::NetbootService.enable(instance: instance, options: {})
      reloaded = ::System::NodeInstance.find(instance.id)
      heartbeat_boot_lkg!

      ::System::NetbootService.disable(instance: reloaded)

      expect(row_config.dig("netboot", "enabled")).to be(false)
      expect(row_config.dig("boot_lkg", "arm_state")).to eq("armed")
    end
  end

  describe "the seam itself" do
    it "#merge_config! replaces only the named keys" do
      instance.merge_config!("a" => 1, "b" => { "x" => 1 })
      other = ::System::NodeInstance.find(instance.id)
      instance.merge_config!("a" => 2)

      expect(row_config["a"]).to eq(2)
      expect(row_config["b"]).to eq({ "x" => 1 })

      # And the stale object's later write does not resurrect the old "a".
      other.merge_config!("c" => 3)
      expect(row_config).to include("a" => 2, "c" => 3)
    end

    it "#delete_config_keys! removes only the named keys" do
      instance.merge_config!("a" => 1, "b" => 2)
      instance.delete_config_keys!("a")

      expect(row_config).not_to have_key("a")
      expect(row_config["b"]).to eq(2)
    end

    it "refreshes the in-memory document so a later save! cannot write it back" do
      heartbeat_boot_lkg!
      stale.merge_config!("marker" => "set")

      # The clobber one line further down: the object is saved for an unrelated
      # reason after the merge. Without the refresh, `config` still holds the
      # pre-heartbeat document and this save! would erase boot_lkg.
      stale.status = "stopped"
      stale.save!

      expect(row_config.dig("boot_lkg", "arm_state")).to eq("armed")
      expect(row_config["marker"]).to eq("set")
    end

    it "writes string keys, so a symbol-keyed document does not shadow the stored one" do
      instance.merge_config!(marker: "one")
      instance.merge_config!("marker" => "two")

      expect(row_config.keys.count { |k| k == "marker" }).to eq(1)
      expect(row_config["marker"]).to eq("two")
    end
  end
end
