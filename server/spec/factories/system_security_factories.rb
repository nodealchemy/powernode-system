# frozen_string_literal: true

# Security-domain factories: certificates, GitOps repositories. Per audit
# plan P3.7e. Specs touching mTLS code paths use :system_node_certificate;
# specs touching the GitOps reconciler use :system_gitops_repository.

FactoryBot.define do
  factory :system_node_certificate, class: "System::NodeCertificate" do
    association :account
    association :node_instance, factory: :system_node_instance
    sequence(:serial)  { |n| format("%032x", n) }
    sequence(:subject) { |n| "CN=node-instance-#{n}" }
    not_before { 1.day.ago }
    not_after  { 90.days.from_now }
    issuer_subject { "CN=Powernode Internal CA" }
    # DB check constraint: subject_kind IN ('instance', 'federation_peer')
    subject_kind { "instance" }

    # pem_chain is not required by validation but specs that verify chain
    # parsing should set this. Default to nil (lazy-load from Vault path).
    pem_chain { nil }

    trait :revoked do
      revoked_at { 5.minutes.ago }
      revocation_reason { "operator_revoked" }
    end

    trait :expired do
      not_after { 1.hour.ago }
    end

    trait :worker_kind do
      subject_kind { "worker" }
    end
  end

  factory :system_gitops_repository, class: "System::GitopsRepository" do
    association :account
    sequence(:name) { |n| "fleet-config-#{n}" }
    sequence(:repo_url) { |n| "git@git.ipnode.net:powernode/fleet-config-#{n}.git" }
    branch { "main" }
    enabled { true }
    auto_apply { false }
    metadata { {} }

    trait :syncing do
      last_status { "pending" }
    end

    trait :synced do
      last_status { "success" }
      last_synced_at { 5.minutes.ago }
      last_synced_revision { SecureRandom.hex(20) }
      last_diff_count { 0 }
    end

    trait :failed do
      last_status { "failed" }
      last_error { "Synthetic failure for testing" }
      last_synced_at { 10.minutes.ago }
    end
  end
end
