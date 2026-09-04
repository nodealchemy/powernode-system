# frozen_string_literal: true

require "rails_helper"

# IMP-29df62fcf221 — the "Demo claim" block of db/seeds/example_instance_pool.rb
# could not report a successful claim, and the sentence it would have printed
# named an API that has never existed.
#
#   claim_result = replenisher.acquire!(pool_id: pool.id)
#   if claim_result.is_a?(Hash) && claim_result[:instance]
#     puts "  ✅ Claimed instance: ..."
#     puts "       To return: ...InstancePoolService.new(account: account).return!(claim_id: ...)"
#   end
#
# `acquire!` returns the claimed ::System::NodeInstance (the last expression of
# its transaction block, instance_pool_service.rb), never a Hash, so the guard
# is always false: the seed claimed a pool member out of the pool and told the
# operator nothing. Silence is the one outcome an operator cannot read — it is
# indistinguishable from "the claim never ran".
#
# WHAT THIS SPEC PINS is not the corrected wording. Two properties:
#
#   1. When the seed performs a claim, its output must identify the member it
#      claimed. The oracle is the DB, not a string: the example asserts the
#      member's pool_state really flipped to "claimed" and THEN that the id of
#      that member appears in stdout. A seed that prints a cheerful line while
#      claiming nothing fails the first half; the original, which claimed
#      silently, fails the second.
#
#   2. Every ::System::InstancePoolService method the seed names must exist,
#      and every keyword it prints for that method must be one the real
#      signature accepts. This is a signature check against the live class,
#      not a comparison against a literal copied out of the fix — it stays red
#      for `return!(claim_id:)` (no such method), for `release!(claim_id:)`
#      (real method, phantom keyword), and it survives a rename of either.
#
# `claim_id` WAS a phantom identifier when this spec was written —
# IMP-ebc1d180dc10 withdrew it from docs/runbooks/instance-pool-tuning.md
# because nothing minted one. IMP-68403ec0358d then built the record it named:
# acquire! writes a `system.pool.claimed` FleetEvent carrying claim_id /
# acquired_by / acquired_for, and release! closes it with
# `system.pool.released`. What is STILL phantom is the return-handle reading of
# that id — there is no `return!`, no `release!(claim_id:)`, and no claims
# table; the claimed instance row remains the handle. The guard below is scoped
# to that residue, not to the vocabulary itself.
RSpec.describe "example_instance_pool seed — demo claim" do
  let!(:account) { create(:account, name: "Powernode Admin") }
  let!(:user)    { create(:user, account: account, email: "admin@powernode.org") }

  let!(:region)        { create(:system_provider_region, account: account) }
  let!(:instance_type) { create(:system_provider_instance_type, account: account) }

  # The seed resolves the canonical amd64 architecture with find_by!, so it has
  # to be present before the seed loads.
  let!(:architecture) do
    ::System::NodeArchitecture.ensure_canonical_seed!
    ::System::NodeArchitecture.canonical.find_by!(name: "amd64")
  end

  let!(:platform) do
    create(:system_node_platform, account: account, name: "ubuntu-24.04",
           node_architecture: architecture)
  end

  # Same name the seed uses — it find_or_initialize_by's this template.
  let!(:template) do
    create(:system_node_template, account: account, name: "ml-training-baseline",
           node_platform: platform)
  end

  # Pre-create the pool the seed would otherwise create, sized so that
  # replenish! sees zero deficit (no provisioning in a unit spec) and holding
  # one ready member so the claim path is actually exercised.
  let!(:pool) do
    ::System::InstancePool.create!(
      account: account, node_template: template, name: "ml-training-pool",
      description: "Warm pool for ML training bursts",
      provider_region: region, provider_instance_type: instance_type,
      lifecycle_class: "ephemeral",
      target_size: 1, min_size: 1, max_size: 3, status: "active"
    )
  end

  let!(:node) do
    create(:system_node, account: account, node_template: template)
  end

  let!(:member) do
    create(:system_node_instance, node: node, account: account,
           variety: "cloud", status: "running",
           provider_region: region, provider_instance_type: instance_type,
           instance_pool_id: pool.id, pool_state: "ready",
           pool_warming_started_at: 5.minutes.ago)
  end

  def seed_path
    Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                    "example_instance_pool.rb")
  end

  # `load`, not require: the seed uses top-level `return` for its skip paths.
  # Exception (not StandardError) is caught because SystemExit — what `abort`
  # raises — is not a StandardError, and an operator running this under
  # `rails runner` reads both as the same non-zero exit.
  def run_seed
    out = StringIO.new
    err = nil
    original_out = $stdout
    original_err = $stderr
    $stdout = out
    $stderr = StringIO.new
    begin
      silence_warnings { load seed_path }
    rescue Exception => e # rubocop:disable Lint/RescueException
      err = e
    ensure
      $stdout = original_out
      $stderr = original_err
    end
    [ out.string, err ]
  end

  describe "the success path — the deliverable" do
    it "reports the member it actually claimed" do
      output, error = run_seed

      expect(error).to be_nil, "seed failed (#{error&.message}):\n#{output}"

      # The DB is the oracle for "a claim happened": the seed took a ready
      # member out of circulation.
      expect(member.reload.pool_state).to eq("claimed"),
        "the seed never claimed the ready member, so this example is no longer " \
        "exercising the success path"
      expect(member.pool_acquired_at).to be_present

      # …and having done that, it has to say so, naming the member by the id
      # the operator needs in order to return it.
      expect(output).to include(member.id),
        "the seed claimed #{member.id} and printed nothing that identifies it — " \
        "an operator cannot tell a working claim from a no-op"
    end

    it "names only InstancePoolService methods that exist, with keywords their signatures accept" do
      output, = run_seed

      calls = output.scan(/InstancePoolService[^\n]*?\.(\w+!)\(([^)]*)\)/)
      expect(calls).not_to be_empty,
        "the seed tells the operator nothing about how to give the claim back"

      calls.each do |(method_name, arg_list)|
        resolved =
          if ::System::InstancePoolService.respond_to?(method_name)
            ::System::InstancePoolService.method(method_name)
          elsif ::System::InstancePoolService.method_defined?(method_name)
            ::System::InstancePoolService.instance_method(method_name)
          end

        expect(resolved).to be_present,
          "the seed tells the operator to call " \
          "::System::InstancePoolService##{method_name}, which does not exist"

        accepted = resolved.parameters
                           .select { |type, _| %i[key keyreq].include?(type) }
                           .map { |_, name| name.to_s }
        required = resolved.parameters
                           .select { |type, _| type == :keyreq }
                           .map { |_, name| name.to_s }
        printed = arg_list.scan(/(\w+):/).flatten

        expect(printed - accepted).to be_empty,
          "the seed prints #{method_name}(#{printed.join(': , ')}:) but the real " \
          "signature accepts only #{accepted.join(', ')}"

        # …and the other direction. A printed call that OMITS a required
        # keyword is just as unrunnable as one that invents a keyword — the
        # operator who pastes it gets ArgumentError, not a returned instance.
        expect(required - printed).to be_empty,
          "the seed prints #{method_name}(#{printed.join(': , ')}:) but the real " \
          "signature requires #{required.join(', ')} — pasting it raises ArgumentError"
      end
    end

    it "names only MCP verbs this extension declares, with parameters their schemas declare" do
      # The corrected message offers a SECOND return path — the MCP verb — and
      # a phantom there is the identical defect to the phantom `return!` this
      # task was filed for. Resolved against the live action catalog, not
      # against a literal copied out of the fix.
      output, = run_seed

      declared = ::Ai::Tools::SystemFleetTool.action_definitions
      mcp_calls = output.scan(/\b(system_[a-z0-9_]+)\(\{([^}]*)\}\)/)

      expect(mcp_calls).not_to be_empty,
        "the seed names no MCP verb for returning the claim — an operator " \
        "driving the fleet through MCP is left without the path this seed " \
        "exists to demonstrate"

      mcp_calls.each do |(verb, arg_list)|
        definition = declared[verb]

        expect(definition).to be_present,
          "the seed tells the operator to call MCP verb #{verb}, which " \
          "Ai::Tools::SystemFleetTool does not declare"

        accepted = definition[:parameters].keys.map(&:to_s)
        required = definition[:parameters]
                   .select { |_, spec| spec[:required] }
                   .keys.map(&:to_s)
        printed  = arg_list.scan(/(\w+):/).flatten

        expect(printed - accepted).to be_empty,
          "the seed prints #{verb}({ #{printed.join(': , ')}: }) but its schema " \
          "declares only #{accepted.join(', ')}"
        expect(required - printed).to be_empty,
          "the seed prints #{verb}({ #{printed.join(': , ')}: }) but its schema " \
          "requires #{required.join(', ')}"
      end
    end

    it "names the claim record with the vocabulary that actually ships" do
      # This example used to forbid claim_id / acquired_by / acquired_for
      # outright, on the (then true) grounds that no claim record existed.
      # IMP-68403ec0358d shipped it, so forbidding the words would now forbid
      # the truth — the trap this loop keeps hitting from the other side. The
      # guard is re-scoped to what remains phantom: a claim id used as a RETURN
      # HANDLE (`return!`, `release!(claim_id:)`) and a claims TABLE. The
      # positive half pins that the seed actually names the shipped record, so
      # the operator copying it can read the attribution back.
      output, = run_seed

      expect(output).not_to match(/return!/)
      expect(output).not_to match(/release!\([^)]*claim_id/)
      expect(output).not_to match(/system_pool_claims/)
      expect(output).to include("system.pool.claimed")
    end
  end

  describe "the no-ready-members path" do
    # The rescue arm was already correct; pinned so the fix to the success
    # branch cannot swallow the pool-empty narration.
    it "still explains why nothing was claimed when the pool has no ready member" do
      member.update!(pool_state: "warming")

      output, error = run_seed

      expect(error).to be_nil, "seed failed (#{error&.message}):\n#{output}"
      expect(output).to match(/no ready members/i)
      expect(output).to include("Done.")
    end
  end
end
