# frozen_string_literal: true

require "rails_helper"

# IMP-ad21fb7b9965 — the NodeMountPoint family is retired (operator decision).
# It was dead-end plumbing: nothing ever created the InstanceMountPoint join
# rows, so definitions could never reach an instance and the agent-plane
# reader always served an empty set. Storage-backed mounts live on
# System::StorageAssignment (Phase S2). This spec pins the retirement: the
# constants, routes, and tables must stay gone.
RSpec.describe "NodeMountPoint family retirement", type: :request do
  it "no longer defines the retired models" do
    expect(System.const_defined?(:NodeMountPoint)).to be(false)
    expect(System.const_defined?(:InstanceMountPoint)).to be(false)
  end

  it "no longer serves the operator CRUD routes" do
    expect {
      Rails.application.routes.recognize_path("/api/v1/system/node_mount_points", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/api/v1/system/node_mount_points", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end

  it "no longer serves the agent-plane mount_points routes" do
    expect {
      Rails.application.routes.recognize_path("/api/v1/system/node_api/mount_points", method: :get)
    }.to raise_error(ActionController::RoutingError)
  end

  it "has dropped the backing tables" do
    connection = ActiveRecord::Base.connection
    expect(connection.table_exists?("system_node_mount_points")).to be(false)
    expect(connection.table_exists?("system_instance_mount_points")).to be(false)
  end
end
