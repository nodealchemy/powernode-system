# frozen_string_literal: true

# Sdwan::* factories. Separate from system_factories.rb to avoid bloat
# (per audit plan P3.7e). Each factory produces a save!-passing record;
# specs override fields as needed via trait blocks or explicit attrs.

FactoryBot.define do
  factory :sdwan_peer, class: "Sdwan::Peer" do
    association :account
    association :network, factory: :sdwan_network
    association :node_instance, factory: :system_node_instance
    sequence(:assigned_address) { |n| "fd00:abcd:1::%x" % (n + 1) }
    status { "pending" }
    publicly_reachable { false }
    capabilities { {} }
    metadata { {} }

    trait :hub do
      publicly_reachable { true }
      endpoint_host_v6 { "fd00:abcd:1::1" }
      endpoint_port { 51_820 }
      listen_port { 51_820 }
    end

    trait :active do
      status { "active" }
      last_handshake_at { Time.current }
    end
  end

  factory :sdwan_firewall_rule, class: "Sdwan::FirewallRule" do
    association :account
    association :network, factory: :sdwan_network
    sequence(:name) { |n| "rule-#{n}" }
    priority { 100 }
    action { "accept" }
    direction { "ingress" }
    protocol { "tcp" }
    # Selectors must use exactly one SELECTOR_KIND ("all", "peer_id", "tag", "cidr").
    # `{"all" => true}` is the simplest match-everything default.
    src_selector { { "all" => true } }
    dst_selector { { "all" => true } }
    enabled { true }
    metadata { {} }
  end

  factory :sdwan_route_policy, class: "Sdwan::RoutePolicy" do
    association :account
    sequence(:name) { |n| "policy-#{n}" }
    scope { "account" }
    direction { "import" }
    # Each statement is { "match" => {...}, "action" => { "type" => "accept"|"reject" } }
    # — action MUST be a hash with a "type" key; match keys must be in MATCH_KEYS.
    statements { [{ "action" => { "type" => "accept" } }] }
    enabled { true }
    metadata { {} }
  end

  factory :sdwan_access_grant, class: "Sdwan::AccessGrant" do
    association :account
    association :network, factory: :sdwan_network
    # Use a `create` block instead of `association :user` to sidestep the
    # parent :user factory's scoped sequence (which fails when nested under
    # another factory's create-strategy). Also keeps user.account aligned.
    user { create(:user, account: account) }
    status { "active" }
    tags { [] }
    granted_at { Time.current }
    metadata { {} }
  end

  factory :sdwan_user_device, class: "Sdwan::UserDevice" do
    # access_grant brings its own account-aligned user; we just chain through.
    access_grant { create(:sdwan_access_grant) }
    sequence(:label) { |n| "device-#{n}" }
    # 32-byte base64 stand-in for a WireGuard public key. Specs that care
    # about real key validity should override with a generated Curve25519
    # public key (see Sdwan::UserDeviceIssuer).
    public_key { Base64.strict_encode64(SecureRandom.bytes(32)) }
    sequence(:assigned_address) { |n| "fd00:abcd:2::%x" % (n + 1) }
    metadata { {} }
  end

  factory :sdwan_host_bridge, class: "Sdwan::HostBridge" do
    association :account
    association :node_instance, factory: :system_node_instance
    # short_id is integer 1-9999 (per-NodeInstance bridge ordinal).
    sequence(:short_id) { |n| (n % 9_999) + 1 }
    sequence(:bridge_name) { |n| "br-pn-%04d" % n }
    kind { "linux" }
    state { "pending" }
    metadata { {} }
  end

  factory :sdwan_ipfix_collector, class: "Sdwan::IpfixCollector" do
    association :account
    sequence(:name) { |n| "ipfix-#{n}" }
    host { "fd00:abcd:3::10" }
    port { 4_739 }
    sampling_rate { 256 }
    state { "active" }
    settings { {} }
  end

  factory :sdwan_ovn_deployment, class: "Sdwan::OvnDeployment" do
    association :account
    nb_db_endpoint { "tcp:[fd00:abcd:4::1]:6641" }
    sb_db_endpoint { "tcp:[fd00:abcd:4::1]:6642" }
    status { "pending" }
    settings { {} }
  end

  factory :sdwan_port_mapping, class: "Sdwan::PortMapping" do
    association :account
    association :network, factory: :sdwan_network
    # Both hub_peer + target_peer must belong to the same network as the
    # port mapping. Without explicit network: scoping, each :sdwan_peer
    # factory call mints its OWN network and the cross-validation fails.
    hub_peer { create(:sdwan_peer, account: account, network: network) }
    # Exactly one of target_peer or target_virtual_ip must be set. Default to
    # target_peer (the most common case). Specs needing the VIP-target variant
    # should pass `target_peer: nil, target_virtual_ip: vip`.
    target_peer { create(:sdwan_peer, account: account, network: network) }
    sequence(:name) { |n| "portmap-#{n}" }
    sequence(:listen_port) { |n| 30_000 + n }
    protocol { "tcp" }
    target_port { 80 }
    enabled { true }
    metadata { {} }
  end

  factory :sdwan_account_bgp, class: "Sdwan::AccountBgp" do
    association :account
    # 32-bit private ASN range (per RFC 6996): 4200000000-4294967294.
    sequence(:as_number) { |n| 4_200_000_000 + n }
    router_id_strategy { "peer_overlay_ipv6_hash" }
    enabled { true }
    metadata { {} }
  end
end
