# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::NodeInstanceSerializer do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node) { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:serializer) { described_class.new(instance) }

  describe "#as_json" do
    it "includes all base fields" do
      json = serializer.as_json

      expect(json[:id]).to eq(instance.id)
      expect(json[:name]).to eq(instance.name)
      expect(json[:status]).to eq(instance.status)
      expect(json[:variety]).to eq(instance.variety)
    end

    context "boot image drift fields (campaign 019f505f)" do
      it "includes booted_image_git_sha, promoted_image_git_sha, and boot_image_drifted" do
        json = serializer.as_json

        expect(json).to have_key(:booted_image_git_sha)
        expect(json).to have_key(:promoted_image_git_sha)
        expect(json).to have_key(:boot_image_drifted)
      end

      context "when instance has booted image that differs from promoted image" do
        before do
          instance.update!(booted_image_git_sha: "booted-abc123")
          platform.update!(disk_image_git_sha: "promoted-xyz789")
        end

        it "includes the booted_image_git_sha value" do
          json = serializer.as_json
          expect(json[:booted_image_git_sha]).to eq("booted-abc123")
        end

        it "includes the promoted_image_git_sha value from the platform" do
          json = serializer.as_json
          expect(json[:promoted_image_git_sha]).to eq("promoted-xyz789")
        end

        it "sets boot_image_drifted to true when they differ" do
          json = serializer.as_json
          expect(json[:boot_image_drifted]).to be true
        end
      end

      context "when instance has booted image that matches promoted image" do
        before do
          sha = "matching-sha"
          instance.update!(booted_image_git_sha: sha)
          platform.update!(disk_image_git_sha: sha)
        end

        it "includes both sha values" do
          json = serializer.as_json
          expect(json[:booted_image_git_sha]).to eq("matching-sha")
          expect(json[:promoted_image_git_sha]).to eq("matching-sha")
        end

        it "sets boot_image_drifted to false when they match" do
          json = serializer.as_json
          expect(json[:boot_image_drifted]).to be false
        end
      end

      context "when booted_image_git_sha is nil" do
        before do
          instance.update!(booted_image_git_sha: nil)
          platform.update!(disk_image_git_sha: "promoted-sha")
        end

        it "includes nil for booted_image_git_sha" do
          json = serializer.as_json
          expect(json[:booted_image_git_sha]).to be_nil
        end

        it "includes promoted_image_git_sha" do
          json = serializer.as_json
          expect(json[:promoted_image_git_sha]).to eq("promoted-sha")
        end

        it "sets boot_image_drifted to false" do
          json = serializer.as_json
          expect(json[:boot_image_drifted]).to be false
        end
      end

      context "when promoted_image_git_sha is nil" do
        before do
          instance.update!(booted_image_git_sha: "booted-sha")
          platform.update!(disk_image_git_sha: nil)
        end

        it "includes booted_image_git_sha" do
          json = serializer.as_json
          expect(json[:booted_image_git_sha]).to eq("booted-sha")
        end

        it "includes nil for promoted_image_git_sha" do
          json = serializer.as_json
          expect(json[:promoted_image_git_sha]).to be_nil
        end

        it "sets boot_image_drifted to false" do
          json = serializer.as_json
          expect(json[:boot_image_drifted]).to be false
        end
      end

      context "when both shas are nil" do
        before do
          instance.update!(booted_image_git_sha: nil)
          platform.update!(disk_image_git_sha: nil)
        end

        it "includes nil for both shas" do
          json = serializer.as_json
          expect(json[:booted_image_git_sha]).to be_nil
          expect(json[:promoted_image_git_sha]).to be_nil
        end

        it "sets boot_image_drifted to false" do
          json = serializer.as_json
          expect(json[:boot_image_drifted]).to be false
        end
      end

      context "with different instances and platforms" do
        it "correctly serializes multiple instances with different drift states" do
          # Drifted instance
          drifted = create(:system_node_instance, :running, node: node)
          drifted.update!(booted_image_git_sha: "old-sha")
          platform.update!(disk_image_git_sha: "new-sha")

          # Synced instance
          synced_node = create(:system_node, account: account, node_template: template)
          synced = create(:system_node_instance, :running, node: synced_node)
          synced.update!(booted_image_git_sha: "new-sha")

          drifted_json = described_class.new(drifted).as_json
          synced_json = described_class.new(synced).as_json

          expect(drifted_json[:boot_image_drifted]).to be true
          expect(drifted_json[:booted_image_git_sha]).to eq("old-sha")
          expect(drifted_json[:promoted_image_git_sha]).to eq("new-sha")

          expect(synced_json[:boot_image_drifted]).to be false
          expect(synced_json[:booted_image_git_sha]).to eq("new-sha")
          expect(synced_json[:promoted_image_git_sha]).to eq("new-sha")
        end
      end
    end

    context "node_platform eager loading for N+1 prevention" do
      it "resolves promoted_image_git_sha through the full chain" do
        json = serializer.as_json

        # The serializer should call instance.promoted_image_git_sha which
        # navigates node → node_template → node_platform. This test ensures
        # the data is correctly passed through when the chain is populated.
        promoted_sha = platform.disk_image_git_sha
        expect(json[:promoted_image_git_sha]).to eq(promoted_sha)
      end
    end
  end
end
