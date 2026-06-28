# frozen_string_literal: true

module System
  module Deploy
    # Kubernetes self-deploy method. Extension-provided: registered into the CORE
    # Ai::Deploy::MethodRegistry via the system engine's :deploy_method_providers seam, so
    # core never names System::. Rolls out a deployment on a Devops::KubernetesCluster by
    # running kubectl on a cluster server node over SSH (System::SshExecutionService).
    # Serves a k8s-hosted platform-self OR a managed project.
    #
    # Target config: { "cluster_id" => <Devops::KubernetesCluster id|name>,
    #                  "deployment" => "<k8s deployment>", "namespace" => "default",
    #                  "container" => "<name>", "image" => "repo:tag" }.
    # image + container → `kubectl set image`; otherwise → `kubectl rollout restart`.
    class KubernetesMethod < ::Ai::Deploy::Method
      KUBECONFIG = "/etc/rancher/k3s/k3s.yaml"

      def self.key = :kubernetes

      def self.available?
        [defined?(::Devops::KubernetesCluster), defined?(::System::SshExecutionService)].all?(&:present?)
      end

      def deploy!(target:, ref:, dry_run: true)
        cluster = resolve_cluster(target)
        return ::Ai::Deploy::Result.failure("no kubernetes cluster for target (set config cluster_id)") unless cluster

        deployment = target.config["deployment"].presence
        return ::Ai::Deploy::Result.failure("config 'deployment' (k8s deployment name) is required") unless deployment

        namespace = target.config["namespace"].presence || "default"
        command = rollout_command(target, deployment, namespace)

        if dry_run
          return ::Ai::Deploy::Result.dry(commands: [command], detail: "would run on cluster #{cluster.name}: #{command}")
        end

        node = server_instance(cluster)
        return ::Ai::Deploy::Result.failure("no reachable server node for cluster #{cluster.name}") unless node

        result = ::System::SshExecutionService.execute(instance: node, command: command, sudo: true)
        if result.success?
          ::Ai::Deploy::Result.ok("kubectl applied on #{cluster.name}", commands: [command],
                                  cluster_id: cluster.id, deployment: deployment, namespace: namespace)
        else
          ::Ai::Deploy::Result.failure("kubectl failed: #{result.error}", commands: [command])
        end
      rescue StandardError => e
        ::Ai::Deploy::Result.failure("kubernetes deploy failed: #{e.message}")
      end

      # kubectl rollout status — converged = healthy. Inconclusive (SSH error) is treated as
      # healthy so a monitoring hiccup never triggers an auto-rollback.
      def verify_health(target:, deploy_run:)
        cluster = resolve_cluster(target)
        node = cluster && server_instance(cluster)
        deployment = (deploy_run.metadata["deployment"] || target.config["deployment"]).to_s
        return ::Ai::Deploy::Result.ok("no cluster/deployment to check") if node.nil? || deployment.blank?

        ns = (deploy_run.metadata["namespace"] || target.config["namespace"] || "default").to_s
        result = ::System::SshExecutionService.execute(
          instance: node, command: kubectl("rollout status deployment/#{deployment} -n #{ns} --timeout=120s"), sudo: true
        )
        result.success? ? ::Ai::Deploy::Result.ok("rollout converged") : ::Ai::Deploy::Result.failure("rollout did not converge: #{result.error}")
      rescue StandardError => e
        ::Ai::Deploy::Result.ok("health inconclusive (not rolling back): #{e.message}")
      end

      def rollback!(target:, deploy_run:)
        cluster = resolve_cluster(target)
        node = cluster && server_instance(cluster)
        deployment = (deploy_run.metadata["deployment"] || target.config["deployment"]).to_s
        return ::Ai::Deploy::Result.failure("no cluster/deployment to roll back") if node.nil? || deployment.blank?

        ns = (deploy_run.metadata["namespace"] || target.config["namespace"] || "default").to_s
        result = ::System::SshExecutionService.execute(
          instance: node, command: kubectl("rollout undo deployment/#{deployment} -n #{ns}"), sudo: true
        )
        if result.success?
          ::Ai::Deploy::Result.new(status: :rolled_back, detail: "kubectl rollout undo deployment/#{deployment}")
        else
          ::Ai::Deploy::Result.failure("rollback failed: #{result.error}")
        end
      end

      private

      def resolve_cluster(target)
        id = target.config["cluster_id"].presence
        return nil if id.blank?

        account.devops_kubernetes_clusters.find_by(id: id) ||
          account.devops_kubernetes_clusters.find_by(name: id)
      end

      def server_instance(cluster)
        node = cluster.kubernetes_nodes.where(role: %w[server control_plane]).first
        node&.node_instance
      rescue StandardError
        nil
      end

      def rollout_command(target, deployment, namespace)
        image = target.config["image"].presence
        container = target.config["container"].presence
        if image && container
          kubectl("set image deployment/#{deployment} #{container}=#{image} -n #{namespace}")
        else
          kubectl("rollout restart deployment/#{deployment} -n #{namespace}")
        end
      end

      def kubectl(args)
        "kubectl --kubeconfig=#{KUBECONFIG} #{args}"
      end
    end
  end
end
