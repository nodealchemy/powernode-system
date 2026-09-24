# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B3 — the six remaining fleet kinds.
#
# The increment's oracle is "each enum value maps to a condition", so every
# mapping table below is asserted against the MODEL's own constant. A value
# added to a model without a branch here reds this file rather than falling
# through to whatever the last else happened to be.
RSpec.describe "B3 status contributors" do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  def conditions(contributor, record)
    contributor.conditions_for(record)
  end

  def condition(contributor, record, type)
    conditions(contributor, record).find { |c| c["type"] == type }
  end

  def verdict(contributor, record)
    Platform::Status::Condition.verdict_for_set(conditions(contributor, record))
  end

  def components(contributor)
    [].tap { |acc| contributor.each_component(account) { |r| acc << r } }
  end

  # ── The property every one of the six must have ──────────────────────────
  describe "the set as a whole" do
    ALL = {
      "node_module"        => System::Status::Contributors::NodeModuleContributor,
      "sdwan_peer"         => System::Status::Contributors::SdwanPeerContributor,
      "sdwan_service"      => System::Status::Contributors::SdwanServiceContributor,
      "storage_assignment" => System::Status::Contributors::StorageAssignmentContributor,
      "acme_certificate"   => System::Status::Contributors::AcmeCertificateContributor,
      "federation_peer"    => System::Status::Contributors::FederationPeerContributor
    }.freeze

    it "is picked up by the registrar with no edit to it" do
      expect(System::Status::Contributors.kinds).to include(*ALL.keys)
    end

    ALL.each do |kind, klass|
      it "#{kind} declares its KIND, account scoping, a string icon and no core escalation" do
        contributor = klass.new

        expect(klass::KIND).to eq(kind)
        expect(contributor.kind).to eq(kind)
        expect(contributor.account_scoped?).to be(true)
        expect(contributor.presentation["icon"]).to be_a(String)
        # Design §5.4: the fleet lane owns escalation for every one of these.
        expect(contributor.escalates?).to be(false)
      end
    end

    it "sorts every B3 kind after the B2 kinds" do
      lowest = ALL.values.map { |k| k.new.presentation["group_order"] }.min
      highest_b2 = System::Status::Contributors::NodeInstanceContributor.new
                     .presentation["group_order"]

      expect(lowest).to be > highest_b2
    end
  end

  # ── node_module ──────────────────────────────────────────────────────────
  describe System::Status::Contributors::NodeModuleContributor do
    let(:contributor) { described_class.new }

    def module!(*traits, **attrs)
      create(:system_node_module, *traits, account: account, **attrs)
    end

    # The :versioned trait creates a version row; it does not move
    # current_version_id, which is what "published" means.
    def published_module!(*traits, **attrs)
      record = module!(*traits, **attrs)
      version = create(:system_node_module_version, node_module: record, version_number: 1)
      record.update_columns(current_version_id: version.id, current_version_number: 1)
      record.reload
    end

    it "does not dress the variety discriminator up as a health condition" do
      # VARIETIES says what a module IS, never how it is doing. A condition
      # over it would be true for every row by construction.
      record = module!(:with_data_file)
      types = conditions(contributor, record).map { |c| c["type"] }

      expect(types).to match_array(%w[Held Published])
      expect(condition(contributor, record, "Published")["evidence"])
        .to include("variety" => record.variety)
    end

    it "is NeverBuilt when it ships an artifact with no current version, and Published with one" do
      unbuilt = module!(:with_data_file)
      expect(condition(contributor, unbuilt, "Published")["reason"]).to eq("NeverBuilt")
      expect(verdict(contributor, unbuilt)).to eq(Platform::ComponentStatus::DEGRADED)

      manifest_only = module!(manifest_yaml: "name: built-from-manifest\n")
      expect(condition(contributor, manifest_only, "Published")["reason"]).to eq("NeverBuilt")

      built = published_module!(:with_data_file)
      expect(condition(contributor, built, "Published")["reason"]).to eq("Published")
      expect(verdict(contributor, built)).to eq(Platform::ComponentStatus::OK)
    end

    it "asks a spec-only module nothing about versions, so it reads ok rather than degraded forever" do
      # Nodes materialise the spec off the row; only an artifact needs a version.
      spec_only = module!

      expect(condition(contributor, spec_only, "Published")).to be_nil
      expect(verdict(contributor, spec_only)).to eq(Platform::ComponentStatus::OK)
    end

    it "holds a disabled module rather than calling it broken" do
      record = published_module!(enabled: false)

      expect(condition(contributor, record, "Held")["reason"]).to eq("Disabled")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "declares the instance edge only for an instance-scoped module" do
      instance = create(:system_node_instance, account: account, node: node, status: "running")
      scoped = module!(node_instance: instance)

      expect(contributor.dependencies_for(scoped))
        .to eq([ { "kind" => "node_instance", "ref" => instance.id.to_s, "relation" => "requires" } ])
      expect(contributor.dependencies_for(module!)).to eq([])
    end

    it "does not enumerate another account's modules" do
      own = module!
      other = create(:system_node_module, account: create(:account))

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end
  end

  # ── sdwan_peer ───────────────────────────────────────────────────────────
  describe System::Status::Contributors::SdwanPeerContributor do
    let(:contributor) { described_class.new }
    let(:network)     { create(:sdwan_network, account: account) }

    def peer!(**attrs)
      instance = create(:system_node_instance, account: account, node: node, status: "running")
      create(:sdwan_peer, account: account, network: network, node_instance: instance, **attrs)
    end

    it "maps every value of Sdwan::Peer::STATUSES" do
      expect(described_class::LIFECYCLE.keys).to match_array(Sdwan::Peer::STATUSES)
    end

    Sdwan::Peer::STATUSES.each do |status|
      it "maps #{status}" do
        record = peer!(status: status, last_handshake_at: Time.current)

        expect(condition(contributor, record, "Lifecycle")["reason"])
          .to eq(described_class::LIFECYCLE.fetch(status)[:reason])
      end
    end

    it "reports an unmapped status as unknown, never ok" do
      record = peer!(status: "active", last_handshake_at: Time.current)
      allow(record).to receive(:status).and_return("quiesced")

      lifecycle = condition(contributor, record, "Lifecycle")

      expect(lifecycle["status"]).to eq("unknown")
      expect(lifecycle["reason"]).to eq("UnknownStatus")
    end

    it "reads the handshake directly, so a stale status shows up as disagreement" do
      # status is DERIVED from last_handshake_at by a method nothing calls on a
      # schedule, and it writes with update_column. A contributor reading only
      # status would report whatever the last recompute concluded.
      record = peer!(status: "active", last_handshake_at: 1.hour.ago)

      expect(condition(contributor, record, "Lifecycle")["reason"]).to eq("Active")
      expect(condition(contributor, record, "Handshake")["reason"]).to eq("Lost")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::DOWN)
    end

    it "walks the model's own two handshake windows" do
      fresh = peer!(status: "active", last_handshake_at: 10.seconds.ago)
      stale = peer!(status: "active",
                    last_handshake_at: (Sdwan::Peer::HEALTHY_HANDSHAKE_WINDOW.to_i + 30).seconds.ago)

      expect(condition(contributor, fresh, "Handshake")["reason"]).to eq("Fresh")
      expect(condition(contributor, stale, "Handshake")["reason"]).to eq("Stale")
      expect(condition(contributor, stale, "Handshake")["severity"]).to be_nil
    end

    it "treats a never-handshaked pending peer as progressing, not failed" do
      record = peer!(status: "pending", last_handshake_at: nil)

      expect(condition(contributor, record, "Handshake")["reason"]).to eq("NeverHandshaked")
      expect(condition(contributor, record, "Progressing")["reason"]).to eq("Handshaking")
    end

    it "loads every peer's node with the batch, not one query per peer" do
      3.times { peer!(status: "active", last_handshake_at: Time.current) }
      node_queries = 0
      counter = lambda do |*, payload|
        node_queries += 1 if payload[:sql].to_s.include?('"system_nodes"')
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        contributor.each_component(account) { |peer| contributor.environment_id_for(peer) }
      end

      expect(node_queries).to eq(1)
    end

    it "does not enumerate another account's peers" do
      own = peer!(status: "active", last_handshake_at: Time.current)
      other_account = create(:account)
      other_instance = create(:system_node_instance, account: other_account, status: "running",
                                                     node: create(:system_node, account: other_account))
      other = create(:sdwan_peer, account: other_account, node_instance: other_instance,
                                  network: create(:sdwan_network, account: other_account))

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end
  end

  # ── sdwan_service ────────────────────────────────────────────────────────
  describe System::Status::Contributors::SdwanServiceContributor do
    let(:contributor) { described_class.new }

    def service!(**attrs)
      create(:sdwan_service, account: account, **attrs)
    end

    it "maps every value of both enums" do
      expect(described_class::LIFECYCLE.keys).to match_array(Sdwan::Service::STATUSES)
      expect(described_class::HEALTH.keys).to match_array(Sdwan::Service::HEALTH_STATES)
    end

    Sdwan::Service::HEALTH_STATES.each do |state|
      it "maps health_state #{state}" do
        record = service!(health_state: state)

        expect(condition(contributor, record, "Health")["reason"])
          .to eq(described_class::HEALTH.fetch(state)[:reason])
      end
    end

    it "keeps intent and observation separate: disabled is held, silent is degraded" do
      # "unknown" is what SdwanServiceHealthSensor writes to every non-active
      # service each tick, so it is the only health a disabled service has.
      disabled = service!(status: "disabled", health_state: "unknown")
      silent   = service!(status: "active", health_state: "silent")

      expect(condition(contributor, disabled, "Held")["reason"]).to eq("Disabled")
      expect(verdict(contributor, disabled)).to eq(Platform::ComponentStatus::HELD)

      expect(condition(contributor, silent, "Held")["status"]).to be(false)
      expect(verdict(contributor, silent)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "does not alarm on unobservable, which nobody can fix" do
      record = service!(status: "active", health_state: "unobservable")

      expect(condition(contributor, record, "Health")["status"]).to eq("unknown")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "declares the certificate edge only when one is bound" do
      cert = create(:system_acme_certificate, account: account)
      bound = service!(local_certificate: cert)

      expect(contributor.dependencies_for(bound))
        .to eq([ { "kind" => "acme_certificate", "ref" => cert.id.to_s, "relation" => "requires" } ])
      expect(contributor.dependencies_for(service!)).to eq([])
    end

    it "does not ask a disabled service the health question at all" do
      expect(condition(contributor, service!(status: "disabled", health_state: "unknown"), "Health")).to be_nil
      expect(condition(contributor, service!(status: "active", health_state: "unknown"), "Health")).to be_present
    end

    it "does not enumerate another account's services" do
      own = service!
      other = create(:sdwan_service, account: create(:account))

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end
  end

  # ── storage_assignment ───────────────────────────────────────────────────
  describe System::Status::Contributors::StorageAssignmentContributor do
    let(:contributor) { described_class.new }
    let(:instance)    { create(:system_node_instance, account: account, node: node, status: "running") }

    # State is written with update_columns AFTER create, deliberately: the
    # model's after_commit fires a reconcile that rewrites status and
    # chown_state, so a status passed to the factory does not survive the save.
    # This spec is about how a given stored state MAPS, not about how the
    # reconciler reaches it.
    def assignment!(status: "pending", chown_state: "complete", **attrs)
      # A unique index covers (file_storage_id, node_instance_id), so each
      # assignment in one example needs its own storage row.
      # Two unique indexes cover this table — (file_storage_id, node_instance_id)
      # and (node_instance_id, mount_path) — so each assignment in one example
      # needs both its own storage row and its own mount path.
      own_storage = create(:file_storage, account: account, node_mount_capable: true)
      record = create(:system_storage_assignment, account: account, node_instance: instance,
                                                  file_storage_id: own_storage.id,
                                                  mount_path: "/mnt/#{SecureRandom.hex(4)}", **attrs)
      record.update_columns(status: status, chown_state: chown_state)
      record.reload
    end

    it "maps every value of both enums" do
      expect(described_class::LIFECYCLE.keys).to match_array(System::StorageAssignment::STATUSES)
      expect(described_class::CHOWN.keys).to match_array(System::StorageAssignment::CHOWN_STATES)
    end

    System::StorageAssignment::STATUSES.each do |status|
      it "maps status #{status}" do
        record = assignment!(status: status)

        expect(condition(contributor, record, "Lifecycle")["reason"])
          .to eq(described_class::LIFECYCLE.fetch(status)[:reason])
      end
    end

    System::StorageAssignment::CHOWN_STATES.each do |state|
      it "maps chown_state #{state}" do
        record = assignment!(status: "mounted", chown_state: state)

        expect(condition(contributor, record, "Chown")["reason"])
          .to eq(described_class::CHOWN.fetch(state)[:reason])
      end
    end

    it "says mounted AND broken when a mounted volume's chown failed" do
      # One column cannot say both, which is why there are two.
      record = assignment!(status: "mounted", chown_state: "failed")

      expect(condition(contributor, record, "Lifecycle")["reason"]).to eq("Mounted")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "sends a failed mount to down and a degraded one to degraded" do
      expect(verdict(contributor, assignment!(status: "failed")))
        .to eq(Platform::ComponentStatus::DOWN)
      expect(verdict(contributor, assignment!(status: "degraded")))
        .to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "holds a disabled assignment" do
      record = assignment!(status: "mounted", enabled: false)

      expect(condition(contributor, record, "Held")["reason"]).to eq("Disabled")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "declares the instance edge" do
      record = assignment!(status: "mounted")

      expect(contributor.dependencies_for(record))
        .to eq([ { "kind" => "node_instance", "ref" => instance.id.to_s, "relation" => "requires" } ])
    end

    it "does not enumerate another account's assignments" do
      own = assignment!(status: "mounted")
      other_account = create(:account)
      other_instance = create(:system_node_instance, account: other_account, status: "running",
                                                     node: create(:system_node, account: other_account))
      other_storage = create(:file_storage, account: other_account, node_mount_capable: true)
      other = create(:system_storage_assignment, account: other_account, node_instance: other_instance,
                                                 file_storage_id: other_storage.id)

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end
  end

  # ── acme_certificate ─────────────────────────────────────────────────────
  describe System::Status::Contributors::AcmeCertificateContributor do
    let(:contributor) { described_class.new }

    def cert!(**attrs)
      create(:system_acme_certificate, account: account, **attrs)
    end

    it "maps every value of STATUSES" do
      expect(described_class::LIFECYCLE.keys).to match_array(System::AcmeCertificate::STATUSES)
    end

    (System::AcmeCertificate::STATUSES - System::AcmeCertificate::TERMINAL_STATUSES).each do |status|
      it "maps #{status}" do
        record = cert!(status: status)

        expect(condition(contributor, record, "Lifecycle")["reason"])
          .to eq(described_class::LIFECYCLE.fetch(status)[:reason])
      end
    end

    it "excludes revoked certificates, which the model itself treats as historical" do
      live = cert!(status: "valid", expires_at: 90.days.from_now)
      revoked = cert!(status: "revoked")

      refs = components(contributor).map(&:id)

      expect(refs).to include(live.id)
      expect(refs).not_to include(revoked.id)
    end

    it "keeps expired and failed, which are the rows an operator must act on" do
      expired = cert!(status: "expired", expires_at: 10.days.ago)
      failed  = cert!(status: "failed")

      expect(components(contributor).map(&:id)).to include(expired.id, failed.id)
      expect(verdict(contributor, expired)).to eq(Platform::ComponentStatus::DOWN)
    end

    it "flags a valid certificate inside the model's own renewal window" do
      soon    = cert!(status: "valid", expires_at: 20.days.from_now)
      current = cert!(status: "valid", expires_at: 90.days.from_now)

      expect(condition(contributor, soon, "Expiry")["reason"]).to eq("ExpiringSoon")
      expect(verdict(contributor, soon)).to eq(Platform::ComponentStatus::DEGRADED)

      expect(condition(contributor, current, "Expiry")["reason"]).to eq("Current")
      expect(verdict(contributor, current)).to eq(Platform::ComponentStatus::OK)
    end

    it "omits the expiry question for a certificate that has never issued" do
      record = cert!(status: "pending", expires_at: nil)

      expect(condition(contributor, record, "Expiry")).to be_nil
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::PROGRESSING)
    end

    it "does not enumerate another account's certificates" do
      own = cert!(status: "valid", expires_at: 90.days.from_now)
      other = create(:system_acme_certificate, account: create(:account), status: "valid",
                                               expires_at: 90.days.from_now)

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end
  end

  # ── federation_peer ──────────────────────────────────────────────────────
  describe System::Status::Contributors::FederationPeerContributor do
    let(:contributor) { described_class.new }

    def peer!(*traits, **attrs)
      create(:system_federation_peer, *traits, account: account, **attrs)
    end

    it "maps every value of STATUSES" do
      expect(described_class::LIFECYCLE.keys).to match_array(System::FederationPeer::STATUSES)
    end

    (System::FederationPeer::STATUSES - described_class::GONE_STATUSES).each do |status|
      it "maps #{status}" do
        record = peer!(status: status)

        expect(condition(contributor, record, "Lifecycle")["reason"])
          .to eq(described_class::LIFECYCLE.fetch(status)[:reason])
      end
    end

    it "excludes revoked, the model's one terminal state, and keeps suspended" do
      suspended = peer!(status: "suspended")
      revoked   = peer!(status: "revoked")

      refs = components(contributor).map(&:id)

      expect(refs).to include(suspended.id)
      expect(refs).not_to include(revoked.id)
    end

    it "holds a suspended peer and carries its reason" do
      record = peer!(status: "suspended", metadata: { "suspension_reason" => "maintenance window" })

      held = condition(contributor, record, "Held")

      expect(held["reason"]).to eq("Suspended")
      expect(held["message"]).to eq("maintenance window")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::HELD)
    end

    it "asks the heartbeat question only of a platform peer that should be sending one" do
      # heartbeat_stale? returns false unconditionally for an sdwan_only peer,
      # so emitting the condition there would report "fresh" for something that
      # never heartbeats — a constant dressed as an observation.
      sdwan_only = peer!(status: "active", peer_kind: "sdwan_only")
      expect(condition(contributor, sdwan_only, "Heartbeat")).to be_nil

      platform = peer!(:active, last_heartbeat_at: Time.current)
      expect(condition(contributor, platform, "Heartbeat")["reason"]).to eq("HeartbeatFresh")
    end

    it "degrades a platform peer whose heartbeat went stale" do
      record = peer!(:active,
                     last_heartbeat_at: (System::FederationPeer::HEARTBEAT_STALE_AFTER.to_i + 60).seconds.ago)

      expect(condition(contributor, record, "Heartbeat")["reason"]).to eq("HeartbeatStale")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "treats a proposed peer as progressing, not broken" do
      record = peer!(status: "proposed")

      expect(condition(contributor, record, "Progressing")["reason"]).to eq("AwaitingAcceptance")
      expect(verdict(contributor, record)).to eq(Platform::ComponentStatus::PROGRESSING)
    end

    it "degrades a proposed peer whose acceptance token expired, naming the expiry" do
      digest = Digest::SHA256.hexdigest("token")
      expired = peer!(status: "proposed", acceptance_token_digest: digest,
                      acceptance_token_expires_at: 1.hour.ago)
      live = peer!(status: "proposed", acceptance_token_digest: digest,
                   acceptance_token_expires_at: 1.day.from_now)

      acceptance = condition(contributor, expired, "Acceptance")
      expect(acceptance["reason"]).to eq("AcceptanceTokenExpired")
      expect(acceptance["message"]).to include("expired at")
      expect(verdict(contributor, expired)).to eq(Platform::ComponentStatus::DEGRADED)

      expect(condition(contributor, live, "Acceptance")["reason"]).to eq("AcceptanceTokenValid")
      expect(verdict(contributor, live)).to eq(Platform::ComponentStatus::PROGRESSING)
    end

    it "does not enumerate another account's peers" do
      own = peer!(status: "active")
      other = create(:system_federation_peer, account: create(:account))

      expect(components(contributor).map(&:id)).to include(own.id)
      expect(components(contributor).map(&:id)).not_to include(other.id)
    end

    # fc-25 deleted the /system/federation/* frontend route outright (no
    # redirect) — FederationHubPage was merged into ServiceDeliveryPage's
    # Peers tab. A component-status link at the old path would 404.
    it "links to the peers tab on the merged Service Delivery page, not the deleted federation route" do
      record = peer!(status: "active")

      expect(contributor.links_for(record))
        .to eq([ { "label" => "Federation", "path" => "/app/system/service-delivery/peers" } ])
    end
  end

  # ── end to end ───────────────────────────────────────────────────────────
  describe "through the core sweep" do
    it "writes a row for each of the six kinds with no edit to the registrar" do
      instance = create(:system_node_instance, account: account, node: node, status: "running")
      network = create(:sdwan_network, account: account)
      storage = create(:file_storage, account: account, node_mount_capable: true)

      create(:system_node_module, account: account)
      create(:sdwan_peer, account: account, network: network, node_instance: instance)
      create(:sdwan_service, account: account)
      create(:system_storage_assignment, account: account, node_instance: instance,
                                         file_storage_id: storage.id)
      create(:system_acme_certificate, account: account, status: "valid",
                                       expires_at: 90.days.from_now)
      create(:system_federation_peer, account: account)

      Platform::Status::SweepService.run_once!(account)

      kinds = Platform::ComponentStatus.where(account_id: account.id).pluck(:component_kind).uniq

      expect(kinds).to include("node_module", "sdwan_peer", "sdwan_service",
                               "storage_assignment", "acme_certificate", "federation_peer")
    end
  end
end
