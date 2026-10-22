# frozen_string_literal: true

require "rails_helper"

# The hub runs the one-time legacy cache clear (core
# Powernode::LegacyCachePlaintextClear) from its boot reconcile runner, which
# rails-start.sh runs after db:migrate and before it execs puma, so the deploy
# that turns on solid_cache encryption empties the pre-encryption entries
# before anything serves. It costs no extra Rails boot, is bounded by the core
# class, and must never fail the boot.
#
# `type: :lib`: spec/system/** would otherwise be inferred as a browser test
# (see role_grant_reconcile_wiring_spec.rb).
RSpec.describe "hub-backend legacy cache plaintext clear wiring", type: :lib do
  module_bin = File.expand_path("../../../modules/powernode-hub-backend/rootfs/usr/local/bin", __dir__)
  let(:runner) { File.read(File.join(module_bin, "role-grants-reconcile.rb")) }
  let(:rails_start) { File.read(File.join(module_bin, "rails-start.sh")) }

  def code_lines(text)
    text.lines.reject { |line| line.match?(/\A\s*#/) }.join
  end

  it "runs the core one-shot from the boot runner, guarded and non-fatal" do
    block = code_lines(runner)[/begin\n\s*if defined\?\(::Powernode::LegacyCachePlaintextClear\).*?\nend\n/m]

    expect(block).not_to be_nil
    expect(block).to include("::Powernode::LegacyCachePlaintextClear.run_once!(time_budget: 30)")
    expect(block).to match(/rescue StandardError => e/)
  end

  it "runs that runner before puma is exec'd" do
    body = code_lines(rails_start)
    runner_at = body.index("rails runner /usr/local/bin/role-grants-reconcile.rb")
    puma_at = body.index(/^exec .*puma/) || body.index(/exec .*rails server/)

    expect(runner_at).not_to be_nil
    expect(puma_at).not_to be_nil
    expect(runner_at).to be < puma_at
  end
end
