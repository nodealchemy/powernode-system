# frozen_string_literal: true

module System
  # The ONE issuer of platform-injected enrolment keys (design D12, operator
  # 2026-10-20): when the platform itself provisions a VM it mints a single-use
  # BootstrapToken, bound to the NodeInstance, valid for 1 hour, and injects it
  # with no human step. Every mint goes through BootstrapToken.issue!, which
  # writes exactly one audit row inside the mint transaction and fails closed.
  #
  #   .issue_token      -> [BootstrapToken, plaintext]   (legacy-format channels)
  #   .render_user_data -> Result                        (provisioning document v1)
  #
  # The key is RE-MINTED on every VM start (each call mints a fresh one); the
  # previous key was consumed by the previous boot's enrolment or has expired.
  #
  # Fail-closed: a document is rendered inside the same transaction as the mint,
  # so a missing/invalid CA (System::ProvisioningDocument::RenderError) rolls the
  # token and its audit row back and raises SeedError. A pin-less document is
  # never produced. The plaintext key is never logged and never put in an error
  # message; callers own the returned string.
  class EnrollmentSeed
    TTL = 1.hour
    CLOUD_PURPOSE = "cloud_seed"
    JSON_PART_TYPE = "application/x-powernode-provision+json"
    BOUNDARY_PREFIX = "powernode-seed"

    # Raw (pre-base64) user-data byte limits per provider. AWS: 16 KB raw. OpenStack
    # (Nova): 65535 base64 chars => ~49151 raw. Azure userData: 64 KB base64 =>
    # ~49151 raw. GCP: 256 KB per metadata value. Others are unlimited here.
    SIZE_LIMITS = { "aws" => 16_384, "openstack" => 49_149, "azure" => 49_151, "gcp" => 262_144 }.freeze

    # Written instead of a seed when an ALREADY-ENROLLED instance starts: no key,
    # nothing secret. cloud-init treats it as a no-op config; the agent finds no
    # identity in it.
    NEUTRAL_USER_DATA = "#cloud-config\n# powernode: platform seed cleared (instance is enrolled)\n"

    # An init-script prefix => the MIME type of its part. Anything else is refused.
    SCRIPT_TYPES = [
      [ "#cloud-config",    "text/cloud-config" ],
      [ "#!",               "text/x-shellscript" ],
      [ "#include-once",    "text/x-include-once-url" ],
      [ "#include",         "text/x-include-url" ],
      [ "#cloud-boothook",  "text/cloud-boothook" ],
      [ "#part-handler",    "text/part-handler" ],
      [ "#upstart-job",     "text/upstart-job" ]
    ].freeze
    OPERATOR_MULTIPART_RE = %r{\A(?:MIME-Version:|Content-Type:\s*multipart/)}i

    Result = Struct.new(:user_data, :bootstrap_token_id, :expires_at, keyword_init: true)

    class SeedError < StandardError; end
    # More than one live row matches a cloud id: never guess between them.
    class AmbiguousInstanceError < SeedError; end
    # A lock deadlock/timeout while minting: nothing was written, retry the start.
    class BusyError < SeedError; end

    # Purposes of keys the PLATFORM injects into a VM. An instance that never had
    # one of these was not platform-seeded (imported, enrolled another way): its
    # user-data/metadata is not ours to rewrite or clear.
    SEED_PURPOSES = %w[cloud_seed proxmox_uefi_provision local_qemu_provision].freeze

    class << self
      # Single mint path for every channel (v1 JSON, fw-cfg, cicustom). Under the
      # instance row lock (serialises concurrent starts) it first revokes every
      # prior ACTIVE token of the same purpose for the instance (each revoke is an
      # audited row in this transaction), so at most one seed key is live.
      def issue_token(instance:, purpose: CLOUD_PURPOSE)
        ::System::BootstrapToken.transaction do
          instance.with_lock do
            ::System::BootstrapToken.active
                                    .where(node_instance_id: instance.id, purpose: purpose)
                                    .find_each do |prior|
              prior.revoke!
            rescue ::System::BootstrapToken::InvalidConsumption
              next # consumed between the read and the lock: nothing left to revoke
            end
            ::System::BootstrapToken.issue!(
              node: instance.node,
              node_instance: instance,
              intended_subject: instance.id,
              ttl: TTL,
              purpose: purpose
            )
          end
        end
      rescue ::ActiveRecord::Deadlocked, ::ActiveRecord::LockWaitTimeout
        raise BusyError, "enrollment seed busy (concurrent enrolment/start); retry"
      end

      # Has the platform ever injected a key into this instance?
      def ever_seeded?(instance)
        ::System::BootstrapToken.where(node_instance_id: instance.id, purpose: SEED_PURPOSES).exists?
      end

      # An enrolled instance (agent holds an mTLS identity) never gets a new key.
      def enrolled?(instance)
        instance.mtls_subject.present? || instance.node_certificates.active.exists?
      end

      # The NodeInstance behind a provider cloud id, scoped to the provider
      # connection's account AND provider, excluding terminated rows. nil when none
      # matches; SeedError when more than one does (never guess between tenants).
      def resolve_instance(connection:, cloud_id:)
        return nil if cloud_id.blank? || connection.nil?
        return nil if connection.account_id.blank? || connection.provider_id.blank?

        rows = ::System::NodeInstance
               .where(account_id: connection.account_id)
               .joins(:provider_region)
               .where(system_provider_regions: { provider_id: connection.provider_id })
               .where.not(status: "terminated")
               .where("system_node_instances.config->>'cloud_instance_id' = ?", cloud_id.to_s)
               .limit(2).to_a
        raise AmbiguousInstanceError, "ambiguous cloud id #{cloud_id.inspect}: #{rows.size}+ live instances match; refusing to seed" if rows.size > 1

        rows.first
      end

      # @param instance [System::NodeInstance]
      # @param extra [String, nil] operator/template init script. When present the
      #   result is a MIME multipart: part 1 is the v1 document (head), part 2 the
      #   script as text/cloud-config or text/x-shellscript. Without it the result
      #   is the bare v1 JSON (what the agent reads from cloud user-data).
      # @param server [String, nil] https platform URL override (default: configured)
      # @return [Result]
      def render_user_data(instance:, purpose: CLOUD_PURPOSE, extra: nil, server: nil, ca_pem: nil,
                           provider_type: nil, unless_enrolled: false)
        result = nil
        ::System::BootstrapToken.transaction do
          instance.with_lock do
            # Re-checked UNDER the lock (with_lock reloads the row): an instance
            # that enrolled since the caller looked gets no key. Returns nil.
            next if unless_enrolled && enrolled?(instance)

            token, plaintext = issue_token(instance: instance, purpose: purpose)
            document = ::System::ProvisioningDocument.render(
              instance: instance, key: plaintext, purpose: purpose,
              expires_at: token.expires_at, server: server, ca_pem: ca_pem
            )
            user_data = compose(document, extra)
            check_size!(user_data, provider_type)
            result = Result.new(
              user_data: user_data,
              bootstrap_token_id: token.id,
              expires_at: token.expires_at
            )
          end
        end
        result
      rescue ::System::ProvisioningDocument::RenderError => e
        # RenderError messages never carry the key (see ProvisioningDocument).
        raise SeedError, "refusing to seed instance #{instance.id}: #{e.message}"
      rescue ::ActiveRecord::Deadlocked, ::ActiveRecord::LockWaitTimeout
        raise BusyError, "enrollment seed busy (concurrent enrolment/start); retry"
      end

      # The template's stored init_script (NodeTemplate#config), carried as the
      # second MIME part. nil when the node has no template or no script.
      def template_init_script(node)
        cfg = node&.node_template&.config
        return nil unless cfg.is_a?(Hash)

        script = cfg["init_script"] || cfg[:init_script]
        script.is_a?(String) && script.present? ? script : nil
      end

      # v1 document as the head, extra script as a second MIME part. cloud-init
      # ignores the unknown JSON part type and runs the script part; the agent
      # selects the JSON part (agent/internal/identity/cloud.go).
      def compose(document, extra)
        return document if extra.to_s.strip.empty?

        boundary = "#{BOUNDARY_PREFIX}-#{SecureRandom.hex(12)}"
        script = extra.to_s.chomp
        raise SeedError, "init script must not contain the MIME boundary" if script.include?(boundary)

        # An operator's own multipart carries its headers; it nests as a part.
        script_head =
          if script.lstrip.match?(OPERATOR_MULTIPART_RE)
            [ script.lstrip ]
          else
            [ "Content-Type: #{part_type_for(script)}; charset=\"utf-8\"",
              "Content-Disposition: attachment; filename=\"user-script\"",
              "",
              script ]
          end
        [
          "MIME-Version: 1.0",
          "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
          "",
          "--#{boundary}",
          "Content-Type: #{JSON_PART_TYPE}; charset=\"utf-8\"",
          "Content-Disposition: attachment; filename=\"powernode-provision.json\"",
          "",
          document,
          "--#{boundary}",
          *script_head,
          "--#{boundary}--",
          ""
        ].join("\n")
      end

      def part_type_for(script)
        head = script.to_s.lstrip
        match = SCRIPT_TYPES.find { |prefix, _| head.start_with?(prefix) }
        return match.last if match

        raise SeedError,
              "unsupported init script type (first line #{head.lines.first.to_s.strip[0, 40].inspect}); " \
              "start it with #cloud-config, #!, #include, #cloud-boothook, #part-handler or #upstart-job, " \
              "or supply a complete MIME multipart"
      end

      def check_size!(user_data, provider_type)
        limit = SIZE_LIMITS[provider_type.to_s]
        return if limit.nil? || user_data.bytesize <= limit

        raise SeedError,
              "user-data is #{user_data.bytesize} bytes, over the #{provider_type} limit of #{limit}; " \
              "shorten the init script or the CA chain"
      end
    end
  end
end
