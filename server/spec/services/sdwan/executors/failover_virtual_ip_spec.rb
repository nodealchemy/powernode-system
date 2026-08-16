# frozen_string_literal: true

require "rails_helper"
require "ripper"
require "tmpdir"

# Regression + contract spec for the FailoverVirtualIp executor. The executor
# previously called `vip.failover!(target_peer_id:)`, but the model signature is
# `failover!(reason:, triggered_by_user:, correlation_id:)` — an unknown keyword
# that raises ArgumentError on every invocation. `instance_double` verifies the
# real signature, so the old call fails this spec exactly as production would.
RSpec.describe Sdwan::Executors::FailoverVirtualIp do
  let(:vip) do
    instance_double(
      "Sdwan::VirtualIp",
      id: "vip-1",
      holder_peer_ids: %w[p2 p1],
      failover_holder_peer_ids: %w[p1 p3],
      state: "active",
      reload: nil
    )
  end

  before do
    allow(::Sdwan::VirtualIp).to receive(:find).with("vip-1").and_return(vip)
    allow(vip).to receive(:failover!)
    allow(vip).to receive(:update!)
    allow(vip).to receive(:failover_blocker).and_return(nil)
  end

  describe ".execute" do
    it "delegates to VirtualIp#failover! using the model's real keyword contract" do
      described_class.execute({ vip_id: "vip-1" }, deferred_operation: nil)

      expect(vip).to have_received(:failover!).with(
        reason: "manual_failover",
        triggered_by_user: nil,
        correlation_id: nil
      )
    end

    it "returns the post-failover holder state" do
      result = described_class.execute({ vip_id: "vip-1" }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result[:data]).to include(
        vip_id: "vip-1",
        holders: %w[p2 p1],
        failover_holders: %w[p1 p3],
        state: "active"
      )
    end

    it "moves a named target_peer_id to the head of the failover queue before failing over" do
      described_class.execute({ vip_id: "vip-1", target_peer_id: "p3" }, deferred_operation: nil)

      expect(vip).to have_received(:update!).with(failover_holder_peer_ids: %w[p3 p1])
      expect(vip).to have_received(:failover!)
    end

    it "ignores a target_peer_id that is not a configured failover candidate" do
      described_class.execute({ vip_id: "vip-1", target_peer_id: "p9" }, deferred_operation: nil)

      expect(vip).not_to have_received(:update!)
      expect(vip).to have_received(:failover!)
    end

    # IMP-d952c791e264 — the precondition is asked BEFORE prefer_target!,
    # whose update! persists a reordered failover_holder_peer_ids and is NOT
    # inside failover!'s transaction. Both pre-gate surfaces already refuse a
    # doomed failover, so this path is reached when state MOVED during the
    # approval window (the VIP was flipped to anycast, the standby was
    # deleted). Checking only inside failover! would let an operation that is
    # about to be refused permanently rewrite the candidate queue on its way
    # to being refused.
    it "refuses on a moved precondition without letting prefer_target! rewrite the queue" do
      allow(vip).to receive(:failover_blocker)
        .with(target_peer_id: "p3").and_return("anycast VIPs don't fail over")

      expect {
        described_class.execute({ vip_id: "vip-1", target_peer_id: "p3" }, deferred_operation: nil)
      }.to raise_error(::Sdwan::VirtualIp::StateError, /anycast/)

      expect(vip).not_to have_received(:update!)
      expect(vip).not_to have_received(:failover!)
    end

    # Positive control: the predicate is asked with the NAMED target, not with
    # today's queue head — prefer_target! is about to promote that peer.
    it "asks the predicate about the peer prefer_target! will promote" do
      described_class.execute({ vip_id: "vip-1", target_peer_id: "p3" }, deferred_operation: nil)

      expect(vip).to have_received(:failover_blocker).with(target_peer_id: "p3")
    end
  end

  # IMP-d952c791e264 — the ADDITION guard. Every example above (and every
  # per-surface example in the tool/controller specs) perturbs a gate site
  # that EXISTS; none of them can see a THIRD one added later. A new surface
  # that parks a system.sdwan_vip_failover operation without first asking
  # Sdwan::VirtualIp#failover_blocker re-opens precisely the defect this task
  # closed — a doomed approval that can only fail at execution — and the whole
  # suite stays green.
  #
  # Keyed on the corroborating literal a gate call always carries (the executor
  # it names), never on the shape of the pre-check, which is the thing under
  # test. Two things the first cut of this guard got wrong, both found by
  # review, both of which made it pass on the most likely drift:
  #
  #   * Scope is the enclosing METHOD, not the file. Both known gate sites live
  #     in files that already mention failover_blocker, so a file-wide check
  #     would clear a SIBLING verb added beside them — `def failover_all`, or a
  #     second failover action in the 2,400-line MCP tool — which is exactly
  #     how a third gate site actually appears.
  #   * The executor may be named as a double- or single-quoted string or as a
  #     constant (both existing sites already reference the class constant on
  #     the adjacent line for ACTION_CATEGORY), so all three shapes count.
  #
  # Comments — line AND =begin/=end — are lexed away first: a guard satisfied
  # by a commented-out failover_blocker is not a guard.
  describe "the gate sites that park a VIP failover" do
    let(:ext_server_root) { Pathname.new(File.expand_path("../../../..", __dir__)) }

    # Globbed, not listed, so a new SDWAN controller or tool is in scope the
    # day it lands.
    let(:gate_source_paths) do
      paths = Dir[ext_server_root.join("app/controllers/api/v1/system/**/*.rb").to_s] +
              Dir[ext_server_root.join("app/services/ai/tools/*.rb").to_s]
      raise "no gate sources found under #{ext_server_root}" if paths.empty?

      paths.sort
    end

    # Source with every comment token dropped, so only executable text is read.
    # The token list is a local, not a constant: a bare constant assigned inside
    # a describe block lands on Object, and a generic name there is the
    # duplicate-constant clobber that makes suites order-dependent.
    def executable_source(path)
      comment_tokens = %i[on_comment on_embdoc_beg on_embdoc on_embdoc_end]
      Ripper.lex(File.read(path))
            .reject { |(_pos, type, _tok, _state)| comment_tokens.include?(type) }
            .map { |(_pos, _type, tok, _state)| tok }
            .join
    end

    # One entry per METHOD that names the failover executor in a gate call.
    # Split on `def ` at the start of a line, which is coarse but conservative
    # in the direction that matters: a gate site can only borrow a
    # failover_blocker call that sits in its own method body.
    def failover_gate_sites(paths)
      paths.flat_map do |path|
        executable_source(path)
          .split(/^(?=\s*def\s)/)
          .filter_map do |chunk|
            next unless chunk.match?(
              /executor_class:\s*(?:"Sdwan::Executors::FailoverVirtualIp"|'Sdwan::Executors::FailoverVirtualIp'|(?:::)?Sdwan::Executors::FailoverVirtualIp\b)/
            )

            {
              file: File.basename(path),
              method: chunk[/\A\s*def\s+([a-z_][\w?!]*)/, 1] || "(top level)",
              consults_predicate: chunk.include?("failover_blocker")
            }
          end
      end
    end

    it "asks the model's precondition predicate in every one of them" do
      offenders = failover_gate_sites(gate_source_paths).reject { |s| s[:consults_predicate] }

      expect(offenders.map { |s| "#{s[:file]}##{s[:method]}" }).to be_empty,
        "#{offenders.size} method(s) park a VIP failover without calling " \
        "Sdwan::VirtualIp#failover_blocker first, so a doomed failover (anycast, no " \
        "candidates, or a standby that is no longer a live peer of the network) parks " \
        "an approval that can only fail at execution"
    end

    # Positive control: a scan that silently matches nothing is
    # indistinguishable from a clean tree. The two known surfaces are pinned by
    # name — a rename or a move out of the glob reds here rather than passing
    # vacuously.
    it "finds both known surfaces" do
      expect(failover_gate_sites(gate_source_paths).map { |s| "#{s[:file]}##{s[:method]}" })
        .to contain_exactly("virtual_ips_controller.rb#failover", "sdwan_tool.rb#failover_virtual_ip"),
            "a genuinely new gate site belongs in this list — ADD it (the example above " \
            "then holds it to the predicate). Relaxing this matcher to `include` instead " \
            "would delete the only proof that the scan is not silently matching nothing"
    end

    # The scanner's own oracle. Everything above trusts failover_gate_sites to
    # notice a drifting site; driven over constructed source, it must flag every
    # shape that is really a gate and clear only a method that really asks.
    it "classifies each constructed gate-site shape correctly" do
      Dir.mktmpdir do |dir|
        fixtures = {
          # Bare gate, no pre-check.
          "bad_controller.rb" => <<~RUBY,
            def failover
              gate!(action_category: "system.sdwan_vip_failover",
                    executor_class: "Sdwan::Executors::FailoverVirtualIp", params: {})
            end
          RUBY
          # Asks the predicate.
          "good_controller.rb" => <<~RUBY,
            def failover
              return render_error(@vip.failover_blocker) if @vip.failover_blocker
              gate!(action_category: "system.sdwan_vip_failover",
                    executor_class: "Sdwan::Executors::FailoverVirtualIp", params: {})
            end
          RUBY
          # The sibling-verb shape a file-wide scan cleared: a guarded verb and
          # an unguarded one in the SAME file.
          "sibling_controller.rb" => <<~RUBY,
            def failover
              return render_error(@vip.failover_blocker) if @vip.failover_blocker
              gate!(executor_class: "Sdwan::Executors::FailoverVirtualIp", params: {})
            end

            def failover_all
              gate!(executor_class: "Sdwan::Executors::FailoverVirtualIp", params: {})
            end
          RUBY
          # Constant instead of a string literal.
          "constant_tool.rb" => <<~RUBY,
            def failover_virtual_ip
              gated_result(executor_class: ::Sdwan::Executors::FailoverVirtualIp.name, params: {})
            end
          RUBY
          # A guard that only LOOKS like one: the pre-check is commented out.
          "commented_guard.rb" => <<~RUBY,
            def failover
              # return render_error(@vip.failover_blocker) if @vip.failover_blocker
              gate!(executor_class: "Sdwan::Executors::FailoverVirtualIp", params: {})
            end
          RUBY
          # Not a gate at all — the literal appears only inside comments.
          "commented_controller.rb" => <<~RUBY
            def failover
              # executor_class: "Sdwan::Executors::FailoverVirtualIp"
            =begin
              executor_class: "Sdwan::Executors::FailoverVirtualIp"
            =end
              :not_a_gate
            end
          RUBY
        }
        fixtures.each { |name, body| File.write(File.join(dir, name), body) }

        sites = failover_gate_sites(fixtures.keys.map { |n| File.join(dir, n) })
                .to_h { |s| [ "#{s[:file]}##{s[:method]}", s[:consults_predicate] ] }

        expect(sites).to eq(
          "bad_controller.rb#failover"          => false,
          "good_controller.rb#failover"         => true,
          "sibling_controller.rb#failover"      => true,
          "sibling_controller.rb#failover_all"  => false,
          "constant_tool.rb#failover_virtual_ip" => false,
          "commented_guard.rb#failover"         => false
        )
      end
    end
  end
end
