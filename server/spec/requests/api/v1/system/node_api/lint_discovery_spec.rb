# frozen_string_literal: true

require "rails_helper"

# D1b — the instance-side doors behind the agent's ci.lint_discovery handler
# (campaign 01a08c9b). Both are lease-gated: the module-forge module on the
# node AND an active, unexpired lint_discovery lease held by THIS instance.
# Every gate is pinned on both arms, and the credential the context hands out
# is proven absent from the log, the fleet event and any filed record.
RSpec.describe "Api::V1::System::NodeApi::LintDiscovery", type: :request do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  def builder_instance
    node = create(:system_node, account: account, node_template: node_template)
    forge = System::NodeModule.find_by(account: account, name: "module-forge") ||
            create(:system_node_module, account: account, name: "module-forge")
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

  def lint_lease(node_instance: instance, repository_ids: [ repository.id ], expires_at: 1.hour.from_now)
    System::CiRunnerLease.create!(
      account: account, node_instance: node_instance, status: "leased", purpose: "lint_discovery",
      expires_at: expires_at,
      metadata: { "repository_ids" => repository_ids, "reported_repository_ids" => [] }
    )
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

  def post_result(inst = instance, run_ref: lease.id, repository_id: repository.id, output: rubocop_json)
    post "/api/v1/system/node_api/config/ci_lint_result",
         params: { run_ref: run_ref, repository_id: repository_id, base_path: "/tmp/lint-discovery-x/src",
                   linters: { "ruby" => { "status" => "ran", "exitstatus" => 1, "output" => output } } },
         headers: headers_for(inst), as: :json
  end

  def offers
    Ai::ImprovementRecommendation.where(account: account, recommendation_type: "code_lint")
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
  end
end
