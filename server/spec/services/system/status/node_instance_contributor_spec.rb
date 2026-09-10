# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B2 — NodeInstance as a status component.
RSpec.describe System::Status::Contributors::NodeInstanceContributor do
  let(:account)     { create(:account) }
  let(:contributor) { described_class.new }
  let(:node)        { create(:system_node, account: account) }

  def instance!(**attrs)
    create(:system_node_instance, account: account, node: node, **attrs)
  end

  def components
    [].tap { |acc| contributor.each_component(account) { |record| acc << record } }
  end

  def conditions_for(record)
    contributor.each_component(account) { |_| } # resolves the per-sweep threshold
    contributor.conditions_for(record)
  end

  def condition(record, type)
    conditions_for(record).find { |c| c["type"] == type }
  end

  def verdict(record)
    Platform::Status::Condition.verdict_for_set(conditions_for(record))
  end

  describe "scope — what counts as gone" do
    it "excludes terminated instances and nothing else" do
      live = System::NodeInstance::STATUSES - described_class::GONE_STATUSES
      live.each { |status| instance!(status: status) }
      terminated = instance!(status: "terminated")

      refs = components.map { |r| contributor.ref_for(r) }

      expect(components.size).to eq(live.size)
      expect(refs).not_to include(terminated.id.to_s)
    end

    it "keeps an errored instance, which is the one an operator most needs" do
      errored = instance!(status: "error")

      expect(components.map(&:id)).to include(errored.id)
    end

    it "does not enumerate another account's instances" do
      other_account = create(:account)
      other = create(:system_node_instance, account: other_account, status: "running")

      expect(components.map(&:id)).not_to include(other.id)
    end
  end

  describe "Lifecycle maps every value of the status enum" do
    it "has a branch for each STATUSES value" do
      # Iterated from the model's own constant: a value added there without a
      # branch here reds this example instead of silently reading as ok.
      expect(described_class::LIFECYCLE.keys).to match_array(System::NodeInstance::STATUSES)
    end

    System::NodeInstance::STATUSES.each do |status|
      next if status == "terminated" # never enumerated; covered below

      it "maps #{status} to a condition that is not silently ok" do
        record = instance!(status: status)
        lifecycle = condition(record, "Lifecycle")

        expect(lifecycle).to be_present
        expect(lifecycle["reason"]).to eq(described_class::LIFECYCLE.fetch(status)[:reason])
        expect(lifecycle["evidence"]).to include("status" => status)
      end
    end

    it "reports an unrecognised status as unknown, never ok" do
      record = instance!(status: "running")
      # The defect this guards: a value added to STATUSES with no branch here.
      allow(record).to receive(:status).and_return("hibernating")

      lifecycle = contributor.conditions_for(record).find { |c| c["type"] == "Lifecycle" }

      expect(lifecycle["status"]).to eq("unknown")
      expect(lifecycle["reason"]).to eq("UnknownStatus")
      expect(Platform::Status::Condition.verdict_for(lifecycle))
        .to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "sends an errored instance to down, not degraded" do
      record = instance!(status: "error")

      expect(condition(record, "Lifecycle")["severity"]).to eq("down")
      expect(verdict(record)).to eq(Platform::ComponentStatus::DOWN)
    end
  end

  describe "Held is operator intent" do
    it "is true and verdict held for a cordoned instance" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)
      cordon!(record)

      held = condition(record.reload, "Held")

      expect(held["status"]).to be(true)
      expect(held["reason"]).to eq("Cordoned")
      expect(verdict(record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "reports the failure, not the intent, when a held instance is also down" do
      # The ladder's whole point: operator intent hides a planned drain, never a
      # real outage.
      record = instance!(status: "error")
      cordon!(record)

      expect(condition(record.reload, "Held")["status"]).to be(true)
      expect(verdict(record)).to eq(Platform::ComponentStatus::DOWN)
    end

    it "names an ops hold and carries its reason" do
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         ops_hold_at: Time.current, ops_hold_reason: "hardware RMA")

      held = condition(record, "Held")

      expect(held["reason"]).to eq("OpsHold")
      expect(held["message"]).to eq("hardware RMA")
    end

    it "names a draining pool member" do
      pool = create_pool!
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         instance_pool_id: pool.id, pool_state: "draining")

      expect(condition(record, "Held")["reason"]).to eq("Draining")
    end

    it "treats a stopped instance as intent" do
      record = instance!(status: "stopped")

      expect(condition(record, "Held")["reason"]).to eq("Stopped")
      expect(verdict(record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "is false with reason NotHeld for an ordinary instance" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)
      held = condition(record, "Held")

      expect(held["status"]).to be(false)
      expect(held["reason"]).to eq("NotHeld")
      expect(verdict(record)).to eq(Platform::ComponentStatus::OK)
    end
  end

  describe "Progressing" do
    { "pending" => "Provisioning", "provisioning" => "Provisioning",
      "starting" => "Starting", "stopping" => "Stopping", "rebooting" => "Rebooting" }
      .each do |status, reason|
      it "is true with reason #{reason} while #{status}" do
        record = instance!(status: status)

        expect(condition(record, "Progressing")["status"]).to be(true)
        expect(condition(record, "Progressing")["reason"]).to eq(reason)
      end
    end

    it "is false with reason Settled for a running instance" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)

      expect(condition(record, "Progressing")["status"]).to be(false)
      expect(condition(record, "Progressing")["reason"]).to eq("Settled")
    end
  end

  describe "Reachable, against the threshold the sensors already use" do
    let(:threshold) do
      System::Fleet::Sensors::InstanceStatusSensor.resolved_threshold(
        "silent_threshold_seconds", account: account
      )
    end

    it "is fresh inside the threshold" do
      record = instance!(status: "running", last_heartbeat_at: 10.seconds.ago)
      reachable = condition(record, "Reachable")

      expect(reachable["status"]).to be(true)
      expect(reachable["reason"]).to eq("HeartbeatFresh")
      expect(reachable["evidence"]).to include("silent_threshold_seconds" => threshold)
    end

    it "goes stale past it, and degrades the instance" do
      record = instance!(status: "running", last_heartbeat_at: (threshold + 60).seconds.ago)

      expect(condition(record, "Reachable")["reason"]).to eq("HeartbeatStale")
      expect(verdict(record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "follows the account's tuned threshold rather than a constant of its own" do
      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "instance_status",
        config: { "silent_threshold_seconds" => 24 * 3600 }
      )
      record = instance!(status: "running", last_heartbeat_at: 2.hours.ago)

      expect(condition(record, "Reachable")["reason"]).to eq("HeartbeatFresh")
    end

    it "reports a never-heartbeated instance distinctly from a stale one" do
      record = instance!(status: "running", last_heartbeat_at: nil)

      expect(condition(record, "Reachable")["reason"]).to eq("NeverHeartbeat")
    end

    it "is omitted where no heartbeat is expected, rather than claiming blindness" do
      # A stopped instance is off, not unreachable. An `unknown` here would rank
      # every deliberately stopped instance above a held one.
      record = instance!(status: "stopped")

      expect(condition(record, "Reachable")).to be_nil
      expect(verdict(record)).to eq(Platform::ComponentStatus::HELD)
    end
  end

  describe "Enrolled" do
    def token!(consumed: false, expires_at: 1.hour.from_now)
      token, = System::BootstrapToken.issue!(node: node, intended_subject: "spec-subject")
      token.update!(expires_at: expires_at)
      token.update!(consumed_at: Time.current) if consumed
      token
    end

    it "is true once the bootstrap token is consumed" do
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         enrollment_token: token!(consumed: true))

      expect(condition(record, "Enrolled")["status"]).to be(true)
      expect(condition(record, "Enrolled")["reason"]).to eq("Enrolled")
    end

    it "is Progressing rather than a failed Enrolled while the token is still valid" do
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         enrollment_token: token!)

      # A freshly provisioned instance must not read degraded for its whole
      # enrolment window.
      expect(condition(record, "Enrolled")).to be_nil
      expect(condition(record, "Progressing")["reason"]).to eq("EnrollmentPending")
      expect(verdict(record)).to eq(Platform::ComponentStatus::PROGRESSING)
    end

    it "goes false when the token expired unconsumed, which is the stuck state" do
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         enrollment_token: token!(expires_at: 1.hour.ago))

      expect(condition(record, "Enrolled")["status"]).to be(false)
      expect(condition(record, "Enrolled")["reason"]).to eq("EnrollmentTokenExpired")
      expect(verdict(record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "is omitted for an instance that was never issued a token" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)

      expect(condition(record, "Enrolled")).to be_nil
    end
  end

  describe "dependencies" do
    it "declares the node that hosts it and the pool it backs" do
      pool = create_pool!
      record = instance!(status: "running", last_heartbeat_at: Time.current,
                         instance_pool_id: pool.id, pool_state: "ready")

      expect(contributor.dependencies_for(record)).to eq([
        { "kind" => "node", "ref" => node.id.to_s, "relation" => "hosts" },
        { "kind" => "instance_pool", "ref" => pool.id.to_s, "relation" => "backs" }
      ])
    end

    it "omits the pool edge for an instance in no pool" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)

      expect(contributor.dependencies_for(record).map { |e| e["kind"] }).to eq([ "node" ])
    end
  end

  describe "actions carry the permission the controller actually checks" do
    let(:record) { instance!(status: "running", last_heartbeat_at: Time.current) }

    # Read from the routes table and the controller source, never copied as a
    # string: a permission that drifted in the controller would otherwise leave
    # a button that renders and then 403s.
    def controller_source
      @controller_source ||= File.read(
        Object.const_source_location(
          "Api::V1::System::NodeInstancesController"
        ).first
      )
    end

    it "offers only verbs with a real REST route, and each route resolves" do
      contributor.actions_for(record).each do |action|
        recognized = Rails.application.routes.recognize_path(
          action["path"], method: action["method"].downcase.to_sym
        )

        expect(recognized[:controller]).to eq("api/v1/system/node_instances")
        expect(recognized[:action]).to eq(action["key"])
      end
    end

    it "declares the permission the controller action requires" do
      contributor.actions_for(record).each do |action|
        body = controller_source[/^\s*def #{action['key']}\b.*?^\s*end/m]

        expect(body).to be_present, "no #{action['key']} action in the controller"
        expect(body).to include(%(require_permission("#{action['permission']}"))),
                        "#{action['key']} declares #{action['permission']} but the controller checks something else"
      end
    end

    it "offers no cordon, uncordon or replace, because none of them has a REST route" do
      # They exist only as MCP verbs on the fleet tool. A button here would 404.
      keys = contributor.actions_for(record).map { |a| a["key"] }

      expect(keys).not_to include("cordon", "uncordon", "replace")
      expect(keys).to include("reboot")
    end

    it "marks terminate destructive and requires a reason" do
      terminate = contributor.actions_for(record).find { |a| a["key"] == "terminate" }
      reboot    = contributor.actions_for(record).find { |a| a["key"] == "reboot" }

      expect(terminate["destructive"]).to be(true)
      expect(terminate["confirm"]["requires_reason"]).to be(true)
      expect(reboot["destructive"]).to be(false)
    end
  end

  describe "presentation" do
    it "declares a string icon and a group order below platform_subsystem" do
      expect(contributor.presentation["icon"]).to be_a(String)
      expect(contributor.presentation["group_order"])
        .to be > System::Status::Contributors::PlatformSubsystemContributor.new
                  .presentation["group_order"]
    end

    it "uses updated_at as the generation, there being no version column" do
      record = instance!(status: "running", last_heartbeat_at: Time.current)

      expect(contributor.observed_generation_for(record)).to eq(record.updated_at.iso8601)
    end
  end

  # The service is the only sanctioned writer of the cordon marker — its own
  # doc insists the shape lives in exactly one file — so the spec goes through
  # it rather than writing config["cordon"] by hand.
  def cordon!(record)
    result = System::InstanceCordonService.cordon!(
      instance: record, user: create(:user, :admin, account: account), reason: "maintenance"
    )
    raise "cordon refused: #{result.error || result.message}" unless result.ok?

    result
  end

  def create_pool!
    template = create(:system_node_template, account: account)
    System::InstancePool.create!(account: account, node_template: template,
                                 name: "pool-#{SecureRandom.hex(4)}", target_size: 1)
  end
end
