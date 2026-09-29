# frozen_string_literal: true

module System
  # IMP-190834701b0a — ingests the agent's `ssh_host_keys` heartbeat block
  # (agent/internal/runtime/hostkeys.go) into NodeInstance#ssh_host_keys, the
  # trust anchor System::SshExecutionService verifies every SSH/SCP
  # connection against.
  #
  # TRUST. The heartbeat is mTLS-authenticated: only the holder of this
  # instance's client certificate can post it. A CHANGED key is therefore
  # accepted, because a reimaged node legitimately gets new host keys and
  # nothing but its own agent can say so. Accepting it quietly would also hide
  # the other cause, a different host now holding the instance's identity. So
  # every change is audited and raises a fleet event.
  #
  # Keys are ingested only when the certificate identity is bound to THIS
  # instance (mtls_subject blank or equal to the instance id). A legacy
  # shared-hostname CN is resolved by the node API to the newest sibling, so
  # its report could write one instance's key onto another.
  #
  # BOOT CLASSIFICATION. The stored document's `boot_id` is the last boot on
  # which the recorded keys were CONFIRMED: an unchanged report on a new boot
  # refreshes it (one write per reboot, no audit). A change is then classed as
  # across-a-reboot (boot_id differs, MEDIUM event, what a reimage looks like)
  # or in-boot (same boot_id, HIGH event, no routine explanation).
  # boot_id is self-reported by the same principal that reports the key, so
  # this separates ACCIDENTS from each other. It is not evidence against an
  # attacker holding the instance certificate, who can send any boot_id.
  #
  # NARROWING. A report whose keys are a strict subset of the recorded set on
  # the same boot is most likely a transiently unreadable .pub file, so it
  # does not replace the recorded set (debug log only). Narrowing happens
  # only across a boot change.
  #
  # AUDIT. The first recording, every change and every operator clear write
  # an AuditLog row with fingerprints only (previous -> new). No key blob and
  # no private material is ever logged. The read, compare, column write and
  # audit row all run under the instance row lock in one transaction, so a key
  # is never trusted without its audit row and a retried heartbeat cannot
  # double-record. If the audit write fails, this raises. The heartbeat
  # controller rescues it, and the next heartbeat retries.
  #
  # MALFORMED INPUT. Absent, malformed, oversized or injected entries are
  # dropped by System::SshHostKeys.normalize_all. A report with NO valid entry
  # leaves the recorded keys untouched. A broken report never un-trusts a
  # node, and it never makes one trusted.
  class SshHostKeyWriter
    WIRE_KEY = "ssh_host_keys"

    RECORDED_ACTION = "system.ssh_host_key.recorded"
    CHANGED_ACTION  = "system.ssh_host_key.changed"
    CLEARED_ACTION  = "system.ssh_host_key.cleared"
    AUDITED_ACTIONS = [ RECORDED_ACTION, CHANGED_ACTION, CLEARED_ACTION ].freeze

    RECORDED_EVENT_KIND = "system.instance.ssh_host_key_recorded"
    CHANGED_EVENT_KIND  = "system.instance.ssh_host_key_changed"
    CLEARED_EVENT_KIND  = "system.instance.ssh_host_key_cleared"

    class << self
      # Returns :recorded (first key), :changed, :unchanged, or nil when the
      # heartbeat carried no usable key or the identity is not instance-bound.
      def write!(instance:, payload:, boot_id: nil)
        return nil if instance.nil? || payload.nil?

        unless instance_bound?(instance)
          Rails.logger.warn(
            "[SshHostKeyWriter] instance #{instance.id}: mTLS identity is not instance-bound " \
            "(shared legacy subject); SSH host keys not ingested"
          )
          return nil
        end

        entries = normalized_entries(instance, payload)
        return nil if entries.empty?

        outcome = nil
        details = nil
        instance.with_lock do
          outcome, details = apply!(instance, entries, boot_id)
        end

        emit_event(instance, outcome, details) if details
        outcome
      end

      # The operator recovery for a stale recorded key (a reimaged node whose
      # agent cannot heartbeat the new one). Clears the column, audited with
      # the previous fingerprints, the actor and the reason. After this,
      # legacy callers connect unverified while system.ssh.require_host_key is
      # off (refused when on), and out-of-band exec is refused until the
      # node's next heartbeat records a key. `actor` must be the User doing
      # it. See docs/design/ssh-host-key-verification.md.
      def clear!(instance:, actor:, reason:)
        raise ArgumentError, "a reason is required to clear a recorded SSH host key" if reason.to_s.strip.empty?
        # Recovery is a human act: only a User may clear, and the audit row
        # names them.
        raise ArgumentError, "only a User may clear a recorded SSH host key" unless actor.is_a?(::User)

        details = nil
        instance.with_lock do
          previous = ::System::SshHostKeys.recorded_for(instance)
          instance.update_columns(ssh_host_keys: nil)
          details = {
            previous_fingerprints: ::System::SshHostKeys.fingerprints(previous),
            reason: reason.to_s.strip
          }
          ::AuditLog.create!(
            account: instance.account,
            user: actor,
            action: CLEARED_ACTION,
            resource_type: "System::NodeInstance",
            resource_id: instance.id.to_s,
            source: "system",
            metadata: details
          )
        end
        emit(instance, CLEARED_EVENT_KIND, :medium, details)
        true
      end

      private

      def instance_bound?(instance)
        subject = instance.respond_to?(:mtls_subject) ? instance.mtls_subject : nil
        subject.blank? || subject == instance.id.to_s
      end

      def normalized_entries(instance, payload)
        entries = ::System::SshHostKeys.normalize_all(payload)
        reported_count = payload.is_a?(Array) ? payload.size : 1
        if entries.size < reported_count
          Rails.logger.warn(
            "[SshHostKeyWriter] instance #{instance.id}: ignored #{reported_count - entries.size} of " \
            "#{reported_count} reported SSH host key entries (malformed, oversized or duplicate)"
          )
        end
        entries
      end

      # Runs under the row lock (with_lock reloads the row first). Returns
      # [outcome, details]; details is nil when nothing was audited.
      def apply!(instance, entries, boot_id)
        document = instance.ssh_host_keys.is_a?(Hash) ? instance.ssh_host_keys : nil
        previous = ::System::SshHostKeys.recorded_for(instance)
        new_fingerprints = ::System::SshHostKeys.fingerprints(entries)
        old_fingerprints = ::System::SshHostKeys.fingerprints(previous)
        same_boot = document.present? && document["boot_id"] == boot_id

        if previous.any? && new_fingerprints.sort == old_fingerprints.sort
          confirm_boot!(instance, document, boot_id) unless same_boot
          return [ :unchanged, nil ]
        end

        if previous.any? && same_boot && (new_fingerprints - old_fingerprints).empty?
          Rails.logger.debug do
            "[SshHostKeyWriter] instance #{instance.id}: narrowed report within one boot " \
              "(#{new_fingerprints.size} of #{old_fingerprints.size} recorded keys); keeping the recorded set"
          end
          return [ :unchanged, nil ]
        end

        outcome = previous.empty? ? :recorded : :changed
        details = {
          previous_fingerprints: old_fingerprints,
          fingerprints: new_fingerprints,
          key_types: entries.map { |entry| entry["type"] },
          boot_id_changed: outcome == :changed ? !same_boot : nil
        }.compact

        instance.update_columns(ssh_host_keys: {
          "keys" => entries,
          "recorded_at" => Time.current.utc.iso8601,
          "boot_id" => boot_id
        })
        write_audit!(instance, outcome, details)
        [ outcome, details ]
      end

      def confirm_boot!(instance, document, boot_id)
        instance.update_columns(ssh_host_keys: document.merge("boot_id" => boot_id))
      end

      def write_audit!(instance, outcome, details)
        ::AuditLog.create!(
          account: instance.account,
          action: outcome == :recorded ? RECORDED_ACTION : CHANGED_ACTION,
          resource_type: "System::NodeInstance",
          resource_id: instance.id.to_s,
          source: "system",
          metadata: details
        )
      end

      # Recorded: low. Changed across a reboot: medium (a reimage). Changed
      # within one boot: high (no routine explanation).
      def emit_event(instance, outcome, details)
        if outcome == :recorded
          emit(instance, RECORDED_EVENT_KIND, :low, details)
        else
          emit(instance, CHANGED_EVENT_KIND, details[:boot_id_changed] ? :medium : :high, details)
        end
      end

      # Best-effort: the audit row is the durable record. The event is how the
      # change reaches the fleet feed and an operator watching it.
      def emit(instance, kind, severity, details)
        ::System::Fleet::EventBroadcaster.emit!(
          account: instance.account,
          kind: kind,
          severity: severity,
          payload: details.merge(instance_id: instance.id),
          source: "system/ssh_host_key_writer",
          node_instance_id: instance.id
        )
      rescue StandardError => e
        Rails.logger.warn("[SshHostKeyWriter] event emit failed for #{instance.id}: #{e.class}")
      end
    end
  end
end
