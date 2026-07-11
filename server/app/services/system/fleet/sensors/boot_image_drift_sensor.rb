# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects running instances whose reported booted disk-image git_sha
      # (NodeInstance#booted_image_git_sha, from the agent heartbeat) differs
      # from the git_sha of the image currently promoted for their platform
      # (NodePlatform#disk_image_git_sha). A drifted node is running a stale
      # boot image — the smooth-upgrade path (campaign 019f505f) exists to
      # converge it. Mirrors ModuleDriftSensor: pure read-side, one signal per
      # drifted instance, deduped by fingerprint.
      #
      # Increment 1 is visibility-only — the "system.boot_image_drift" signal is
      # bound observation-only in DecisionEngine (action_category
      # "system.observation": no remediation and no operator notification;
      # surfaced via the signal stream, NodeInstanceSerializer, and the
      # system_drift_report MCP action). Increment 4 swaps that binding to the
      # drift-driven rollout executor.
      class BootImageDriftSensor < BaseSensor
        def sense
          ::System::NodeInstance
            .joins(:node)
            .includes(node: { node_template: :node_platform })
            .where(system_nodes: { account_id: account.id })
            .where(status: "running")
            .where.not(booted_image_git_sha: [ nil, "" ])
            .find_each.filter_map do |inst|
            promoted = inst.promoted_image_git_sha
            next if promoted.blank?
            next if inst.booted_image_git_sha == promoted

            signal(
              kind: "system.boot_image_drift",
              severity: :medium,
              payload: {
                instance_id: inst.id,
                # platform_id rides the signal payload so it lands TOP-LEVEL in
                # the decision metadata — the rollout dedup (inc 4) collapses a
                # fleet-wide drift to ONE approval per platform, and key_value
                # only reads top-level keys (the executor's nested skill_plan
                # data would be invisible to it).
                platform_id: inst.node&.node_platform&.id,
                booted_git_sha: inst.booted_image_git_sha,
                promoted_git_sha: promoted
              },
              # Dedup per instance (mirrors ModuleDriftSensor). The promoted sha is
              # deliberately NOT in the fingerprint: including it would make a
              # promotion bump during a settle window read as a "cleared"
              # fingerprint and distort the RemediationValidator ground truth in
              # later increments. The payload already carries the current pair.
              fingerprint: "boot_image_drift:#{inst.id}"
            )
          end
        end
      end
    end
  end
end
