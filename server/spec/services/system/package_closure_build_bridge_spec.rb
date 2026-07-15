# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc2 §4.3.2 — the native-build bridge. A materialized
# package closure is routed through System::NativeModuleBuildOrchestrator via a
# ModuleBuildBatch(trigger: "package") instead of the legacy fire-and-forget
# Gitea dispatch, so on-demand builds get Vault signing + inc10 parity + a
# batch an agent can poll. Build EXECUTION is mocked (no mmdebstrap/erofs/Vault
# — the live builder fleet run is PARKED); this proves the server-side wiring:
# batch creation, member-task correlation, and the finalize file_spec step.
#
# Pool/lease setup mirrors native_module_build_orchestrator_spec.rb's
# seed_pool_member pattern (InstancePool has no factory in this suite).
RSpec.describe System::PackageClosureBuildBridge do
  let(:account)         { create(:account) }
  let(:user)            { create(:user, account: account) }
  let(:node_template)   { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:instance_type)   { create(:system_provider_instance_type) }
  let(:suffix)          { "br#{SecureRandom.hex(3)}" }

  let(:repo) do
    create(:system_package_repository, account: account,
                                       apt_config: { "suite" => "noble", "components" => [ "main" ] },
                                       last_synced_at: Time.utc(2026, 4, 15, 0, 0, 0))
  end

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template,
      name: System::NativeModuleBuildOrchestrator::DEFAULT_POOL_NAME,
      target_size: 5, min_size: 1, max_size: 5,
      lifecycle_class: "ephemeral", status: "active",
      provider_region: provider_region, provider_instance_type: instance_type
    )
  end

  def seed_pool_member
    pool
    node = create(:system_node, account: account, node_template: node_template, lifecycle_class: "ephemeral")
    create(:system_node_instance,
           node: node, name: "member-#{SecureRandom.hex(3)}", variety: "cloud", status: "running",
           provider_region: provider_region, provider_instance_type: instance_type,
           instance_pool_id: pool.id, pool_state: "ready", pool_warming_started_at: 1.minute.ago)
  end

  # A materialized package module: a NodeModule + its PackageModuleLink, exactly
  # as PackageModuleMaterializer would leave them.
  def materialized_module(pkg_name)
    mod = create(:system_node_module, account: account, name: pkg_name, auto_generated: false)
    System::PackageModuleLink.create!(
      node_module: mod, package_repository: repo, package_name: pkg_name,
      package_version: "1.0.0", architecture: "amd64", file_spec_source: "package_query"
    )
    mod
  end

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
  end

  describe ".dispatch!" do
    it "creates a ModuleBuildBatch(trigger: package) over the closure, queryable by id/trigger" do
      seed_pool_member
      top = materialized_module("app-#{suffix}")
      dep = materialized_module("lib-#{suffix}")

      result = described_class.dispatch!(
        repository: repo, modules: [ top, dep ], architectures: [ "amd64" ],
        account: account, requested_by: user
      )

      expect(result.ok?).to be(true)
      batch = result.batch
      expect(batch).to be_present
      expect(batch.trigger).to eq("package")
      expect(batch.module_slugs).to match_array([ "app-#{suffix}", "lib-#{suffix}" ])

      # Queryable by id + trigger scope.
      expect(System::ModuleBuildBatch.find(batch.id)).to eq(batch)
      expect(System::ModuleBuildBatch.by_trigger("package")).to include(batch)

      # §4.3.4 — repository sync snapshot threaded into the build context.
      ctx = batch.metadata["package_context"]
      expect(ctx["repository_id"]).to eq(repo.id)
      expect(ctx["architecture"]).to eq("amd64")
      expect(ctx["apt_snapshot"]).to eq("20260415T000000Z")
      expect(ctx["apt_suite"]).to eq("noble")
      expect(ctx["modules"]).to have_key("app-#{suffix}")
    end

    it "dispatches ci.package_build member tasks correlated by batch_id, carrying the build recipe" do
      seed_pool_member
      seed_pool_member
      top = materialized_module("web-#{suffix}")
      dep = materialized_module("pcre-#{suffix}")

      result = described_class.dispatch!(
        repository: repo, modules: [ top, dep ], architectures: [ "amd64" ],
        account: account, requested_by: user
      )
      batch = result.batch

      # Member tasks are ci.package_build (NOT ci.module_build) and are found by
      # the batch's own containment query.
      expect(batch.member_task_command).to eq("ci.package_build")
      tasks = batch.member_tasks.to_a
      expect(tasks.size).to eq(2)
      expect(tasks.map(&:command).uniq).to eq([ "ci.package_build" ])
      expect(tasks.map { |t| t.options["batch_id"] }.uniq).to eq([ batch.id ])

      web_task = tasks.detect { |t| t.options["module"] == "web-#{suffix}" }
      expect(web_task.options["build_kind"]).to eq("package")
      expect(web_task.options["package_name"]).to eq("web-#{suffix}")
      expect(web_task.options["package_repo_id"]).to eq(repo.id)
      expect(web_task.options["apt_snapshot"]).to eq("20260415T000000Z")
      expect(web_task.options["batch_id"]).to eq(batch.id)

      # No ci.module_build tasks were created (this is NOT the platform path).
      expect(System::Task.where(account: account, command: "ci.module_build").count).to eq(0)
    end

    it "returns an error result (no batch) for an empty module set" do
      result = described_class.dispatch!(
        repository: repo, modules: [], architectures: [ "amd64" ], account: account
      )
      expect(result.ok?).to be(false)
      expect(result.batch).to be_nil
    end
  end

  # The finalize path is owned by NativeModuleBuildOrchestrator#advance!; here we
  # prove its package branch: apply the builder's dpkg -L file_spec via
  # PackageBuildWebhookService, THEN sign + publish through the same path as
  # platform modules (both mocked — no real Vault/OCI).
  describe "finalize (orchestrator package branch)" do
    def complete_task!(task, result:)
      task.update!(status: "complete", completed_at: Time.current,
                   events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                      "result" => result, "timestamp" => Time.current.iso8601 } ])
    end

    it "applies the dpkg -L file_spec via PackageBuildWebhookService, then signs + publishes" do
      seed_pool_member
      mod = materialized_module("nginx-#{suffix}")
      batch = described_class.dispatch!(
        repository: repo, modules: [ mod ], architectures: [ "amd64" ], account: account, requested_by: user
      ).batch

      task = batch.member_tasks.first
      complete_task!(task, result: {
        "oci_digest" => "sha256:deadbeef",
        "file_spec"  => [ "/usr/sbin/nginx", "/etc/nginx/nginx.conf" ]
      })

      sign_result = System::ModuleSigningService::Result.new(ok?: true, digest: "sha256:deadbeef")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil)

      # The package-specific finalize step: file_spec written via the webhook
      # service's public seam (single source of truth for both-columns write).
      expect(System::PackageBuildWebhookService).to receive(:apply_file_spec!)
        .with(node_module: mod, file_spec: [ "/usr/sbin/nginx", "/etc/nginx/nginx.conf" ])
        .and_call_original
      # ...then the SAME sign→publish path platform modules use.
      expect(System::ModuleSigningService).to receive(:sign!).and_return(sign_result)
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(node_module: mod, tag: batch.metadata["package_context"]["tag"], promote: true)
        .and_return(publish_result)

      result = System::NativeModuleBuildOrchestrator.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(batch.reload.status).to eq("complete")
      expect(batch.metadata["modules"]["nginx-#{suffix}"]["state"]).to eq("succeeded")
      # file_spec actually landed on the module (dpkg -L → file_spec + dependency_spec).
      expect(mod.reload.file_spec_text).to include("/usr/sbin/nginx")
      expect(mod.dependency_spec_text).to include("/etc/nginx/nginx.conf")
    end
  end
end
