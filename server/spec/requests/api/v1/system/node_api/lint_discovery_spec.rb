# frozen_string_literal: true

require "rails_helper"

# D1b — the instance-side doors behind the agent's ci.lint_discovery handler
# (campaign 01a08c9b). Both are lease-gated: the module-forge module on the
# node AND a live (leased, registered or busy), unexpired lint_discovery lease
# held by THIS instance, whose ci.lint_discovery task is running there. Every
# gate is pinned on both arms, and the credential the context hands out is
# proven absent from the log, the fleet event and any filed record.
RSpec.describe "Api::V1::System::NodeApi::LintDiscovery", type: :request do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  def builder_instance(acct = account)
    template = acct == account ? node_template : create(:system_node_template, account: acct)
    node = create(:system_node, account: acct, node_template: template)
    forge = System::NodeModule.find_by(account: acct, name: "module-forge") ||
            create(:system_node_module, account: acct, name: "module-forge")
    create(:system_node_module_assignment, node: node, node_module: forge)
    create(:system_node_instance, :running, node: node).tap do |inst|
      System::NodeCertificate.create!(
        node_instance: inst, serial: SecureRandom.hex(16), subject: "CN=#{inst.id}",
        not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
      )
    end
  end

  let!(:instance) { builder_instance }

  let(:token) { "gta_#{SecureRandom.hex(20)}" }
  let!(:repository) do
    create(:git_repository, account: account, name: "core").tap do |repo|
      repo.credential.update!(credentials: { "access_token" => token })
    end
  end

  # A lint lease as the executor leaves it once the agent has taken its task
  # up: live, unexpired, naming its repositories, and pointing at a
  # ci.lint_discovery task that is RUNNING on the holder's own instance.
  def lint_lease(node_instance: instance, acct: account, repository_ids: [ repository.id ],
                 expires_at: 1.hour.from_now, purpose: "lint_discovery")
    lease = System::CiRunnerLease.create!(
      account: acct, node_instance: node_instance, status: "leased", purpose: purpose,
      expires_at: expires_at,
      metadata: { "repository_ids" => repository_ids, "reported_repository_ids" => [] }
    )
    task = System::Task.create!(account: acct, operable: node_instance, command: System::LintDiscoveryExecutor::COMMAND,
                                status: "running", options: { "run_ref" => lease.id, "repository_ids" => repository_ids })
    lease.update_columns(build_task_id: task.id)
    lease
  end

  let!(:lease) { lint_lease }

  def headers_for(inst)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{inst.id}")) }
  end

  def json = JSON.parse(response.body)

  def get_context(inst = instance)
    get "/api/v1/system/node_api/config/ci_lint_context", headers: headers_for(inst)
  end

  def rubocop_json(message: "Prefer double-quoted strings")
    { "files" => [ { "path" => "app/models/thing.rb", "offenses" => [
      { "severity" => "convention", "message" => message, "cop_name" => "Style/StringLiterals",
        "location" => { "start_line" => 3, "start_column" => 1 } }
    ] } ], "summary" => { "inspected_file_count" => 1, "offense_count" => 1 } }.to_json
  end

  def post_result(inst = instance, run_ref: lease.id, repository_id: repository.id, output: rubocop_json,
                  base_path: "/tmp/lint-discovery-x/src")
    post "/api/v1/system/node_api/config/ci_lint_result",
         params: { run_ref: run_ref, repository_id: repository_id, base_path: base_path,
                   linters: { "ruby" => { "status" => "ran", "exitstatus" => 1, "output" => output } } },
         headers: headers_for(inst), as: :json
  end

  def lint_task = System::Task.find(lease.build_task_id)

  def offers
    Ai::ImprovementRecommendation.where(account: account, recommendation_type: "code_lint")
  end

  def discovery_runs
    AuditLog.where(action: "ai.improvement_discovery.run", account_id: account.id)
  end

  # Everything Rails logs during the block, request logging included.
  def captured_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |l| l.level = :debug }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  describe "GET config/ci_lint_context" do
    it "hands the lease's repositories, with their credentials, to the instance that holds it" do
      get_context

      expect(response).to have_http_status(:ok)
      expect(json["data"]["repositories"]).to contain_exactly(
        "id" => repository.id, "clone_url" => repository.clone_url_for_devops,
        "ref" => "main", "username" => "x-access-token", "token" => token
      )
    end

    it "hands the runner core's output limit, and follows the setting" do
      get_context
      expect(json["data"]["output_limit_bytes"]).to eq(Ai::Codebase::StaticAnalysisService::DEFAULT_OUTPUT_LIMIT)

      SiteSetting.set(Ai::Codebase::StaticAnalysisService::OUTPUT_LIMIT_SETTING, 4096, setting_type: "integer")
      get_context
      expect(json["data"]["output_limit_bytes"]).to eq(4096)
    end

    it "hands the runner the lease deadline, and the workdir base only when one is set" do
      get_context
      expect(json["data"]["deadline_at"]).to eq(lease.expires_at.iso8601)
      expect(json["data"]).to include("workdir_base" => nil)

      SiteSetting.set(System::LintDiscoveryExecutor::WORKDIR_BASE_SETTING, "/srv/lint", setting_type: "string")
      get_context
      expect(json["data"]["workdir_base"]).to eq("/srv/lint")
    end

    it "hands out nothing the lease does not name, even of the same account" do
      create(:git_repository, account: account, name: "docs")

      get_context

      expect(json["data"]["repositories"].map { |r| r["id"] }).to eq([ repository.id ])
    end

    it "refuses an instance that holds no lease of its own" do
      get_context(builder_instance)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    it "refuses an expired lease, even before the sweep has released it" do
      lease.update!(expires_at: 1.minute.ago)

      get_context

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    it "refuses a node that is not a module-forge builder" do
      System::NodeModuleAssignment.where(node: instance.node).delete_all

      get_context

      expect(response).to have_http_status(:forbidden)
    end

    it "writes the credential to neither the log nor the fleet event" do
      events = []
      allow(System::Fleet::EventBroadcaster).to receive(:emit!) { |**kwargs| events << kwargs }

      log = captured_log { get_context }

      expect(response).to have_http_status(:ok)
      expect(log).not_to include(token)
      expect(events.to_json).not_to include(token)
      expect(events.map { |e| e[:payload]["repository_ids"] }).to eq([ [ repository.id ] ])
    end

    # Review F1: `active` counts a releasing lease, and a release that raised
    # between begin_release! and complete_release! stays releasing until its
    # deadline. Only a lease its holder may still use reads anything.
    %w[releasing released errored].each do |status|
      it "reads no credential through a #{status} lease, even before its deadline" do
        lease.update_columns(status: status)

        get_context

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include(token)
      end
    end

    %w[registered busy].each do |status|
      it "still hands the credential to the holder of a #{status} lease" do
        lease.update_columns(status: status)

        get_context

        expect(response).to have_http_status(:ok)
        expect(json["data"]["repositories"].map { |r| r["token"] }).to eq([ token ])
      end
    end

    # Review F2: the credential is the runner's while ITS task runs: not
    # before the agent has taken the task up, and not once the task is over.
    %w[pending scheduled complete failed aborted cancelled].each do |task_status|
      it "reads no credential while the lease's task is #{task_status}" do
        lint_task.update_columns(status: task_status)

        get_context

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include(token)
      end
    end

    it "reads no credential through a lease that names no task" do
      lease.update_columns(build_task_id: nil)

      get_context

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    it "reads no credential through a running lint task on another instance" do
      elsewhere = System::Task.create!(
        account: account, operable: builder_instance, command: System::LintDiscoveryExecutor::COMMAND,
        status: "running", options: { "run_ref" => lease.id, "repository_ids" => [ repository.id ] }
      )
      lease.update_columns(build_task_id: elsewhere.id)

      get_context

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    it "reads no credential through a running task that is not a lint task" do
      lint_task.update_columns(command: "ci.module_build")

      get_context

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    # Adopted from the security review's probe (D1b, L1): each pins a guard no
    # other example in this file notices missing.
    it "opens nothing for a live lease of another purpose, even one whose task is a running lint task" do
      lease.update_columns(status: "released")
      lint_lease(purpose: "module_build")

      get_context

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
    end

    it "hands none of this account's repositories to another account's lease that names them" do
      other = create(:account)
      foreign = builder_instance(other)
      foreign_lease = lint_lease(node_instance: foreign, acct: other)

      get_context(foreign)

      # The foreign lease is live and its task runs: only the repository
      # set's account scope stands between it and this account's credential.
      expect(response).to have_http_status(:ok)
      expect(json["data"]["repositories"]).to eq([])
      expect(response.body).not_to include(token)

      post_result(foreign, run_ref: foreign_lease.id)

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
      expect(discovery_runs.count).to eq(0)
    end
  end

  describe "POST config/ci_lint_result" do
    it "hands the lease holder's result to core, which files the offer" do
      post_result

      expect(response).to have_http_status(:ok)
      expect(json["data"]).to eq("ingest_status" => "completed", "findings" => 1, "offers_created" => 1)
      expect(offers.count).to eq(1)
      expect(lease.reload.metadata["reported_repository_ids"]).to eq([ repository.id ])
    end

    it "refuses another instance, even one holding a lint lease of its own" do
      intruder = builder_instance
      lint_lease(node_instance: intruder)

      post_result(intruder)

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
    end

    it "refuses an instance that holds no lease at all" do
      post_result(builder_instance)

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
    end

    it "refuses the holder once its lease has expired" do
      lease.update!(expires_at: 1.minute.ago)

      post_result

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
    end

    it "refuses a repository the lease does not name" do
      other = create(:git_repository, account: account, name: "docs")

      post_result(repository_id: other.id)

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
    end

    it "refuses a run_ref that is not the holder's lease" do
      post_result(run_ref: SecureRandom.uuid)

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
    end

    it "refuses a second report for the same repository" do
      post_result
      post_result

      expect(response).to have_http_status(:conflict)
      expect(offers.count).to eq(1)
    end

    it "files nothing from a result carrying the handed-out credential, and logs no trace of it" do
      log = captured_log { post_result(output: rubocop_json(message: "token=#{token}")) }

      expect(response).to have_http_status(:ok)
      expect(json["data"]["ingest_status"]).to eq("failed")
      expect(offers.count).to eq(0)
      expect(log).not_to include(token)
      last = AuditLog.where(action: "ai.improvement_discovery.run", account_id: account.id).last
      expect(last.metadata).to include("failure" => "credential_in_payload")
      expect(last.metadata.to_json).not_to include(token)
    end

    it "refuses the holder's report once its task has finished" do
      lint_task.update_columns(status: "complete")

      post_result

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
      expect(discovery_runs.count).to eq(0)
    end

    it "refuses the holder's report while its lease is releasing" do
      lease.update_columns(status: "releasing")

      post_result

      expect(response).to have_http_status(:forbidden)
      expect(offers.count).to eq(0)
      expect(discovery_runs.count).to eq(0)
    end

    # Review F3/F4: a result's values reach the request log before any gate
    # can refuse them, so they are filtered (below) AND held to their shape:
    # base_path is the absolute path the runner cloned into, run_ref the lease id.
    [ "src", "tmp/lint/src", "/tmp/../etc", "/tmp/./src", "/tmp//src", "/tmp/src/",
      "/tmp/lint dir/src", "/tmp/src\n", "", "/#{'a' * 1100}", { "path" => "/tmp/src" } ].each do |base_path|
      it "refuses a base_path that is not an absolute path (#{base_path.inspect[0, 32]}) and files nothing" do
        post_result(base_path: base_path)

        expect(response).to have_http_status(:unprocessable_content)
        expect(offers.count).to eq(0)
        expect(discovery_runs.count).to eq(0)
        expect(lease.reload.metadata["reported_repository_ids"]).to eq([])
      end
    end

    [ "lease-1", "gta_not_a_uuid", "0190f5a8-0000-7000-8000-00000000000",
      "0190f5a8-0000-7000-8000-000000000000\n" ].each do |run_ref|
      it "refuses a run_ref that is not a lease reference (#{run_ref.inspect}) and files nothing" do
        post_result(run_ref: run_ref)

        expect(response).to have_http_status(:unprocessable_content)
        expect(offers.count).to eq(0)
        expect(discovery_runs.count).to eq(0)
      end
    end
  end

  # Review F3/F4: Rails writes "Parameters: {...}" before any action runs, so
  # a credential a runner echoed into ANY field would reach the log whatever
  # the gates then decide. Every value these doors receive is filtered.
  describe "request logging" do
    def expect_logged_without_token(log)
      expect(log).to include("Parameters:") # the capture saw the parameter line
      expect(log).to include("[FILTERED]")
      expect(log).not_to include(token)
    end

    it "logs no credential echoed in base_path, and core files nothing from it" do
      log = captured_log { post_result(base_path: "/tmp/lint-discovery-x/#{token}/src") }

      expect(response).to have_http_status(:ok)
      expect(json["data"]["ingest_status"]).to eq("failed")
      expect(offers.count).to eq(0)
      expect_logged_without_token(log)
    end

    it "logs no credential echoed in run_ref, and the refusal echoes none" do
      log = captured_log { post_result(run_ref: token) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(token)
      expect_logged_without_token(log)
    end

    it "logs no credential echoed in repository_id, and the refusal echoes none" do
      log = captured_log { post_result(repository_id: token) }

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(token)
      expect_logged_without_token(log)
    end

    it "filters every value of the lint doors and leaves every other controller's alone" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      lint_path = Api::V1::System::NodeApi::LintDiscoveryController.controller_path
      values = { "base_path" => "/a/b", "run_ref" => "r", "repository_id" => "i",
                 "linters" => { "ruby" => { "output" => "o", "exitstatus" => 1 } } }

      expect(filter.filter(values.merge("controller" => lint_path, "action" => "result"))).to eq(
        "controller" => lint_path, "action" => "result",
        "base_path" => "[FILTERED]", "run_ref" => "[FILTERED]", "repository_id" => "[FILTERED]",
        "linters" => { "ruby" => { "output" => "[FILTERED]", "exitstatus" => 1 } }
      )
      expect(filter.filter(values.merge("controller" => "api/v1/internal/codebase", "action" => "show")))
        .to include("base_path" => "/a/b", "run_ref" => "r", "repository_id" => "i")
    end
  end
end
