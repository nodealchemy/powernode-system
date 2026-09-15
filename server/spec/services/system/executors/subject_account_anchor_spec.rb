# frozen_string_literal: true

require "rails_helper"

# IMP-71bbba747282 — every System executor resolves its SUBJECT through
# Base#resolve_scoped, anchored on the deferred operation's account.
#
# Executor params are caller-supplied, stored verbatim on the deferred
# operation and replayed at approval with no re-validation, so a bare
# `Model.find(params[...])` acted on whichever account's row the id named. It
# held only while every dispatcher happened to scope the same id upstream.
# IMP-134062908364 converted the Sdwan executors; these are the System ones the
# same census found. One example per lookup: a row owned by ANOTHER account is
# refused before anything is read off it or written to it.
RSpec.describe "System executors anchor their subject lookup on the operation's account" do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  def foreign_pool
    System::InstancePool.create!(
      account: other_account, name: "foreign-pool-#{SecureRandom.hex(3)}",
      node_template: create(:system_node_template, account: other_account),
      target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral", status: "active"
    )
  end

  def foreign_platform
    create(:system_node_platform, account: other_account, disk_image_retention_count: 3)
  end

  def foreign_publication
    create(:system_disk_image_publication, :published, account: other_account,
                                                       node_platform: create(:system_node_platform, account: other_account))
  end

  def foreign_cluster
    create(:devops_kubernetes_cluster, account: other_account)
  end

  def expect_refused(executor, params)
    expect { executor.execute(params, deferred_operation: deferred_operation) }
      .to raise_error(::Ai::DeferredOperation::CrossAccountError, /is not in account #{account.id}/)
  end

  describe "disk_image" do
    it "PromotePublication refuses a foreign publication" do
      pub = foreign_publication
      expect_refused(System::Executors::DiskImage::PromotePublication, { publication_id: pub.id })
    end

    it "RollbackPublication refuses a foreign target publication" do
      pub = foreign_publication
      expect_refused(System::Executors::DiskImage::RollbackPublication, { target_publication_id: pub.id })
    end

    it "RollbackPublication refuses a foreign platform for an in-account target, leaving the platform alone" do
      target = create(:system_disk_image_publication, :published, account: account,
                                                                  node_platform: create(:system_node_platform, account: account))
      platform = foreign_platform

      expect_refused(System::Executors::DiskImage::RollbackPublication,
                     { target_publication_id: target.id, platform_id: platform.id })
      expect(platform.reload.disk_image_sha256).not_to eq(target.sha256)
    end

    it "TriggerWebhook refuses a foreign webhook, leaving it active" do
      webhook = create(:system_disk_image_webhook, account: other_account)

      expect_refused(System::Executors::DiskImage::TriggerWebhook, { webhook_id: webhook.id, action: "revoke" })
      expect(webhook.reload.status).to eq("active")
    end

    it "UpdateRetention refuses a foreign platform, leaving its retention" do
      platform = foreign_platform

      expect_refused(System::Executors::DiskImage::UpdateRetention, { platform_id: platform.id, retention_count: 9 })
      expect(platform.reload.disk_image_retention_count).to eq(3)
    end
  end

  describe "instance_pool" do
    it "DeletePool refuses a foreign pool, leaving it in place" do
      pool = foreign_pool

      expect_refused(System::Executors::InstancePool::DeletePool, { pool_id: pool.id })
      expect(System::InstancePool.exists?(pool.id)).to be(true)
    end

    it "DrainPool refuses a foreign pool" do
      expect_refused(System::Executors::InstancePool::DrainPool, { pool_id: foreign_pool.id })
    end

    it "ReplenishPool refuses a foreign pool" do
      expect_refused(System::Executors::InstancePool::ReplenishPool, { pool_id: foreign_pool.id })
    end
  end

  describe "runtime" do
    it "BootstrapK3sCluster refuses a foreign node instance" do
      instance = create(:system_node_instance, account: other_account)
      expect_refused(System::Executors::Runtime::BootstrapK3sCluster, { instance_id: instance.id, attributes: {} })
    end

    it "ProvisionDockerHost refuses a foreign node instance" do
      instance = create(:system_node_instance, account: other_account)
      expect_refused(System::Executors::Runtime::ProvisionDockerHost, { instance_id: instance.id, attributes: {} })
    end

    it "DecommissionDockerHost refuses a foreign host, leaving it in place" do
      host = create(:devops_docker_host, account: other_account)

      expect_refused(System::Executors::Runtime::DecommissionDockerHost, { host_id: host.id })
      expect(Devops::DockerHost.exists?(host.id)).to be(true)
    end

    it "DecommissionK3sCluster refuses a foreign cluster, leaving it in place" do
      cluster = foreign_cluster

      expect_refused(System::Executors::Runtime::DecommissionK3sCluster, { cluster_id: cluster.id })
      expect(Devops::KubernetesCluster.exists?(cluster.id)).to be(true)
    end

    it "UpgradeK3sRuntime refuses a foreign cluster" do
      expect_refused(System::Executors::Runtime::UpgradeK3sRuntime, { cluster_id: foreign_cluster.id, target_version: "v1.31.0+k3s1" })
    end

    # Devops::KubernetesNode carries no account_id of its own; its account is its
    # cluster's, which is what the anchor has to compare.
    it "DrainK3sNode refuses a node of a foreign cluster" do
      node = create(:devops_kubernetes_node, kubernetes_cluster: foreign_cluster,
                                             node_instance: create(:system_node_instance, account: other_account))
      expect_refused(System::Executors::Runtime::DrainK3sNode, { node_id: node.id })
    end
  end
end
