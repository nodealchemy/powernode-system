# frozen_string_literal: true

require "rails_helper"

# N4 (review round 11, IMP-caef5c00d63f) — unit oracles for the pending
# module digests ingest. A hostile or simply buggy node controls this
# payload entirely (it is the agent's own PendingModuleDigests map, straight
# off the wire), so every helper here exists to stop a specific false
# reading of it — same posture as BootLkgStateWriter's own spec.
RSpec.describe System::PendingModuleDigestsWriter do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  # UNLIKE BootLkgStateWriter (which never reads its own prior document),
  # this writer's merge base IS instance.config as loaded in memory — the
  # class doc's own accepted simplification. Reload between calls to
  # exercise the SAME cross-heartbeat path a real request takes (a fresh
  # current_instance load per request).
  def write(payload)
    doc = described_class.write!(instance: instance, payload: payload)
    instance.reload
    doc
  end

  def stored
    instance.reload.config[described_class::CONFIG_KEY]
  end

  describe "the absence rule" do
    it "writes nothing for a heartbeat with no pending_module_digests key at all, on a fresh instance" do
      expect(write({})).to be_nil
      expect(stored).to be_nil
    end

    it "writes nothing for a nil payload on an instance with no document" do
      expect(write(nil)).to be_nil
      expect(stored).to be_nil
    end

    it "DROPS a module id the next heartbeat no longer reports (resolved)" do
      write("pending_module_digests" => { "m1" => "d2" })
      write("pending_module_digests" => {})

      expect(stored["modules"]).to eq({})
    end
  end

  describe "normalization" do
    it "ignores a non-Hash pending_module_digests value" do
      expect(write("pending_module_digests" => "not-a-hash")).to be_nil
      expect(stored).to be_nil
    end

    it "drops an entry with a blank digest" do
      write("pending_module_digests" => { "m1" => "" })

      expect(stored).to be_nil
    end

    it "drops an entry with a blank module id" do
      write("pending_module_digests" => { "" => "d2" })

      expect(stored).to be_nil
    end

    it "truncates an oversized module id / digest rather than storing it whole" do
      long = "x" * 500
      write("pending_module_digests" => { long => long })

      stored_id = stored["modules"].keys.first
      expect(stored_id.length).to eq(System::IdentifierCaps::MAX_IDENTIFIER_CHARS)
      expect(stored["modules"][stored_id]["digest"].length).to eq(System::IdentifierCaps::MAX_IDENTIFIER_CHARS)
    end

    it "accepts a symbol-keyed payload the same as a string-keyed one" do
      write(pending_module_digests: { "m1" => "d2" })

      expect(stored["modules"]["m1"]["digest"]).to eq("d2")
    end
  end

  describe "first_seen_at tracking (N2's revert/backoff needs cross-heartbeat memory)" do
    it "stamps a NEW module id with first_seen_at = now" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_seen_at"]).to eq("2026-01-01T00:00:00Z")
    end

    it "CARRIES FORWARD first_seen_at across heartbeats reporting the SAME digest" do
      first_seen = nil
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
        first_seen = stored["modules"]["m1"]["first_seen_at"]
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_seen_at"]).to eq(first_seen)
    end

    it "RESETS first_seen_at when the pending digest CHANGES (a revert or re-target, N2)" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d1" }) # reverted
      end

      expect(stored["modules"]["m1"]["digest"]).to eq("d1")
      expect(stored["modules"]["m1"]["first_seen_at"]).to eq("2026-01-01T00:20:00Z")
    end

    it "tracks each module id independently" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2", "m2" => "d5" })
      end

      expect(stored["modules"]["m1"]["first_seen_at"]).to eq("2026-01-01T00:00:00Z")
      expect(stored["modules"]["m2"]["first_seen_at"]).to eq("2026-01-01T00:20:00Z")
    end
  end

  describe "first_pending_at tracking (N4 addendum, review round 12 — survives a re-target)" do
    it "stamps a NEW module id with first_pending_at = now, same as first_seen_at" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_pending_at"]).to eq("2026-01-01T00:00:00Z")
    end

    it "CARRIES FORWARD first_pending_at across heartbeats reporting the SAME digest" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_pending_at"]).to eq("2026-01-01T00:00:00Z")
    end

    it "does NOT reset when the pending digest CHANGES — unlike first_seen_at" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d1" }) # reverted
      end

      expect(stored["modules"]["m1"]["digest"]).to eq("d1")
      expect(stored["modules"]["m1"]["first_seen_at"]).to eq("2026-01-01T00:20:00Z")   # per-digest clock resets
      expect(stored["modules"]["m1"]["first_pending_at"]).to eq("2026-01-01T00:00:00Z") # continuously-pending clock does not
    end

    it "survives a d2 -> d3 -> d2 bounce without ever resetting" do
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:10:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d3" })
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_pending_at"]).to eq("2026-01-01T00:00:00Z")
    end

    it "DROPS first_pending_at along with the rest of the entry once the module stops being reported (resolved)" do
      write("pending_module_digests" => { "m1" => "d2" })
      write("pending_module_digests" => {})

      expect(stored["modules"]).not_to have_key("m1")
    end

    it "falls back to a prior first_seen_at (not now) for a document written before this field existed" do
      # Simulates a document a pre-round-12 writer produced: no
      # first_pending_at key at all. A migration-unaware "now" fallback
      # would silently reset an ALREADY-stuck module's clock the first
      # time this runs post-deploy — falling back to first_seen_at instead
      # preserves the module's real stuck duration.
      old_first_seen = nil
      travel_to(Time.zone.parse("2026-01-01 00:00:00 UTC")) do
        old_first_seen = Time.current.utc.iso8601
        instance.update!(config: instance.config.merge(
          described_class::CONFIG_KEY => {
            "observed_at" => old_first_seen,
            "modules" => { "m1" => { "digest" => "d2", "first_seen_at" => old_first_seen } }
          }
        ))
      end

      travel_to(Time.zone.parse("2026-01-01 00:20:00 UTC")) do
        write("pending_module_digests" => { "m1" => "d2" })
      end

      expect(stored["modules"]["m1"]["first_pending_at"]).to eq(old_first_seen)
    end
  end
end
