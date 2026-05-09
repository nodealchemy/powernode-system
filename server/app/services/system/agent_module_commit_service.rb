# frozen_string_literal: true

module System
  # Persists an agent-side module commit as a new NodeModuleVersion.
  # Receives the tar.zst body + sha256 + changelog from the agent's
  # commit CLI (Phase 4 of the agent stub implementation plan), runs
  # defense-in-depth sha256 verification, creates the version row at
  # promotion_state: "built", and emits a fleet event.
  #
  # The platform's existing ModulePromotionService handles promotion
  # through canary → staging → blessed → live; agent commits land at
  # "built" and require explicit operator/agent promotion to expose
  # to live deployments.
  class AgentModuleCommitService
    Result = Struct.new(:ok?, :error, :version, keyword_init: true)

    def self.call(node_module:, tar_b64:, changelog:, sha256:, size_bytes:, committer_instance:)
      new.call(
        node_module: node_module,
        tar_b64: tar_b64,
        changelog: changelog,
        sha256: sha256,
        size_bytes: size_bytes,
        committer_instance: committer_instance
      )
    end

    def call(node_module:, tar_b64:, changelog:, sha256:, size_bytes:, committer_instance:)
      return failure("module is locked") if node_module.try(:lock_spec).present?
      return failure("tar_b64 required") if tar_b64.blank?
      return failure("sha256 required") if sha256.blank?

      tar_bytes = decode_b64(tar_b64)
      return failure("tar_b64 decode failed") unless tar_bytes

      computed = Digest::SHA256.hexdigest(tar_bytes)
      unless computed.casecmp?(sha256.delete_prefix("sha256:"))
        return failure("sha256 mismatch (got #{computed}, expected #{sha256})")
      end

      if size_bytes.to_i.positive? && tar_bytes.bytesize != size_bytes.to_i
        return failure("size mismatch (got #{tar_bytes.bytesize}, expected #{size_bytes})")
      end

      version = ::System::NodeModuleVersion.create!(
        node_module: node_module,
        promotion_state: "built",
        changelog: changelog.presence || "agent-committed at #{Time.current.iso8601}",
        data_file_name: build_data_file_name(node_module, computed),
        data_file_size: tar_bytes.bytesize,
        data_checksum: computed
      )

      ::System::Fleet::EventBroadcaster.emit!(
        account: node_module.account,
        kind: "module.version.committed",
        severity: "medium",
        payload: {
          module_id: node_module.id,
          version_id: version.id,
          version_number: version.version_number,
          changelog: version.changelog,
          sha256: computed,
          size_bytes: tar_bytes.bytesize,
          committer_instance_id: committer_instance&.id
        },
        source: "agent",
        node_instance_id: committer_instance&.id,
        node_module_id: node_module.id,
        node_module_version_id: version.id
      )

      Result.new(ok?: true, version: version)
    rescue ::ActiveRecord::RecordInvalid => e
      failure("version persistence failed: #{e.record.errors.full_messages.join('; ')}")
    end

    private

    def decode_b64(s)
      Base64.strict_decode64(s.to_s.tr("\n\r", ""))
    rescue ArgumentError
      nil
    end

    def build_data_file_name(node_module, sha256)
      base = node_module.name.to_s.downcase.gsub(/[^a-z0-9_-]/, "-")
      "#{base}-#{sha256[0, 12]}.tar.zst"
    end

    def failure(msg)
      Result.new(ok?: false, error: msg)
    end
  end
end
