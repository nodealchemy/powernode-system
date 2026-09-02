# frozen_string_literal: true

require "rails_helper"

# `restart_after_update` — a module declares that updating IT requires
# restarting ANOTHER module's systemd service.
#
# Why this exists: the agent restarts a service only when that service's own
# manifest services-block hash drifts (agent/internal/mount/state.go
# LastAttachedManifestHashes + lifecycle/service.go AttachServices, which
# "restarts only services whose unit file content actually changed"). A module
# declaring `services: []` — powernode-extension-system does — therefore
# NEVER triggers a restart of anything, so its new code lands on disk while the
# running Rails process keeps serving the previous version in memory. Observed
# live 2026-08-16: extension v53 materialized (running_module_digests matched
# the promoted oci_digest byte-for-byte) and a 200s poll of /up recorded zero
# non-200 responses. The deploy looked complete and was inert.
RSpec.describe System::RestartAfterUpdate do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  # The declaring module: ships controllers/jobs that run INSIDE another
  # module's processes, so it owns no services of its own.
  let(:extension) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, name: "powernode-extension-system")
  end

  # The target module: owns the rails service whose process must be recycled.
  let(:backend) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, name: "powernode-hub-backend")
  end

  let(:digest) { "sha256:#{'a' * 64}" }

  def declare!(mod, targets)
    mod.update!(config: mod.config.merge("restart_after_update" => targets))
  end

  def publish_version!(mod, digest:, armed: true)
    version = System::NodeModuleVersion.create!(
      node_module: mod, version_number: (mod.versions.maximum(:version_number) || 0) + 1,
      mask: [], file_spec: [], package_spec: [], config: {}, oci_digest: digest
    )
    mod.update!(current_version: version, current_version_number: version.version_number)
    described_class.arm!(node_module: mod, version: version) if armed
    version
  end

  def instance_running(digests)
    create(:system_node_instance, :running, node: node).tap do |inst|
      inst.update!(running_module_digests: digests, last_heartbeat_at: Time.current)
    end
  end

  before do
    node.node_modules << extension
    node.node_modules << backend
  end

  describe ".declarations" do
    it "parses a well-formed declaration" do
      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])

      decls = described_class.declarations(extension)

      expect(decls.size).to eq(1)
      expect(decls.first.module_name).to eq("powernode-hub-backend")
      expect(decls.first.services).to eq([ "rails" ])
    end

    it "is empty when the module declares nothing (absent field == today's behaviour)" do
      expect(described_class.declarations(extension)).to eq([])
    end
  end

  describe ".unit_name" do
    # CLAUDE.md standing rule: a guessed unit name does NOT error —
    # `systemctl restart` on a nonexistent unit fails silently in a `||`
    # chain and looks like a successful deploy. The server holds both halves,
    # so it must COMPUTE the name the way agent/internal/lifecycle/service.go
    # UnitName does: powernode-<moduleID>-<svcName>.service.
    it "composes powernode-<module-uuid>-<service>.service from the module UUID" do
      expect(described_class.unit_name(backend.id, "rails"))
        .to eq("powernode-#{backend.id}-rails.service")
    end
  end

  describe ".reconcile! — materialization gate (TRAP 1)" do
    before { declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ]) }

    it "enqueues a restart once the instance reports the promoted digest" do
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)

      expect { described_class.reconcile!(instance: instance) }
        .to change { instance.tasks.where(command: "restart").count }.by(1)

      task = instance.tasks.where(command: "restart").last
      expect(task.options["unit"]).to eq("powernode-#{backend.id}-rails.service")
      # DECLARED, not inferred: without this the dispatcher would be left
      # choosing between one systemd unit and a whole-VM reboot.
      expect(task.options["scope"]).to eq("unit")
      expect(::System::ExecutionDispatcher.agent_delegated?(task.command, task.options)).to be true
      expect(task.status).to eq("pending")
    end

    it "enqueues NOTHING while the instance is still running the OLD digest" do
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => "sha256:#{'b' * 64}")

      expect { described_class.reconcile!(instance: instance) }
        .not_to change { instance.tasks.where(command: "restart").count }
    end

    it "enqueues NOTHING when the promoted version was never armed" do
      # A version promoted before this feature existed, or by a module that
      # does not declare the field, must behave exactly as it does today.
      publish_version!(extension, digest: digest, armed: false)
      instance = instance_running(extension.id => digest)

      expect { described_class.reconcile!(instance: instance) }
        .not_to change { instance.tasks.where(command: "restart").count }
    end
  end

  describe ".reconcile! — deduplication (TRAP 2)" do
    it "restarts a shared unit ONCE when several modules name it" do
      other = create(:system_node_module, account: account, node_platform: platform,
                     category: category, name: "powernode-extension-marketing")
      node.node_modules << other

      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      declare!(other,     [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      publish_version!(extension, digest: digest)
      publish_version!(other, digest: digest)

      instance = instance_running(extension.id => digest, other.id => digest)

      expect { described_class.reconcile!(instance: instance) }
        .to change { instance.tasks.where(command: "restart").count }.by(1)
    end

    it "does not re-enqueue on a second heartbeat carrying the same digest" do
      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)

      described_class.reconcile!(instance: instance)

      expect { described_class.reconcile!(instance: instance) }
        .not_to change { instance.tasks.where(command: "restart").count }
    end

    it "enqueues again for a NEW digest" do
      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)
      described_class.reconcile!(instance: instance)
      # The first restart has to have RUN before a second is meaningful: while
      # it is still in flight it will pick up whatever is on disk when it
      # fires, so coalescing onto it is correct and a second task redundant.
      instance.tasks.where(command: "restart").each { |t| t.update_columns(status: "complete") }

      next_digest = "sha256:#{'c' * 64}"
      publish_version!(extension, digest: next_digest)
      instance.update!(running_module_digests: { extension.id => next_digest })

      expect { described_class.reconcile!(instance: instance) }
        .to change { instance.tasks.where(command: "restart").count }.by(1)
    end
  end

  # A platform deploy is THREE modules that materialize on their own
  # heartbeats. Collapsing duplicates within a single pass is not enough:
  # without an in-flight check each one queues its own restart of the same
  # rails unit, so the platform bounces three times back to back.
  describe ".reconcile! — coalescing across separate heartbeats" do
    it "does not queue a second restart of a unit that already has one in flight" do
      other = create(:system_node_module, account: account, node_platform: platform,
                     category: category, name: "powernode-extension-marketing")
      node.node_modules << other

      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      declare!(other,     [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      publish_version!(extension, digest: digest)
      publish_version!(other, digest: "sha256:#{'f' * 64}")

      # First module materializes on its own heartbeat.
      instance = instance_running(extension.id => digest)
      described_class.reconcile!(instance: instance)

      # Second module materializes on a LATER heartbeat, naming the same unit.
      instance.update!(running_module_digests: {
        extension.id => digest, other.id => "sha256:#{'f' * 64}"
      })

      expect { described_class.reconcile!(instance: instance) }
        .not_to change { instance.tasks.where(command: "restart").count }
    end
  end

  # A dependant child (config/instance variety, created via
  # NodeModuleAssignment#create_dependant!) carries node_id + parent_module_id
  # and has NO assignment row at all. NodeApi::ModulesController#node_modules
  # treats both pathways as "on this node" and carries a comment that honouring
  # only the assignment path was a bug — a resolver that misses them silently
  # restarts nothing, which is the exact inert-deploy failure this feature
  # exists to remove.
  describe ".reconcile! — target attached as a dependant child" do
    it "resolves a target that has no assignment row" do
      child = create(:system_node_module, account: account, node_platform: platform,
                     category: category, name: "powernode-hub-worker",
                     variety: "config", node_id: node.id, parent_module: backend)

      declare!(extension, [ { "module" => "powernode-hub-worker", "services" => [ "sidekiq" ] } ])
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)

      expect { described_class.reconcile!(instance: instance) }
        .to change { instance.tasks.where(command: "restart").count }.by(1)

      expect(instance.tasks.where(command: "restart").last.options["unit"])
        .to eq("powernode-#{child.id}-sidekiq.service")
    end
  end

  # Rolling back is the recovery path, so an inert rollback is the worst case:
  # the known-good files land on disk while the bad code keeps serving. The
  # rolled-back version's digest was already restarted once, so a dedup key
  # built from the digest alone is permanently consumed.
  describe ".reconcile! — rollback re-promotes an older version" do
    it "restarts again when current_version moves BACK to an earlier version" do
      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      v1 = publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)
      described_class.reconcile!(instance: instance)
      instance.tasks.where(command: "restart").each { |t| t.update_columns(status: "complete") }

      next_digest = "sha256:#{'c' * 64}"
      publish_version!(extension, digest: next_digest)
      instance.update!(running_module_digests: { extension.id => next_digest })
      described_class.reconcile!(instance: instance)
      instance.tasks.where(command: "restart").each { |t| t.update_columns(status: "complete") }

      # Roll back to v1 through promote_to_version! — arm!'s only call site.
      # NOT "the single choke point": five other writers move current_version_id
      # without passing it (spec/lint/node_module_current_version_write_seam_spec.rb).
      extension.promote_to_version!(v1)
      instance.update!(running_module_digests: { extension.id => digest })

      expect { described_class.reconcile!(instance: instance) }
        .to change { instance.tasks.where(command: "restart").count }.by(1)
    end
  end

  describe ".reconcile! — target not attached to this instance" do
    it "is a clean no-op, not an error" do
      node.node_modules.destroy(backend)
      declare!(extension, [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ])
      publish_version!(extension, digest: digest)
      instance = instance_running(extension.id => digest)

      expect { described_class.reconcile!(instance: instance) }
        .not_to change { instance.tasks.where(command: "restart").count }
    end
  end

  describe ".reconcile! — settling a self-targeting restart (TRAP 3)" do
    # On ops-hub the rails unit IS the platform. `systemctl restart` kills the
    # process the agent posts its Result to, so agent/internal/runtime/tasks/
    # loop.go processTask's Complete() call errors and — verified in that
    # terminal function — is NOT retried: it only calls OnError. The task is
    # left `running` forever, so a SUCCESSFUL restart reads as a hung task.
    let(:instance) { instance_running({}) }

    def in_flight_restart!(started_at:)
      System::Task.create!(
        account: account, operable: instance, command: "restart", status: "pending",
        options: { "scope" => "unit", "unit" => "powernode-#{backend.id}-rails.service",
                   "restart_after_update" => { "triggers" => [] } }
      ).tap { |t| t.update_columns(status: "running", started_at: started_at) }
    end

    it "completes an in-flight unit restart once the grace window has passed" do
      task = in_flight_restart!(started_at: (described_class::SETTLE_GRACE + 1.minute).ago)

      described_class.reconcile!(instance: instance)

      expect(task.reload.status).to eq("complete")
    end

    it "leaves a restart that is still inside the grace window alone" do
      task = in_flight_restart!(started_at: Time.current)

      described_class.reconcile!(instance: instance)

      expect(task.reload.status).to eq("running")
    end

    # The asymmetry argument is strong but not total: a restart that STOPS the
    # unit and then fails to start it also takes the platform down, so the
    # agent's Fail POST is lost too and looks identical from here. Marking the
    # completion as inferred is what lets a late, genuine failure report
    # overrule it rather than be rejected as "cannot fail from complete".
    it "records that the completion was INFERRED, not reported" do
      task = in_flight_restart!(started_at: (described_class::SETTLE_GRACE + 1.minute).ago)

      described_class.reconcile!(instance: instance)

      expect(described_class.settled?(task.reload)).to be true
    end

    it "does not mark an agent-reported completion as inferred" do
      task = in_flight_restart!(started_at: Time.current)

      described_class.reconcile!(instance: instance)

      expect(described_class.settled?(task.reload)).to be false
    end
  end

  describe ".offerable — suppressing re-execution" do
    # agent loop.go tick() does NOT filter by status, and StatusController's
    # pending_tasks includes `running`. Without this suppression a restart
    # whose completion report was lost is re-offered every ~30s and
    # re-executed forever: a restart LOOP, not merely a hung task.
    let(:instance) { instance_running({}) }

    it "withholds an in-flight unit restart from the agent's task list" do
      task = System::Task.create!(
        account: account, operable: instance, command: "restart", status: "pending",
        options: { "scope" => "unit", "unit" => "powernode-#{backend.id}-rails.service",
                   "restart_after_update" => { "triggers" => [] } }
      )
      task.update_columns(status: "running")

      expect(described_class.offerable(instance.tasks).pluck(:id)).not_to include(task.id)
    end

    it "still offers a restart that has not been picked up yet" do
      task = System::Task.create!(
        account: account, operable: instance, command: "restart", status: "pending",
        options: { "scope" => "unit", "unit" => "powernode-#{backend.id}-rails.service",
                   "restart_after_update" => { "triggers" => [] } }
      )

      expect(described_class.offerable(instance.tasks).pluck(:id)).to include(task.id)
    end

    it "still offers an in-flight task that is NOT a unit restart" do
      task = System::Task.create!(
        account: account, operable: instance, command: "sync_modules", status: "pending"
      )
      task.update_columns(status: "running")

      expect(described_class.offerable(instance.tasks).pluck(:id)).to include(task.id)
    end

    # offerable and settle! must cover EXACTLY the same set. A unit restart
    # created by an operator or another tool carries no restart_after_update
    # provenance, so settle! will never close it — withholding it too would
    # strand it `running` with its crash-recovery re-offer lost.
    it "still offers an in-flight unit restart it does not own" do
      task = System::Task.create!(
        account: account, operable: instance, command: "restart", status: "pending",
        options: { "scope" => "unit", "unit" => "powernode-#{backend.id}-rails.service" }
      )
      task.update_columns(status: "running")

      expect(described_class.offerable(instance.tasks).pluck(:id)).to include(task.id)
    end
  end

  describe "SETTLE_GRACE" do
    # "abc".to_i == 0 would settle every in-flight restart on the very next
    # heartbeat, inverting the safety this constant exists to provide.
    it "never falls below a floor that a restart plus boot can fit inside" do
      expect(described_class::SETTLE_GRACE).to be >= 60.seconds
    end
  end
end
