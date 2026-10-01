# frozen_string_literal: true

module System
  module Storage
    # IMP-04ce3762270f — read-only preflight for the SMB credential rotation
    # that remediates IMP-ab6e4075a007 (plaintext SMB passwords in
    # System::Task#options). Rotation itself stays operator-run; this only
    # answers whether it is safe to start, and it never writes, dispatches a
    # task, or touches a credential.
    #
    # Two preconditions, per SMB backend instance (the instance SmbUserManager
    # would dispatch storage.smb_user.apply to: the gateway for a gateway_proxy
    # storage, the export host otherwise):
    #
    #   agent_check   — the instance's agent can resolve the CredentialRef
    #                   payload a rotation dispatches.
    #   account_check — the instance serves SMB storages of exactly one
    #                   account, and that account is its own.
    #
    # Every check is pass / fail / unknown, and unknown NEVER reads as pass:
    # the verdict is safe_to_rotate only when there is at least one backend and
    # everything is a proven pass. No SMB storages at all is its own verdict
    # (no_smb_backends), not a pass by vacuity.
    #
    # HOW "AT OR AFTER THE COMMIT" IS DECIDED. The only thing the platform
    # records about an agent build is NodeInstance#agent_version, the string
    # the agent heartbeats. scripts/module-build/stage15.sh stamps it as
    # "<UTC build date>-<12-hex source sha>". A sha is not orderable and the
    # server has no git history to resolve ancestry against, so the build DATE
    # is the comparable:
    #
    #   built before the commit's date  → fail (the commit did not exist yet)
    #   built on the commit's date      → unknown, unless the sha is the commit
    #   built after the commit's date   → pass, basis "build_date"
    #
    # "build_date" proves the binary was built after the commit existed, not
    # that the source tree contained it — a build from a branch cut earlier
    # would pass. That holds for module builds off the mainline, and the basis
    # is carried on every row so the reader can see which rows rest on it.
    # Anything that is not a stamped version ("dev", "unknown", a tag) is
    # unknown, as is a version last reported by a heartbeat that has gone stale.
    #
    # TWO FLOORS. The finding named VALIDATION_FLOOR as the threshold, but that
    # commit only added payload validation: an agent at or after it REFUSES the
    # CredentialRef payload (no password field) instead of running samba-tool
    # with an empty one. The agent that can actually resolve a CredentialRef is
    # CREDENTIAL_REF_FLOOR, a descendant. Passing requires the latter; the
    # former only distinguishes the two failure reasons.
    class SmbRotationPreflight
      # Added Validate() for every storage.* payload.
      VALIDATION_FLOOR = { sha: "c0edfa8277a4", date: Date.new(2026, 9, 1) }.freeze
      # Resolves `credential` / `new_credential` CredentialRefs (IMP-ab6e4075a007).
      CREDENTIAL_REF_FLOOR = { sha: "c9eb9e725c07", date: Date.new(2026, 9, 19) }.freeze

      STAMPED_VERSION = /\A(\d{4}-\d{2}-\d{2})-([0-9a-f]{12})\z/

      PASS = "pass"
      FAIL = "fail"
      UNKNOWN = "unknown"

      Check = Struct.new(:status, :reason, :basis, keyword_init: true)

      NodeRow = Struct.new(
        :instance_id, :instance_name, :node_name, :instance_account_id, :instance_status, :roles,
        :agent_version, :last_heartbeat_at, :agent_check, :account_check, :accounts, :storages,
        keyword_init: true
      ) do
        def status
          SmbRotationPreflight.worst([ agent_check.status, account_check.status ])
        end

        def as_json(*)
          to_h.merge(
            status: status,
            last_heartbeat_at: last_heartbeat_at&.iso8601,
            agent_check: agent_check.to_h,
            account_check: account_check.to_h
          ).as_json
        end
      end

      Report = Struct.new(:generated_at, :verdict, :summary, :nodes, :unresolved_storages, :floors, keyword_init: true) do
        def safe_to_rotate?
          verdict == "safe_to_rotate"
        end

        def as_json(*)
          {
            generated_at: generated_at.iso8601,
            verdict: verdict,
            safe_to_rotate: safe_to_rotate?,
            summary: summary,
            floors: floors,
            nodes: nodes.map(&:as_json),
            unresolved_storages: unresolved_storages
          }.as_json
        end
      end

      def self.call
        new.call
      end

      def self.worst(statuses)
        return FAIL if statuses.include?(FAIL)
        return UNKNOWN if statuses.include?(UNKNOWN)

        PASS
      end

      def call
        storages = ::FileManagement::Storage.where(provider_type: "smb").includes(:account).order(:created_at, :id).to_a
        by_backend_id = storages.group_by { |storage| backend_instance_id(storage) }
        instances = ::System::NodeInstance.where(id: by_backend_id.keys.compact).includes(:node).index_by(&:id)

        nodes = []
        unresolved = []
        by_backend_id.each do |backend_id, served|
          instance = backend_id && instances[backend_id]
          if instance
            nodes << node_row(instance, served)
          else
            unresolved.concat(served.map { |storage| unresolved_row(storage, backend_id) })
          end
        end

        Report.new(
          generated_at: Time.current,
          verdict: verdict(storages, nodes, unresolved),
          summary: summary(storages, nodes, unresolved),
          nodes: nodes,
          unresolved_storages: unresolved,
          floors: floors
        )
      end

      private

      # Same rule as SmbUserManager#backend_node_instance_id, so the preflight
      # checks the instance a rotation would actually dispatch to.
      def backend_instance_id(storage)
        key = storage.gateway_proxy? ? "gateway_node_instance_id" : "export_host_node_instance_id"
        storage.configuration[key].presence&.to_s
      end

      def node_row(instance, storages)
        NodeRow.new(
          instance_id: instance.id,
          instance_name: instance.name,
          node_name: instance.node.name,
          instance_account_id: instance.account_id,
          instance_status: instance.status,
          roles: storages.map { |storage| storage.gateway_proxy? ? "gateway" : "backend" }.uniq.sort,
          agent_version: instance.agent_version,
          last_heartbeat_at: instance.last_heartbeat_at,
          agent_check: agent_check(instance),
          account_check: account_check(instance, storages),
          accounts: storages.map(&:account).uniq.map { |account| { id: account.id, name: account.name } },
          storages: storages.map { |storage| storage_ref(storage) }
        )
      end

      def storage_ref(storage)
        { id: storage.id, name: storage.name, account_id: storage.account_id, deployment_shape: storage.deployment_shape }
      end

      # A dangling id is a fail (SmbUserManager would raise RecordNotFound);
      # an absent one is unknown — the storage may be an external SMB server
      # the platform provisions no users on, which this report cannot tell
      # apart from a misconfigured one.
      def unresolved_row(storage, backend_id)
        status, reason = backend_id ? [ FAIL, "backend_instance_not_found" ] : [ UNKNOWN, "no_backend_instance_configured" ]
        storage_ref(storage).merge(
          account_name: storage.account.name, backend_instance_id: backend_id, status: status, reason: reason
        )
      end

      def agent_check(instance)
        check = version_check(instance.agent_version)
        # A stale heartbeat makes the recorded version history, not state —
        # whichever way it pointed.
        return Check.new(status: UNKNOWN, reason: "stale_heartbeat", basis: check.basis) if instance.stale_heartbeat?

        check
      end

      def version_check(version)
        match = STAMPED_VERSION.match(version.to_s)
        built_on = match && parse_date(match[1])
        return Check.new(status: UNKNOWN, reason: "agent_version_not_orderable", basis: "none") unless built_on

        sha = match[2]
        return Check.new(status: PASS, reason: "is_credential_ref_commit", basis: "exact_commit") if sha == CREDENTIAL_REF_FLOOR[:sha]
        return Check.new(status: FAIL, reason: "predates_credential_ref", basis: "exact_commit") if sha == VALIDATION_FLOOR[:sha]

        date_check(built_on)
      end

      def date_check(built_on)
        basis = "build_date"
        if built_on > Date.current + 1
          Check.new(status: UNKNOWN, reason: "build_date_in_future", basis: basis)
        elsif built_on > CREDENTIAL_REF_FLOOR[:date]
          Check.new(status: PASS, reason: "built_after_credential_ref_commit", basis: basis)
        elsif built_on == CREDENTIAL_REF_FLOOR[:date]
          Check.new(status: UNKNOWN, reason: "built_same_day_as_credential_ref_commit", basis: basis)
        elsif built_on < VALIDATION_FLOOR[:date]
          Check.new(status: FAIL, reason: "predates_payload_validation", basis: basis)
        else
          Check.new(status: FAIL, reason: "predates_credential_ref", basis: basis)
        end
      end

      def parse_date(string)
        Date.iso8601(string)
      rescue Date::Error
        nil
      end

      def account_check(instance, storages)
        account_ids = storages.map(&:account_id).uniq
        if account_ids.size > 1
          Check.new(status: FAIL, reason: "serves_multiple_accounts", basis: "storage_accounts")
        elsif account_ids.first != instance.account_id
          Check.new(status: FAIL, reason: "instance_account_differs_from_storage_account", basis: "storage_accounts")
        else
          Check.new(status: PASS, reason: "serves_one_account", basis: "storage_accounts")
        end
      end

      def verdict(storages, nodes, unresolved)
        return "no_smb_backends" if storages.empty?

        case self.class.worst(nodes.map(&:status) + unresolved.map { |row| row[:status] })
        when FAIL then "not_safe"
        when UNKNOWN then "unknown"
        else "safe_to_rotate"
        end
      end

      def summary(storages, nodes, unresolved)
        counts = nodes.map(&:status).tally
        {
          smb_storages: storages.size,
          nodes: nodes.size,
          pass: counts.fetch(PASS, 0),
          fail: counts.fetch(FAIL, 0),
          unknown: counts.fetch(UNKNOWN, 0),
          unresolved_storages: unresolved.size
        }
      end

      def floors
        {
          credential_ref: CREDENTIAL_REF_FLOOR.merge(date: CREDENTIAL_REF_FLOOR[:date].iso8601),
          payload_validation: VALIDATION_FLOOR.merge(date: VALIDATION_FLOOR[:date].iso8601)
        }
      end
    end
  end
end
