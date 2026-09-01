# frozen_string_literal: true

require "rails_helper"

# IMP-b5fabc7a9d7f — the honeypot drill could not fail.
#
# `db/seeds/example_honeypot.rb` advertises itself as a verification of the
# "sensor + escalation chain". It wrote a FleetEvent with the fabricated kind
# `honeypot.access_attempted`; HoneypotAccessSensor reads
# `system.honeypot_triggered` (the kind CanaryModuleService actually emits), so
# the sensor never saw the drill's event. That alone would be a one-string fix
# — the reason it needed a spec is that the drill ABSORBED the failure:
#
#   * it called `sensor.tick(account:)`, a method BaseSensor does not define,
#     behind `rescue []`, so the NoMethodError became an empty signal list;
#   * the zero-signal outcome — the one result that proves the chain is broken
#     — printed as an informational "may need additional state setup" line;
#   * execution then continued and printed "Production response would be: …",
#     describing a chain it had just failed to exercise, and exited 0.
#
# WHAT THIS SPEC PINS is therefore not the corrected string. It is the
# property the string was only one way of breaking: **a drill whose sensor did
# not observe the drill's own event must exit non-zero.** The load-bearing
# assertion in the seed is the one that ties a produced signal back to the
# emitted event by id (`signals.select { |s| s.payload["event_id"] == event.id }`,
# aborting when the result is empty)
# — an identity check, not a comparison of the kind literal against itself, so
# it survives a rename of the kind and dies the moment the two ends stop
# agreeing.
#
# The seed's mechanism is `abort`, matching the sibling `smoke_test_*` seeds
# (SystemExit, status 1) rather than a bare raise: these run under
# `rails runner`, where the operator's oracle is the exit status.
RSpec.describe "example_honeypot seed drill" do
  let!(:account) { create(:account, name: "Powernode Admin") }
  let!(:user)    { create(:user, account: account, email: "admin@powernode.org") }
  let!(:instance) { create(:system_node_instance, :running, account: account) }

  def seed_path
    Rails.root.join("..", "extensions", "system", "server", "db", "seeds", "example_honeypot.rb")
  end

  # Runs the seed, returning [stdout, error_or_nil]. `load` is used (not
  # require) because the seed uses top-level `return` for its skip paths.
  #
  # `Exception` — not `StandardError` — is caught deliberately: SystemExit (what
  # `abort` raises) is not a StandardError, and it is the outcome under test.
  # Both an abort and an uncaught error mean the same thing to the operator
  # running this under `rails runner`: a non-zero exit. The examples below
  # distinguish the two only where the distinction is the point.
  def run_seed
    out = StringIO.new
    err = nil
    original_out = $stdout
    original_err = $stderr
    # stderr is captured only to keep `abort`'s message out of the suite
    # output; the message itself is asserted on the exception.
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

  describe "the failure path — the deliverable" do
    it "exits non-zero when the emitted event carries a kind the sensor does not read" do
      # The ORIGINAL defect, reconstructed at the producer: every event the
      # drill emits gets the fabricated kind back. Nothing else changes — the
      # sensor is real, the module is real, the instance is real.
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_wrap_original do |orig, **kwargs|
        orig.call(**kwargs.merge(kind: "honeypot.access_attempted"))
      end

      output, error = run_seed

      expect(error).to be_a(SystemExit),
        "the drill completed successfully while the sensor observed nothing"
      expect(error.status).to eq(1)
      # `abort` writes its message to stderr, so the diagnosis is on the
      # exception, not in stdout — and stdout must NOT claim completion.
      expect(error.message).to include("ESCALATION CHAIN BROKEN")
      expect(output).not_to include("Done.")
    end

    it "exits non-zero when the sensor raises instead of returning signals" do
      # The `rescue []` funnelled genuine errors into the benign branch. A
      # sensor that blows up is a broken chain, not a setup nuance.
      allow_any_instance_of(::System::Fleet::Sensors::HoneypotAccessSensor)
        .to receive(:sense).and_raise(RuntimeError, "sensor exploded")

      output, error = run_seed

      # The seed does not catch this: an uncaught error already exits non-zero
      # under `rails runner`, which is the property. What must NOT happen is
      # the old behaviour — the error absorbed into an empty signal list and
      # the drill running on to print its success narration.
      #
      # The error's CLASS and MESSAGE are asserted, not merely its presence:
      # `be_present` alone is satisfied by a factory blowing up or a typo in
      # the seed, so it cannot tell "the drill propagated the sensor error"
      # from "the drill is broken somewhere earlier". The stdout assertions
      # pin WHERE it died — past the emit, before the narration.
      expect(error).to be_a(RuntimeError)
      expect(error.message).to eq("sensor exploded")
      expect(output).to include("FleetEvent emitted")
      expect(output).not_to include("Done.")
      expect(output).not_to include("Production response")
    end

    it "fails even while the sensor IS producing signals, when none of them is the drill's event" do
      # THE mutation oracle for the event_id filter. Every other failure example
      # here also passes against the weaker `signals.any?` — because when the
      # kind is wrong the sensor produces nothing at all, so "no signal" and "no
      # signal for MY event" coincide. They stop coinciding the moment any other
      # honeypot event exists inside the 15-minute lookback, which on a real
      # fleet is the normal case.
      #
      # So: plant one. The sensor then raises a signal (for the decoy), and an
      # oracle written as `signals.any?` reports a healthy chain while the
      # drill's own event was never observed. Only the event_id filter fails.
      decoy = create(:system_node_module, account: account, name: "decoy-canary")
      ::System::Honeypot::CanaryModuleService.mark!(node_module: decoy)
      expect(::System::Honeypot::CanaryModuleService.observe_access!(node_module: decoy, source: "decoy"))
        .to be_present

      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_wrap_original do |orig, **kwargs|
        orig.call(**kwargs.merge(kind: "honeypot.access_attempted"))
      end

      output, error = run_seed

      expect(error).to be_a(SystemExit)
      expect(error.message).to include("ESCALATION CHAIN BROKEN")
      # Load-bearing: a NON-ZERO count here is what proves `signals.any?` would
      # have passed. If this ever reads "raised 0", the example has stopped
      # testing the filter and is duplicating the zero-signal example above.
      expect(error.message).to match(/Sensor raised [1-9]\d* signal\(s\)/)
      expect(output).not_to include("Done.")
    end

    it "exits non-zero when the sensor returns no signals at all" do
      allow_any_instance_of(::System::Fleet::Sensors::HoneypotAccessSensor)
        .to receive(:sense).and_return([])

      output, error = run_seed

      expect(error).to be_a(SystemExit),
        "zero signals is the broken-chain outcome, not an informational one"
      expect(error.status).to eq(1)
      expect(output).not_to include("Done.")
    end
  end

  describe "the success path" do
    it "emits through the real producer and reports the signal the sensor raised" do
      output, error = run_seed

      expect(error).to be_nil, "drill aborted unexpectedly (#{error&.message}):\n#{output}"

      # The event the drill wrote is the kind the sensor reads, and no event
      # carries the fabricated kind any more.
      expect(::System::FleetEvent.where(account: account, kind: "system.honeypot_triggered")).to exist
      expect(::System::FleetEvent.where(kind: "honeypot.access_attempted")).not_to exist

      # …and the drill reported the sensor's real escalation signal.
      expect(output).to include("system.honeypot_access")
      expect(output).to match(/Sensor observed the drill event/i)
    end

    it "binds the signal to the running instance that hosts the canary" do
      # The production point of the sensor: quarantine needs a target. The
      # drill has to set up the assignment for that arm to be exercised at all.
      run_seed

      canary = ::System::NodeModule.find_by(account: account, name: "honeypot-canary")
      expect(canary).to be_present
      expect(::System::Honeypot::CanaryModuleService.canary?(node_module: canary)).to be(true)
      expect(::System::NodeModuleAssignment.enabled
              .where(node_id: instance.node_id, node_module_id: canary.id)).to exist

      signals = ::System::Fleet::Sensors::HoneypotAccessSensor.new(account: account).sense
      expect(signals).not_to be_empty
      expect(signals.map { |s| s.payload["instance_id"] }).to include(instance.id)
    end
  end

  describe "the wiring assertions" do
    # The drill instantiates the sensor class directly, so a sensor that is
    # present but unregistered would leave it green while production escalates
    # nothing. Same for a signal the DecisionEngine cannot route.
    it "exits non-zero when the sensor is not in the tick registry" do
      registry = ::System::Fleet::FleetAutonomyService::SENSORS
        .reject { |c| c == ::System::Fleet::Sensors::HoneypotAccessSensor }
      stub_const("System::Fleet::FleetAutonomyService::SENSORS", registry)

      output, error = run_seed

      expect(error).to be_a(SystemExit)
      expect(error.message).to include("FleetAutonomyService::SENSORS")
      expect(output).not_to include("Done.")
    end

    it "exits non-zero when the escalation signal is bound to no action category" do
      bindings = ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS.except("system.honeypot_access")
      stub_const("System::Fleet::DecisionEngine::SIGNAL_BINDINGS", bindings)

      output, error = run_seed

      expect(error).to be_a(SystemExit)
      expect(error.message).to include("bound to no action category")
      expect(output).not_to include("Done.")
    end
  end

  describe "the narration" do
    # Two claims in the closing block were false. They matter because an
    # operator reads them as the description of what just happened.
    it "names the kind the sensor really emits, not a fabricated escalation kind" do
      output, = run_seed

      expect(output).not_to include("honeypot.escalation")
      expect(output).to include("system.honeypot_access")
    end

    it "points at a tutorial that exists" do
      output, = run_seed

      referenced = output[%r{docs/[\w/.-]+\.md}]
      expect(referenced).to be_present, "the drill cites no documentation at all"

      ext_root = File.expand_path("../../../..", __dir__)
      expect(File.exist?(File.join(ext_root, referenced))).to be(true),
        "the drill cites #{referenced}, which does not exist under #{ext_root}"
    end
  end

  it "is idempotent — a second run still drills, and duplicates neither module nor assignment" do
    run_seed
    before = ::System::FleetEvent.where(account: account, kind: "system.honeypot_triggered").count
    output, error = run_seed

    expect(error).to be_nil, "second run failed: #{error&.message}\n#{output}"
    expect(::System::NodeModule.where(account: account, name: "honeypot-canary").count).to eq(1)
    expect(::System::NodeModuleAssignment.where(node_id: instance.node_id).count).to eq(1)

    # The re-run must still EXERCISE the chain, not merely find its own setup
    # already in place and exit 0. `find_or_create_by!` on the assignment means
    # the after_commit producer does NOT fire a second time, so the drill's own
    # explicit observe_access! is the only thing that can add this event —
    # which is also what makes this example red against the pre-fix seed, where
    # no system.honeypot_triggered event was ever written at all.
    after = ::System::FleetEvent.where(account: account, kind: "system.honeypot_triggered").count
    expect(after).to eq(before + 1)
    expect(output).to match(/Sensor observed the drill event/i)
  end
end
