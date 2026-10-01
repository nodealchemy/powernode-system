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
    # SCOPE. Every provider_type "smb" storage is scanned, whatever its status
    # and whether or not it holds a credential today: a credential issued
    # between the preflight and the rotation lands on the same backend agent.
    #
    # HOW "AT OR AFTER THE COMMIT" IS DECIDED. The only thing the platform
    # records about an agent build is NodeInstance#agent_version, the string
    # the agent heartbeats. scripts/module-build/stage15.sh stamps it as
    # "<UTC build date>-<12-hex source sha>". A sha is not orderable and the
    # server has no git history to resolve ancestry against, so the build DATE
    # is the comparable:
    #
    #   built before the commit's date  → fail (the commit did not exist yet)
    #   built on the commit's date      → unknown, with no exception
    #   built after the commit's date   → pass, basis "build_date"
    #
    # The whole day is unknown, even for a build of CREDENTIAL_REF_FLOOR itself,
    # because STDIN_FLOOR (8f6aeae2) landed later that same day: a build of the
    # CredentialRef commit resolves the ref and then still passes the new
    # password to samba-tool on argv. Rotating against it would be the exposure
    # the rotation is meant to end, so the day cannot be split by sha.
    #
    # "build_date" proves the binary was built after the commits existed, not
    # that the source tree contained them. It is sound for a build from the
    # default branch and not for a build from a branch cut earlier; the basis is
    # carried on every row, and Report#agent_shas lists the shas seen so an
    # operator can settle one in an extension checkout with
    # `git merge-base --is-ancestor 8f6aeae26de9 <sha>`.
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
      # Delivers the SMB password to samba-tool on stdin instead of argv
      # (IMP-ad2c66a838f2). Same day as CREDENTIAL_REF_FLOOR, a descendant of it.
      STDIN_FLOOR = { sha: "8f6aeae26de9", date: Date.new(2026, 9, 19) }.freeze

      STAMPED_VERSION = /\A(\d{4}-\d{2}-\d{2})-([0-9a-f]{12})\z/

      PASS = "pass"
      FAIL = "fail"
      UNKNOWN = "unknown"

      ANCESTRY_COMMAND = "git merge-base --is-ancestor #{STDIN_FLOOR[:sha]} <sha>"

      # What an operator does about each reason that is not a pass.
      HINTS = {
        "agent_version_not_orderable" =>
          "Redeploy a stamped module build to this instance; an unstamped agent (e.g. \"dev\") cannot be ordered.",
        "stale_heartbeat" =>
          "No heartbeat in the last #{::System::NodeInstance::HEARTBEAT_STALE_AFTER.inspect}, so the recorded " \
          "version may be out of date. Check the agent on this instance, then re-run.",
        "built_same_day_as_credential_ref_commit" =>
          "Built on the day the required commits landed. Settle it in an extension checkout with " \
          "`#{ANCESTRY_COMMAND}` (exit 0 = safe), or redeploy a newer module build.",
        "build_date_in_future" =>
          "The stamped build date is in the future; check the build host's clock and redeploy a module build.",
        "predates_credential_ref" =>
          "Upgrade this instance's agent to a module build made after #{CREDENTIAL_REF_FLOOR[:date].iso8601}; " \
          "this one refuses the rotation payload.",
        "predates_payload_validation" =>
          "Upgrade this instance's agent before anything else: it would run samba-tool with an empty value.",
        "serves_multiple_accounts" =>
          "Move each account's SMB storages to a backend of its own before rotating.",
        "instance_account_differs_from_storage_account" =>
          "The backend belongs to a different account than the storage it serves; correct the storage's backend.",
        "backend_instance_not_found" =>
          "The storage names a backend instance that no longer exists; point it at a live backend or retire it.",
        "no_backend_instance_configured" =>
          "Confirm this is an external SMB server the platform provisions no users on; if it is not, set its backend."
      }.freeze

      Check = Struct.new(:status, :reason, :basis, keyword_init: true) do
        def hint
          HINTS[reason] unless status == PASS
        end

        def as_json(*)
          to_h.merge(hint: hint).as_json
        end
      end

      NodeRow = Struct.new(
        :instance_id, :instance_name, :node_name, :instance_account_id, :instance_status, :roles,
        :agent_version, :agent_sha, :last_heartbeat_at, :agent_check, :account_check, :accounts, :storages,
        keyword_init: true
      ) do
        def status
          SmbRotationPreflight.worst([ agent_check.status, account_check.status ])
        end

        def as_json(*)
          to_h.merge(
            status: status,
            last_heartbeat_at: last_heartbeat_at&.iso8601,
            agent_check: agent_check.as_json,
            account_check: account_check.as_json
          ).as_json
        end
      end

      Report = Struct.new(
        :generated_at, :environment, :database, :verdict, :summary, :nodes, :unresolved_storages, :agent_shas, :floors,
        keyword_init: true
      ) do
        def safe_to_rotate?
          verdict == "safe_to_rotate"
        end

        def as_json(*)
          {
            generated_at: generated_at.iso8601,
            environment: environment,
            database: database,
            verdict: verdict,
            safe_to_rotate: safe_to_rotate?,
            summary: summary,
            floors: floors,
            agent_shas: agent_shas,
            ancestry_command: ANCESTRY_COMMAND,
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
          environment: Rails.env.to_s,
          database: ::ActiveRecord::Base.connection_db_config.database,
          verdict: verdict(storages, nodes, unresolved),
          summary: summary(storages, nodes, unresolved),
          nodes: nodes,
          unresolved_storages: unresolved,
          agent_shas: nodes.filter_map(&:agent_sha).uniq.sort,
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
          agent_sha: STAMPED_VERSION.match(instance.agent_version.to_s)&.[](2),
          last_heartbeat_at: instance.last_heartbeat_at,
          agent_check: agent_check(instance),
          account_check: account_check(instance, storages),
          accounts: storages.map(&:account).uniq.map { |account| { id: account.id, name: account.name } },
          storages: storages.map { |storage| storage_ref(storage) }
        )
      end

      def storage_ref(storage)
        {
          id: storage.id, name: storage.name, account_id: storage.account_id,
          status: storage.status, deployment_shape: storage.deployment_shape
        }
      end

      # A dangling id is a fail (SmbUserManager would raise RecordNotFound);
      # an absent one is unknown — the storage may be an external SMB server
      # the platform provisions no users on, which this report cannot tell
      # apart from a misconfigured one.
      def unresolved_row(storage, backend_id)
        status, reason = backend_id ? [ FAIL, "backend_instance_not_found" ] : [ UNKNOWN, "no_backend_instance_configured" ]
        storage_ref(storage).merge(
          account_name: storage.account.name, backend_instance_id: backend_id,
          check: status, reason: reason, hint: HINTS[reason]
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

        # The one sha known NOT to carry the change, whenever it was built. There
        # is deliberately no exact-sha pass: see the class comment on STDIN_FLOOR.
        return Check.new(status: FAIL, reason: "predates_credential_ref", basis: "exact_commit") if match[2] == VALIDATION_FLOOR[:sha]

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

        case self.class.worst(nodes.map(&:status) + unresolved.map { |row| row[:check] })
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
          nodes_pass: counts.fetch(PASS, 0),
          nodes_fail: counts.fetch(FAIL, 0),
          nodes_unknown: counts.fetch(UNKNOWN, 0),
          unresolved_storages: unresolved.size
        }
      end

      def floors
        {
          credential_ref: CREDENTIAL_REF_FLOOR.merge(date: CREDENTIAL_REF_FLOOR[:date].iso8601),
          stdin_delivery: STDIN_FLOOR.merge(date: STDIN_FLOOR[:date].iso8601),
          payload_validation: VALIDATION_FLOOR.merge(date: VALIDATION_FLOOR[:date].iso8601)
        }
      end
    end
  end
end
