# frozen_string_literal: true

# CVE-ops + fleet event factories. Per audit plan P3.7e — currently
# inline-constructed in spec bodies; extracting here avoids duplication
# as P0.1 controller specs + P2.2 sensor specs land.

FactoryBot.define do
  factory :system_cve, class: "System::Cve" do
    # CVE-YYYY-NNNN format. Year stays current; the sequence on NNNN keeps
    # rows unique within a test run.
    sequence(:cve_id) { |n| "CVE-#{Time.current.year}-#{format('%04d', 9_000 + n)}" }
    severity { "high" }
    summary { "Synthetic CVE for testing" }
    affected_packages { [{ "name" => "openssl", "version" => "<3.1.4", "ecosystem" => "deb" }] }
    reference_url { "https://nvd.nist.gov/vuln/detail/#{cve_id}" }
    published_at { 1.day.ago }
    ingested_at { 1.hour.ago }
    feed_source { "TEST" }
    metadata { {} }

    trait :critical do
      severity { "critical" }
    end

    trait :ghsa_source do
      feed_source { "GHSA" }
    end
  end

  factory :system_cve_exposure, class: "System::CveExposure" do
    association :cve, factory: :system_cve
    association :node_module_version, factory: :system_node_module_version
    sequence(:package_name) { |n| "package-#{n}" }
    package_version { "3.1.3" }
    state { "open" }
    detected_at { 1.hour.ago }
    metadata { {} }

    trait :resolved do
      state { "resolved" }
      resolved_at { 5.minutes.ago }
      resolution_note { "Upgraded to fixed version" }
    end

    trait :remediating do
      state { "remediating" }
    end
  end

  factory :system_fleet_event, class: "System::FleetEvent" do
    association :account
    sequence(:kind) { |n| "system.test.event_#{n}" }
    severity { "low" }
    source { "test" }
    payload { {} }
    sequence(:correlation_id) { |n| "corr-#{n}-#{SecureRandom.hex(4)}" }
    emitted_at { Time.current }

    trait :high_severity do
      severity { "high" }
    end

    trait :critical do
      severity { "critical" }
    end
  end
end
