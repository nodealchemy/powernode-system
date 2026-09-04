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
    node = create(:system_node, account: account, node_template: node_template)
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

      # Campaign 019f6084 item L — EVR lockfile: sourced from each module's
      # PackageModuleLink#package_version (materialized_module seeds "1.0.0"
      # above), recorded both at the batch-metadata top level (operator/audit
      # visibility) and embedded inside package_context (what the orchestrator
      # actually reads to thread the pin into task options).
      expect(batch.metadata["package_lock"]).to eq(
        "app-#{suffix}" => "1.0.0", "lib-#{suffix}" => "1.0.0"
      )
      expect(ctx["package_lock"]).to eq(batch.metadata["package_lock"])
      expect(ctx["modules"]["app-#{suffix}"]["package_version"]).to eq("1.0.0")
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
      expect(web_task.options["package_version"]).to eq("1.0.0")
      expect(web_task.options["package_repo_id"]).to eq(repo.id)
      expect(web_task.options["apt_snapshot"]).to eq("20260415T000000Z")
      expect(web_task.options["batch_id"]).to eq(batch.id)

      # No ci.module_build tasks were created (this is NOT the platform path).
      expect(System::Task.where(account: account, command: "ci.module_build").count).to eq(0)
    end

    it "omits package_version from task options when a module in the closure carries no PackageModuleLink at all (backward-compat: absent lockfile → unpinned)" do
      seed_pool_member
      # PackageModuleLink.package_version is NOT NULL at the DB level (every
      # real materialized link always has one — see the model's own presence
      # validation), so the realistic "nothing to pin" case isn't a link with
      # a blank version, it's a module with NO link at all — #module_context
      # / #package_lock are already nil-safe against that (`link&.…`).
      mod = create(:system_node_module, account: account, name: "unpinned-#{suffix}", auto_generated: false)
      expect(mod.package_module_link).to be_nil

      batch = described_class.dispatch!(
        repository: repo, modules: [ mod ], architectures: [ "amd64" ], account: account, requested_by: user
      ).batch

      expect(batch.metadata["package_lock"]).to eq({})
      task = batch.member_tasks.first
      expect(task.options).not_to have_key("package_version")
    end

    it "returns an error result (no batch) for an empty module set" do
      result = described_class.dispatch!(
        repository: repo, modules: [], architectures: [ "amd64" ], account: account
      )
      expect(result.ok?).to be(false)
      expect(result.batch).to be_nil
    end
  end

  # Campaign 019f6084 inc J — multi-arch package builds. mmdebstrap can't
  # produce a multi-arch rootfs in one invocation the way platform modules'
  # single buildx push can, so a multi-arch package build fans out into one
  # independent lease + ci.package_build Task PER (module, arch) — mirrored
  # by PackageClosureBuildBridge#build_plan / NativeModuleBuildOrchestrator
  # #load_modules_state's compound "slug@arch" state key.
  describe ".dispatch! — multi-arch" do
    def complete_task!(task, result:)
      task.update!(status: "complete", completed_at: Time.current,
                   events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                      "result" => result, "timestamp" => Time.current.iso8601 } ])
    end

    it "creates one ci.package_build member task per (module, arch), each on its own OCI tag" do
      SiteSetting.set("system.module_builds.max_concurrent_builders", "10", setting_type: "integer")
      4.times { seed_pool_member }
      top = materialized_module("app-#{suffix}")
      dep = materialized_module("lib-#{suffix}")

      result = described_class.dispatch!(
        repository: repo, modules: [ top, dep ], architectures: [ "amd64", "arm64" ],
        account: account, requested_by: user
      )
      expect(result.ok?).to be(true)
      batch = result.batch

      # 2 modules x 2 arches = 4 independent build units.
      tasks = batch.member_tasks.to_a
      expect(tasks.size).to eq(4)
      expect(tasks.map { |t| t.options["module"] }).to match_array(
        [ "app-#{suffix}", "app-#{suffix}", "lib-#{suffix}", "lib-#{suffix}" ]
      )
      expect(tasks.map { |t| t.options["architecture"] }).to match_array(%w[amd64 amd64 arm64 arm64])

      # Distinct OCI ref/tag per arch of the same module — two builders never
      # race to push the same mutable registry tag.
      app_tasks = tasks.select { |t| t.options["module"] == "app-#{suffix}" }
      expect(app_tasks.map { |t| t.options["oci_ref"] }.uniq.size).to eq(2)

      # module_slugs is the distinct-module display list, not one entry per
      # build unit; planned_count IS the raw build-unit count.
      expect(batch.module_slugs).to match_array([ "app-#{suffix}", "lib-#{suffix}" ])
      expect(batch.planned_count).to eq(4)

      # Plan + package_context both reflect the full requested arch set.
      expect(batch.metadata["plan"].map { |p| p["architecture"] }.uniq).to match_array(%w[amd64 arm64])
      expect(batch.metadata["package_context"]["architectures"]).to match_array(%w[amd64 arm64])
    end

    it "still produces exactly one task per module, with a byte-identical plan shape, for a single requested arch" do
      seed_pool_member
      seed_pool_member
      top = materialized_module("solo-#{suffix}")
      dep = materialized_module("solodep-#{suffix}")

      batch = described_class.dispatch!(
        repository: repo, modules: [ top, dep ], architectures: [ "amd64" ],
        account: account, requested_by: user
      ).batch

      tasks = batch.member_tasks.to_a
      expect(tasks.size).to eq(2)
      expect(tasks.map { |t| t.options["architecture"] }).to eq(%w[amd64 amd64])
      # No "architecture" key at all in a single-arch plan entry — same shape
      # dispatch! produced before multi-arch fan-out existed.
      batch.metadata["plan"].each { |entry| expect(entry.keys).to match_array(%w[module oci_ref]) }
    end

    it "finalizes each arch of a module independently — one arch's failure doesn't block the other's success" do
      seed_pool_member
      seed_pool_member
      mod = materialized_module("multi-#{suffix}")

      batch = described_class.dispatch!(
        repository: repo, modules: [ mod ], architectures: [ "amd64", "arm64" ],
        account: account, requested_by: user
      ).batch

      tasks = batch.member_tasks.to_a
      amd64_task = tasks.detect { |t| t.options["architecture"] == "amd64" }
      arm64_task = tasks.detect { |t| t.options["architecture"] == "arm64" }
      complete_task!(amd64_task, result: { "oci_digest" => "sha256:amd64digest" })
      arm64_task.update!(status: "failed", completed_at: Time.current, error_message: "builder ENOSPC")

      sign_result = System::ModuleSigningService::Result.new(ok?: true, digest: "sha256:amd64digest")
      publish_result = System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil)
      # Only the amd64 finalize path should ever reach sign/publish here —
      # arm64 failed the build itself, before signing is even attempted.
      expect(System::ModuleSigningService).to receive(:sign!).once.and_return(sign_result)
      expect(System::ModulePublicationProcessor).to receive(:process!).once.and_return(publish_result)

      result = System::NativeModuleBuildOrchestrator.advance!(batch: batch)

      expect(result.succeeded).to eq(1)
      expect(result.retried).to eq(1) # arm64 gets a fresh-lease retry, not an immediate fail (max_attempts default 2)

      modules_state = batch.reload.metadata["modules"]
      expect(modules_state["#{mod.name}@amd64"]["state"]).to eq("succeeded")
      expect(modules_state["#{mod.name}@arm64"]["state"]).to eq("queued")
      # Both entries carry the real module name, never the compound key.
      expect(modules_state.values.map { |e| e["module"] }.uniq).to eq([ mod.name ])
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
      # `native_build:` is passed by finalize_success! for every module, package
      # or platform — it routes the processor to record the artifact from the
      # registry-resolved erofs LAYER digest rather than the dev stub path. This
      # expectation predates that argument; asserting the three that matter and
      # allowing the rest keeps it from breaking again the next time the
      # processor's signature grows.
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(hash_including(node_module: mod,
                             tag: batch.metadata["package_context"]["tag"],
                             promote: true))
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
