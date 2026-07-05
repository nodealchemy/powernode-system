# frozen_string_literal: true

module System
  module Executors
    module Runtime
      class UpgradeK3sRuntime < ::System::Executors::Base
        # Raised until a real rolling-upgrade backend exists. See the
        # class-level note below — no orchestration is wired up yet.
        class NotYetImplementedError < StandardError; end

        protected

        def perform
          # `cluster.try(:version)` always returned nil — Devops::
          # KubernetesCluster has no `version` column; the persisted field
          # is `k8s_version`. Column bug aside, this executor never
          # actually triggered an upgrade: full rolling-upgrade
          # orchestration (drain each node, bump k8s_version, re-run the
          # k3s installer) lives in a dedicated service that doesn't exist
          # yet. Refuse to claim success on a no-op — a false "upgraded"
          # stamp here is exactly what the require_approval gate exists to
          # prevent.
          cluster = ::Devops::KubernetesCluster.find(params[:cluster_id])
          target = params[:target_version]
          raise NotYetImplementedError,
                "K3s runtime upgrade orchestration is not implemented for cluster " \
                "#{cluster.id} (current #{cluster.k8s_version.inspect} -> target #{target.inspect})"
        end

        def summarize = "Upgrade K3s runtime to #{params[:target_version]}"
        def impact    = "Not implemented — raises rather than faking a completed upgrade"
      end
    end
  end
end
