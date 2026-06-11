# frozen_string_literal: true

require "rails_helper"

# Audit F6-06 — WorkerApi::ModulesController#download returned a download_url
# pointing at /api/v1/system/worker_api/files/modules/:id/:filename, a route
# that does not exist (only node_api/files/modules is defined), so module
# data-file download via the worker_api path 404'd.
RSpec.describe "Api::V1::System::WorkerApi::Modules#download", type: :request do
  let(:account)  { create(:account) }
  let!(:worker)  { create(:worker, :system_worker, account: account, status: "active") }
  let(:headers)  { worker_mtls_headers(worker) }
  let(:node)     { create(:system_node, account: account, worker: worker) }
  let(:mod)      { create(:system_node_module, :with_data_file, account: account) }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?).and_return(true)
    create(:system_node_module_assignment, node: node, node_module: mod)
  end

  it "returns a download_url that resolves to a real route" do
    get "/api/v1/system/worker_api/modules/#{mod.id}/download", headers: headers

    expect(response).to have_http_status(:ok)
    download_url = JSON.parse(response.body).dig("data", "file", "download_url")
    expect(download_url).to be_present

    # The URL must map to an actual route — recognize_path raises
    # ActionController::RoutingError for the dead worker_api/files path.
    path = URI.parse(download_url).path
    expect { Rails.application.routes.recognize_path(path, method: :get) }.not_to raise_error
  end

  it "points at the node_api files/modules endpoint with the id and filename" do
    get "/api/v1/system/worker_api/modules/#{mod.id}/download", headers: headers

    download_url = JSON.parse(response.body).dig("data", "file", "download_url")
    expect(download_url).to eq("/api/v1/system/node_api/files/modules/#{mod.id}/#{mod.data_file_name}")

    recognized = Rails.application.routes.recognize_path(URI.parse(download_url).path, method: :get)
    expect(recognized[:controller]).to eq("api/v1/system/node_api/files")
    expect(recognized[:action]).to eq("module_file")
  end
end
