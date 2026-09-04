# frozen_string_literal: true

require "spec_helper"

# IMP-01b1e152f667 — extension isolation (gate #9). The public, MIT-licensed
# system extension must not name the private business extension's `Billing::`
# namespace anywhere in its application code: cross-extension traffic goes
# through core's generic Powernode::BillingBridge seam
# (check_provisioning_quota / record_provisioning_event).
#
# The core-purity hook exempts everything under extensions/ wholesale, so this
# file is the ratchet. Rails-free file scan. The acceptance property is a raw
# `grep -rn "::Billing::" extensions/system/server/app`, so comments count too
# — a comment is how the last stale copy of a claim survives — and so does
# every file type, not just *.rb: an .erb view, a .rake task or a .yml default
# under app/ names a constant just as effectively. Scan is byte-oriented for
# that reason (a non-UTF-8 asset must not raise here).
RSpec.describe "extensions/system billing-namespace purity" do
  app_root = File.expand_path("../../app", __dir__)

  it "names no Billing:: constant anywhere under server/app (routes through Powernode::BillingBridge)" do
    paths = Dir.glob(File.join(app_root, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort

    hits = paths.flat_map do |path|
      File.read(path, mode: "rb").force_encoding(Encoding::BINARY)
          .split("\n", -1).each_with_index.filter_map do |line, index|
        next unless line.match?(/\bBilling::\w+/)

        "#{path.delete_prefix("#{app_root}/")}:#{index + 1}: #{line.strip}"
      end
    end

    expect(hits).to be_empty,
      "extensions/system must not reference the business extension's Billing:: namespace — " \
      "route through Powernode::BillingBridge instead. Found:\n  #{hits.join("\n  ")}"
  end
end
