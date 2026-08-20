# frozen_string_literal: true

require "rails_helper"

# IMP-fd3397eef4b1 — generated instance names outgrew the DNS label limit.
#
# WHAT WAS VERIFIED FIRST, because it decides cosmetic vs identity (the answer
# is neither, exactly):
#
#   * node.name  = "<prefix>-<template>-<index>-<hex6>"          — 43 chars for
#     a realistic dryrun prefix + ordinary template. Comfortably legal.
#   * instance.name = node.name + "-instance-<14-digit ts>-<hex4>" — 72 chars
#     for the SAME inputs. Over both the 63-char DNS label limit and the
#     64-char kernel HOST_NAME_MAX.
#
#   * The AUTHORITATIVE guest hostname is node.name, delivered over the mTLS
#     /node_api/modules envelope — runtime/hostname.go's desiredHostname puts it
#     FIRST and calls the fw-cfg instance_name blob a "LEGACY / fallback source
#     ... (long) instance name". So an enrolled node is not mis-identified.
#   * On that fallback path the guest DOES diverge: etcidentity.ApplyHostname
#     caps at HostNameMax=64 ("degrades to truncated-but-valid rather than a
#     failed apply"), so the platform records 72 characters and the guest
#     carries 64 — and 64 is still an invalid DNS label.
#
# So this budgets the name at generation instead of letting two layers truncate
# it differently.
RSpec.describe System::HostnameBudget do
  it "leaves a name that already fits byte-identical" do
    fitted = described_class.fit(variable: "web-1-instance", fixed_tail: "-20260820120000-abcd")

    expect(fitted).to eq("web-1-instance-20260820120000-abcd")
  end

  it "truncates the variable middle, never the tail" do
    tail = "-20260820120000-abcd"
    fitted = described_class.fit(variable: "x" * 200, fixed_tail: tail)

    expect(fitted.length).to eq(described_class::MAX_LABEL)
    expect(fitted).to end_with(tail), "the entropy suffix was eaten — collisions become possible"
  end

  # A DNS label may not end with a hyphen, and a blind cut lands on one
  # whenever the boundary falls there.
  it "never leaves a trailing hyphen at the cut" do
    fitted = described_class.fit(variable: "#{'a' * 42}-", fixed_tail: "-tail")

    expect(fitted).not_to include("--")
    expect(fitted).to eq("#{'a' * 42}-tail")
  end

  # A tail that cannot fit on its own is a caller bug, not a runtime condition:
  # silently minting a name that is nothing but timestamp would hide it.
  it "refuses a fixed tail that cannot fit at all" do
    expect { described_class.fit(variable: "x", fixed_tail: "-" * 70) }
      .to raise_error(ArgumentError, /fixed tail/)
  end
end

RSpec.describe System::ProvisioningService, "generated instance name length" do
  let(:account) { create(:account) }

  def name_for(node_name)
    node = create(:system_node, account: account, name: node_name)
    described_class.new.send(:generate_instance_name, node, {})
  end

  # The realistic combination measured above: a dryrun blast-radius prefix and
  # an ordinary template name. 72 characters before this fix.
  it "keeps a realistic prefixed fleet name inside the DNS label limit" do
    name = name_for("dryrun-20260809g-ubuntu-24-04-base-1-aaaaaa")

    expect(name.length).to be <= 63,
                           "generated #{name.length} chars: #{name}"
  end

  # ...and the round-trip the truncation must not break: the name is the
  # instance's unique key per node, so the entropy suffix has to survive.
  it "still round-trips to the right instance" do
    node = create(:system_node, account: account,
                                name: "dryrun-20260809g-ubuntu-24-04-base-1-aaaaaa")
    generated = described_class.new.send(:generate_instance_name, node, {})
    instance = create(:system_node_instance, node: node, name: generated)

    expect(node.node_instances.find_by(name: generated)).to eq(instance)
  end

  # No existing fleet may be gratuitously renamed: a short node name must
  # produce exactly what it produced before.
  it "leaves a short name byte-identical to the unbudgeted form" do
    node = create(:system_node, account: account, name: "web")
    allow(SecureRandom).to receive(:hex).with(2).and_return("beef")

    travel_to(Time.utc(2026, 8, 20, 12, 0, 0)) do
      generated = described_class.new.send(:generate_instance_name, node, {})
      expect(generated).to eq("web-instance-20260820120000-beef")
    end
  end
end
