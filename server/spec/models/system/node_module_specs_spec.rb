# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.C/D/E/F/G — port legacy NodeModule spec methods.
# Reference: ~/Drive/Projects/powernode-server/app/models/node_module.rb
# - encode_spec / decode_spec      (304-321)
# - *_text accessors               (248-283)
# - effective_priority             (110-112)
# - effective_mask                 (252-266)
# - rsync_spec                     (268-271)
# - info                           (127-138)
# - immutable?                     (referenced by effective_mask)
RSpec.describe System::NodeModule, "spec methods", type: :model do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:category_a)    do
    create(:system_node_module_category, account: account, name: "Cat A", position: 5)
  end
  let(:category_b) do
    create(:system_node_module_category, account: account, name: "Cat B", position: 10)
  end

  describe "spec encoding (encode_spec / encode_specs callback)" do
    it "encodes a multi-line String into a sorted, deduped, base64 array on save" do
      mod = build_module(category: category_a)
      mod.mask = "/etc/foo\n/etc/bar\n/etc/foo\n\n/etc/baz"
      mod.save!

      raw_array = mod.read_attribute(:mask)
      expect(raw_array).to be_an(Array)
      expect(raw_array.size).to eq(3)

      decoded = raw_array.map { |s| Base64.decode64(s) }.sort
      expect(decoded).to eq(["/etc/bar", "/etc/baz", "/etc/foo"])
    end

    it "leaves an Array input unchanged (idempotent)" do
      encoded = ["/x", "/y"].sort.map { |l| Base64.strict_encode64(l) }
      mod = build_module(category: category_a)
      mod.write_attribute(:file_spec, encoded)
      mod.save!
      expect(mod.read_attribute(:file_spec)).to eq(encoded)
    end

    it "round-trips all four spec fields" do
      mod = build_module(category: category_a)
      mod.mask            = "/m"
      mod.file_spec       = "/f"
      mod.package_spec    = "pkg"
      mod.dependency_spec = "/d"
      mod.save!

      expect(mod.mask_text).to            eq("/m\n")
      expect(mod.file_spec_text).to       eq("/f\n")
      expect(mod.package_spec_text).to    eq("pkg\n")
      expect(mod.dependency_spec_text).to eq("/d\n")
    end
  end

  describe "#effective_priority" do
    it "is category.position * MULTIPLIER + module.priority" do
      mod = create_module(category: category_a, priority: 7) # 5 * 1000 + 7
      expect(mod.effective_priority).to eq((category_a.position * described_class::PRIORITY_CATEGORY_MULTIPLIER) + 7)
      expect(mod.effective_priority).to eq(5_007)
    end

    it "treats missing category as position=0" do
      mod = create_module(category: nil, priority: 3)
      expect(mod.effective_priority).to eq(3)
    end
  end

  describe "#info text" do
    let(:copy_path) do
      create(:system_node_module_copy_path, account: account, name: "fast",
             source_path: "/src", destination_path: "/mnt/fast")
    end

    it "produces legacy key=value sidecar content with zero-padded priority" do
      mod = create_module(
        category: category_a, priority: 42, name: "demo-module",
        init_start: "/etc/init.d/demo start",
        init_stop:  "/etc/init.d/demo stop",
        init_restart: "/etc/init.d/demo restart",
        reboot_required: true,
        copy_path: copy_path
      )

      lines = mod.info.split("\n")
      expect(lines).to include("name=demo-module")
      expect(lines).to include("init_start=/etc/init.d/demo start")
      expect(lines).to include("init_stop=/etc/init.d/demo stop")
      expect(lines).to include("init_restart=/etc/init.d/demo restart")
      expect(lines).to include("reboot=true")
      expect(lines).to include("copy_path=/mnt/fast")
      # Priority is 5 * 1000 + 42 = 5042; PRIORITY_PLACES default 7 → 0005042
      expect(lines).to include("priority=#{(5_042).to_s.rjust(7, '0')}")
    end

    it "outputs reboot=false when reboot_required is false" do
      mod = create_module(category: category_a, reboot_required: false)
      expect(mod.info).to include("reboot=false")
    end
  end

  describe "#immutable?" do
    it "reflects lock_spec" do
      mod = create_module(category: category_a, lock_spec: false)
      expect(mod).not_to be_immutable
      mod.update_columns(lock_spec: true)
      expect(mod.reload).to be_immutable
    end
  end

  describe "#effective_mask" do
    it "returns the module's own mask when no target context is given" do
      mod = create_module(category: category_a, mask: "/x\n/y")
      result = mod.effective_mask
      decoded = mod.send(:decode_spec, result).sort
      expect(decoded).to eq(["/x", "/y"])
    end

    context "with a Node target" do
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }

      it "incorporates higher-priority neighbors' mask" do
        # category_a (position 5) vs category_b (position 10) → b is higher priority
        low  = create_module(category: category_a, name: "low", mask: "/own_excl")
        high = create_module(category: category_b, name: "high", mask: "/high_excl")
        assign(node, low)
        assign(node, high)

        decoded = low.send(:decode_spec, low.effective_mask(target: node)).sort
        expect(decoded).to include("/own_excl", "/high_excl")
      end

      it "only includes immutable higher-priority neighbors' file_spec + dependency_spec" do
        low  = create_module(category: category_a, name: "low",
                             mask: "/own", file_spec: "/own_file")
        immut = create_module(category: category_b, name: "high-immut",
                              mask: "/h_excl", file_spec: "/h_file",
                              dependency_spec: "/h_dep", lock_spec: true)
        mutable = create_module(category: category_b, name: "high-mut",
                                mask: "/m_excl", file_spec: "/m_file",
                                dependency_spec: "/m_dep", lock_spec: false)
        [low, immut, mutable].each { |m| assign(node, m) }

        decoded = low.send(:decode_spec, low.effective_mask(target: node)).sort
        # immutable neighbor contributes its file_spec, dependency_spec, AND mask:
        expect(decoded).to include("/h_file", "/h_dep", "/h_excl")
        # mutable neighbor only contributes its mask, NOT file_spec or dependency_spec:
        expect(decoded).to include("/m_excl")
        expect(decoded).not_to include("/m_file")
        expect(decoded).not_to include("/m_dep")
      end

      it "ignores neighbors with equal or lower effective_priority" do
        peer  = create_module(category: category_a, name: "peer", priority: 1, mask: "/peer_excl")
        focus = create_module(category: category_a, name: "focus", priority: 2, mask: "/own")
        assign(node, peer)
        assign(node, focus)

        decoded = focus.send(:decode_spec, focus.effective_mask(target: node)).sort
        expect(decoded).to eq(["/own"])
      end
    end
  end

  describe "#rsync_spec" do
    it "emits '- excl\\n' lines, '+ incl\\n' lines, then '- *' fallback" do
      mod = create_module(category: category_a, mask: "/etc/secret", file_spec: "/etc/desired")
      out = mod.rsync_spec
      expect(out).to include("- /etc/secret\n")
      expect(out).to include("+ /etc/desired\n")
      expect(out).to end_with("- *\n")
    end
  end

  # ----- helpers -----

  def build_module(category:, **attrs)
    base = {
      account:    account,
      node_platform: platform,
      category:   category,
      variety:    "subscription",
      name:       attrs[:name] || "module-#{SecureRandom.hex(3)}",
      priority:   0
    }
    System::NodeModule.new(base.merge(attrs))
  end

  def create_module(**attrs)
    build_module(**attrs).tap(&:save!)
  end

  def assign(node, mod)
    System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
  end
end
