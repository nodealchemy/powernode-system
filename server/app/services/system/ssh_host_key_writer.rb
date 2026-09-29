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
  # every change is audited and raises a HIGH-severity fleet event.
  # `boot_id_changed` is recorded beside it. A key that changes across a
  # reboot looks like a reimage. A key that changes WITHOUT a reboot is the
  # shape worth an operator's attention.
  #
  # AUDIT. The first recording and every change write an AuditLog row with
  # fingerprints only (previous -> new). No key blob and no private material
  # is ever logged. The audit row and the column write share a transaction, so
  # a key is never trusted without its audit row. If the audit write fails,
  # this raises. The heartbeat controller rescues it, and the next heartbeat
  # retries.
  #
  # MALFORMED INPUT. Absent, malformed, oversized or injected entries are
  # dropped by System::SshHostKeys.normalize_all. A report with NO valid entry
  # leaves the recorded keys untouched. A broken report never un-trusts a
  # node, and it never makes one trusted.
  class SshHostKeyWriter
    WIRE_KEY = "ssh_host_keys"

    RECORDED_ACTION = "system.ssh_host_key.recorded"
    CHANGED_ACTION  = "system.ssh_host_key.changed"
    AUDITED_ACTIONS = [ RECORDED_ACTION, CHANGED_ACTION ].freeze

    RECORDED_EVENT_KIND = "system.instance.ssh_host_key_recorded"
    CHANGED_EVENT_KIND  = "system.instance.ssh_host_key_changed"

    class << self
      # Returns :recorded (first key), :changed, :unchanged, or nil when the
      # heartbeat carried no usable key.
      def write!(instance:, payload:, boot_id: nil)
        return nil if instance.nil? || payload.nil?

        entries = ::System::SshHostKeys.normalize_all(payload)
        reported_count = payload.is_a?(Array) ? payload.size : 1
        if entries.size < reported_count
          Rails.logger.warn(
            "[SshHostKeyWriter] instance #{instance.id}: ignored #{reported_count - entries.size} of " \
            "#{reported_count} reported SSH host key entries (malformed, oversized or duplicate)"
          )
        end
        return nil if entries.empty?

        previous_document = instance.ssh_host_keys.is_a?(Hash) ? instance.ssh_host_keys : nil
        previous = ::System::SshHostKeys.recorded_for(instance)
        new_fingerprints = ::System::SshHostKeys.fingerprints(entries)
        old_fingerprints = ::System::SshHostKeys.fingerprints(previous)
        return :unchanged if previous.any? && new_fingerprints.sort == old_fingerprints.sort

        outcome = previous.empty? ? :recorded : :changed
        boot_id_changed = previous_document.present? && previous_document["boot_id"] != boot_id
        details = {
          previous_fingerprints: old_fingerprints,
          fingerprints: new_fingerprints,
          key_types: entries.map { |entry| entry["type"] },
          boot_id_changed: outcome == :changed ? boot_id_changed : nil
        }.compact

        instance.class.transaction do
          instance.update_columns(ssh_host_keys: {
            "keys" => entries,
            "recorded_at" => Time.current.utc.iso8601,
            "boot_id" => boot_id
          })
          write_audit!(instance, outcome, details)
        end

        emit_event(instance, outcome, details)
        outcome
      end

      private

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

      # Best-effort: the audit row is the durable record. The event is how the
      # change reaches the fleet feed and an operator watching it.
      def emit_event(instance, outcome, details)
        ::System::Fleet::EventBroadcaster.emit!(
          account: instance.account,
          kind: outcome == :recorded ? RECORDED_EVENT_KIND : CHANGED_EVENT_KIND,
          severity: outcome == :recorded ? :low : :high,
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
