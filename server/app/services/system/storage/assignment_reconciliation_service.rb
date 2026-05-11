# frozen_string_literal: true

module System
  module Storage
    # Drives StorageAssignment toward its target state.
    #
    # Triggers (each one calls reconcile_assignment!):
    #   * StorageAssignment after_commit on create or status-affecting update
    #   * Agent heartbeat reports a missing mount (heartbeat handler dispatches)
    #   * Periodic StorageAssignmentDriftSensor sweep
    #
    # Steps per assignment:
    #   1. Bail if not enabled (any mounted assignment that's now disabled
    #      gets an unmount task instead).
    #   2. Honor exponential backoff stored in error_message metadata.
    #   3. Ensure Sdwan::Peer exists (auto-enroll via Sdwan::PeerEnroller).
    #   4. Ensure StorageCredential exists + not expired (issue via
    #      CredentialIssuer, which also writes exports.d / samba user on
    #      the backend peer).
    #   5. Dispatch storage.mount task to the client node.
    class AssignmentReconciliationService
      BACKOFF_BASE = 30 # seconds
      BACKOFF_MAX = 30.minutes

      def self.reconcile_instance!(instance)
        ::System::StorageAssignment
          .pending_reconcile
          .where(node_instance_id: instance.id)
          .find_each { |a| reconcile_assignment!(a) }
      end

      def self.reconcile_assignment!(assignment)
        new(assignment: assignment).reconcile!
      end

      def initialize(assignment:)
        @assignment = assignment
      end

      def reconcile!
        if !@assignment.enabled? && @assignment.status == "mounted"
          dispatch_unmount!
          return
        end

        return unless @assignment.enabled?
        return if in_backoff?

        @assignment.mark_status!("provisioning")

        ensure_peer!
        credential = ensure_credential!
        encryption_key = ensure_encryption_key! if @assignment.effective_encryption_mode != "none"

        dispatch_mount!(credential: credential, encryption_key: encryption_key)
      rescue StandardError => e
        record_failure!(e)
      end

      private

      def in_backoff?
        until_time = @assignment.error_message.to_s.match(/backoff_until:(\S+)/)&.[](1)
        return false unless until_time

        Time.parse(until_time) > Time.current
      rescue StandardError
        false
      end

      def ensure_peer!
        return unless @assignment.sdwan_network_id

        peer = ::Sdwan::Peer.find_by(
          node_instance_id: @assignment.node_instance_id,
          sdwan_network_id: @assignment.sdwan_network_id
        )
        return peer if peer

        ::Sdwan::PeerEnroller.call(
          network: @assignment.sdwan_network,
          node_instance: @assignment.node_instance
        )
      end

      def ensure_credential!
        active = @assignment.active_credential
        return active if active && !active.expired? && !active.needs_rotation?

        if active
          CredentialIssuer.new(assignment: @assignment).rotate!(active)
        else
          CredentialIssuer.new(assignment: @assignment).issue!
        end
      end

      def ensure_encryption_key!
        existing = @assignment.mount_encryption_keys.active.first
        return existing if existing

        algorithm = algorithm_for_mode(@assignment.effective_encryption_mode)
        key = ::System::MountEncryptionKey.create!(
          storage_assignment: @assignment,
          node_instance_id: nil, # mount-wide; per-instance LUKS slots are v2 stretch
          algorithm: algorithm,
          escrowed: true
        )
        key.store_in_vault(material: SecureRandom.hex(32))
        ::System::MountEncryptionKey.find(key.id)
      end

      def algorithm_for_mode(mode)
        case mode
        when "fscrypt" then "fscrypt-v2"
        when "luks" then "aes-xts-plain64"
        when "client_side_aes" then "aes-256-gcm"
        else "fscrypt-v2"
        end
      end

      def dispatch_mount!(credential:, encryption_key:)
        payload = TaskPayloadBuilder.build_mount_payload(
          assignment: @assignment, credential: credential, encryption_key: encryption_key
        )

        ::System::Task.create!(
          account: @assignment.account,
          operable: @assignment.node_instance,
          command: "storage.mount",
          options: payload,
          status: "pending"
        )
      end

      def dispatch_unmount!
        payload = TaskPayloadBuilder.build_unmount_payload(assignment: @assignment)

        ::System::Task.create!(
          account: @assignment.account,
          operable: @assignment.node_instance,
          command: "storage.unmount",
          options: payload,
          status: "pending"
        )
        @assignment.mark_status!("unmounting")
      end

      def record_failure!(error)
        attempt = (@assignment.error_message.to_s.match(/attempt:(\d+)/)&.[](1).to_i) + 1
        delay = [BACKOFF_BASE * (2**(attempt - 1)), BACKOFF_MAX.to_i].min
        backoff_until = (Time.current + delay).iso8601

        @assignment.mark_status!(
          "failed",
          error_message: "attempt:#{attempt} backoff_until:#{backoff_until} #{error.class}: #{error.message}"
        )
        Rails.logger.error("[StorageAssignment##{@assignment.id}] reconcile failed: #{error.class}: #{error.message}")
      end
    end
  end
end
