# frozen_string_literal: true

require "rails_helper"

# IMP-b8d5cfa33b79 — unit oracles for the boot/LKG ingest.
#
# The request spec proves the WIRE is connected; this file proves the
# NORMALIZATION, because the shapes that matter most here are ones the real
# agent never sends: a hostile or simply buggy node controls this payload
# entirely, and every helper in the writer exists to stop one specific
# false-green reading of it.
RSpec.describe System::BootLkgStateWriter do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  def write(payload)
    described_class.write!(instance: instance, payload: payload)
  end

  def stored
    instance.reload.config[described_class::CONFIG_KEY]
  end

  describe "the absence rule" do
    it "writes nothing for a first heartbeat carrying none of the seven keys" do
      expect(write({})).to be_nil
      expect(stored).to be_nil
    end

    it "writes nothing for a nil payload on an instance with no document" do
      expect(write(nil)).to be_nil
      expect(stored).to be_nil
    end

    # The one place this lane deliberately departs from its two siblings —
    # and the ONLY examples that discriminate against an in-memory
    # `instance.config.key?(CONFIG_KEY)` guard, which is what an earlier cut of
    # this class used.
    #
    # DO NOT add an intermediate assertion to either example. `stored` calls
    # `instance.reload`, which refreshes `instance.config` in memory; an
    # in-memory guard PASSES once that has happened, so a single `expect` in
    # the middle silently deletes the oracle. The refresh decision is made in
    # the UPDATE precisely so it cannot depend on how fresh the caller's object
    # is — the writes below run against an object whose `config` is still `{}`.
    it "REWRITES an existing document without ever reading instance.config" do
      write("lkg_present" => true)
      write({})

      expect(stored["arm_state"]).to eq("unreported")
      expect(stored["lkg_present"]).to be_nil
    end

    it "rewrites on a nil payload too, also without reading instance.config" do
      write("lkg_present" => true)
      write(nil)

      expect(stored["arm_state"]).to eq("unreported")
    end
  end

  describe "arm_state" do
    # Every falsy / absent / unparseable shape a node could send. NONE of them
    # may reach "armed" — that is the entire safety property.
    [ false, nil, "", "false", "0", 0, "no", [ true ], { "a" => 1 } ].each do |value|
      it "reads #{value.inspect} as unreported, never armed" do
        write("lkg_present" => value, "booted_from_lkg" => true)

        expect(stored["arm_state"]).to eq("unreported")
        expect(stored["lkg_present"]).to be_nil
      end
    end

    # An explicit assertion in any of the encodings a JSON or form-encoded
    # heartbeat can carry. Each of these IS the node stating the fact.
    [ true, "true", "TRUE", 1, "1", "t", "yes" ].each do |value|
      it "reads #{value.inspect} as armed" do
        write("lkg_present" => value)

        expect(stored["arm_state"]).to eq("armed")
        expect(stored["lkg_present"]).to be(true)
      end
    end

    it "never stores a literal false for any of the three booleans" do
      write("lkg_present" => false, "booted_from_lkg" => false, "boot_incomplete" => false)

      expect(stored.values_at("lkg_present", "booted_from_lkg", "boot_incomplete")).to all(be_nil)
    end

    it "accepts symbol keys as well as string keys" do
      write(lkg_present: true, lkg_module_count: 4)

      expect(stored["arm_state"]).to eq("armed")
      expect(stored["lkg_module_count"]).to eq(4)
    end
  end

  describe "integers" do
    it "records a reported count and age" do
      write("lkg_present" => true, "lkg_module_count" => "12", "lkg_age_seconds" => 86_400)

      expect(stored["lkg_module_count"]).to eq(12)
      expect(stored["lkg_age_seconds"]).to eq(86_400)
    end

    it "keeps a negative age — clock skew is an observation, not a parse failure" do
      write("lkg_present" => true, "lkg_age_seconds" => -30)

      expect(stored["lkg_age_seconds"]).to eq(-30)
    end

    # Unbounded integer literals are jsonb growth a node controls, per tick.
    it "rejects an integer beyond MAX_INTEGER_DIGITS rather than storing it" do
      write("lkg_present" => true, "lkg_age_seconds" => "9" * 200)

      expect(stored["lkg_age_seconds"]).to be_nil
    end

    it "keeps the digit boundary at MAX_INTEGER_DIGITS" do
      write("lkg_present" => true, "lkg_age_seconds" => "9" * described_class::MAX_INTEGER_DIGITS)
      expect(stored["lkg_age_seconds"]).to eq(("9" * described_class::MAX_INTEGER_DIGITS).to_i)

      write("lkg_present" => true, "lkg_age_seconds" => "9" * (described_class::MAX_INTEGER_DIGITS + 1))
      expect(stored["lkg_age_seconds"]).to be_nil
    end

    it "rejects a non-numeric count" do
      write("lkg_present" => true, "lkg_module_count" => "seven")

      expect(stored["lkg_module_count"]).to be_nil
    end
  end

  describe "lkg_confirmed_at" do
    it "normalizes a reported timestamp to UTC" do
      write("lkg_present" => true, "lkg_confirmed_at" => "2026-08-20T06:05:06+02:00")

      expect(stored["lkg_confirmed_at"]).to eq("2026-08-20T04:05:06Z")
    end

    # Unparseable is UNMEASURED, the same rule the sibling writers apply to an
    # unrecognized state string — and it is what keeps node-controlled junk out
    # of a column the MCP read surface echoes back.
    it "drops an unparseable timestamp instead of echoing it" do
      write("lkg_present" => true, "lkg_confirmed_at" => "not a time")

      expect(stored["lkg_confirmed_at"]).to be_nil
    end

    # The fixture has to be a string Time.iso8601 ACCEPTS, or the length cap is
    # not what rejects it and the example passes with the cap deleted.
    # `Time.iso8601` takes unbounded fractional-second digits: this 221-char
    # value parses and normalizes to "2026-08-20T04:05:06Z".
    it "drops an over-long timestamp the parser would otherwise accept" do
      write("lkg_present" => true, "lkg_confirmed_at" => "2026-08-20T04:05:06." + ("1" * 200) + "Z")

      expect(stored["lkg_confirmed_at"]).to be_nil
    end
  end

  describe "pivot_confinement_omitted" do
    it "records the list a pivot node reports" do
      write("pivot_confinement_omitted" => %w[capability_bounding_set mandatory_access_control])

      expect(stored["pivot_confinement_omitted"])
        .to eq(%w[capability_bounding_set mandatory_access_control])
    end

    it "stores nil, never [], when the field is absent" do
      write("lkg_present" => true)

      expect(stored["pivot_confinement_omitted"]).to be_nil
    end

    it "stores nil for a non-array value" do
      write("lkg_present" => true, "pivot_confinement_omitted" => "capability_bounding_set")

      expect(stored["pivot_confinement_omitted"]).to be_nil
    end

    # Dropping a blank entry would silently shorten the omission list, which
    # understates how little the node enforces — the one unsafe direction here.
    it "keeps a blank entry under a name that says so rather than dropping it" do
      write("pivot_confinement_omitted" => [ nil, "", "mandatory_access_control" ])

      expect(stored["pivot_confinement_omitted"]).to eq(%w[unnamed unnamed mandatory_access_control])
    end

    it "caps the list at MAX_CONFINEMENTS" do
      write("pivot_confinement_omitted" => Array.new(200) { |i| "gap-#{i}" })

      expect(stored["pivot_confinement_omitted"].size).to eq(described_class::MAX_CONFINEMENTS)
    end

    it "clamps an over-long entry to MAX_IDENTIFIER_CHARS" do
      write("pivot_confinement_omitted" => [ "x" * 500 ])

      expect(stored["pivot_confinement_omitted"].first.length)
        .to eq(described_class::MAX_IDENTIFIER_CHARS)
    end
  end

  describe "the config write" do
    it "touches only its own key" do
      instance.update!(config: instance.config.merge("unrelated" => { "keep" => "me" }))

      write("lkg_present" => true)

      expect(instance.reload.config["unrelated"]).to eq("keep" => "me")
      expect(stored["arm_state"]).to eq("armed")
    end

    it "returns nil and writes nothing without an instance" do
      expect(described_class.write!(instance: nil, payload: { "lkg_present" => true })).to be_nil
    end
  end
end
