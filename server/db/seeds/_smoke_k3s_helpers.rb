# frozen_string_literal: true

# Shared helpers for the K3s full-lifecycle smoke seeds.
#
# Each smoke_test_k3s_<phase>.rb loads this module once + calls helpers
# via the module function surface. The helpers exist to:
#
#   1. Replace the per-seed step/ok/assert/fail_with lambdas with module
#      methods, so phase seeds stay terse + consistent.
#   2. Centralize the env preflight (KVM, libvirtd, initramfs artifacts,
#      writable fw-cfg dir) so seeds can't accidentally run without it.
#   3. Encode the SMOKE_K3S_LEVEL tier gate (db | single | site | full)
#      so phases that need a real VM can skip cleanly at db tier rather
#      than mis-running.
#   4. Provide state-sidecar IO (/tmp/smoke-k3s-state.json) so phases pass
#      cluster_id/network_id/instance_id forward additively, and operators
#      can resume from the middle of the sequence.
#   5. Switch the bootstrap contract per tier: db = operator-driven
#      (call provisioner directly); single+ = agent-driven (boot VM,
#      poll cluster status).
#
# Usage:
#
#   require_relative "_smoke_k3s_helpers"
#   h = System::Seeds::SmokeK3sHelpers
#   h.preflight!(level: h.current_tier)
#   account = h.discover_or_create_account!
#   ...
#
# All helpers are strict — they fail loudly on missing prerequisites
# rather than silently degrading. Exception: federation-child detection
# warns but does not raise (operators may legitimately smoke a federated
# child account; the warning gives them a chance to abort).
require "json"
require "open3"
require "fileutils"

module System
  module Seeds
    module SmokeK3sHelpers
      module_function

      TIERS = %w[db single site full].freeze
      TIER_INDEX = TIERS.each_with_index.to_h.freeze
      STATE_PATH = "/tmp/smoke-k3s-state.json"
      INITRAMFS_KERNEL = File.expand_path("../../../initramfs/build/amd64/kernel-initrd/kernel", __dir__)
      INITRAMFS_CPIO   = File.expand_path("../../../initramfs/build/amd64/kernel-initrd/initramfs.cpio.zst", __dir__)

      class TierInsufficient < StandardError; end
      class PreflightFailed  < StandardError; end

      # ── Output primitives (replace per-seed lambdas) ──────────────────
      def step(label)
        puts "\n  [step] #{label}"
      end

      def ok(msg)
        puts "    ✓ #{msg}"
      end

      def warn_msg(msg)
        puts "    ⚠ #{msg}"
      end

      def fail_with(msg)
        puts "    ✗ #{msg}"
        abort("  💥 SMOKE FAIL")
      end

      def assert(condition, msg)
        condition ? ok(msg) : fail_with(msg)
      end

      def skipped(msg)
        puts "  ⊘ skipped (#{msg})"
      end

      # ── Tier gate ─────────────────────────────────────────────────────
      def current_tier
        ENV.fetch("SMOKE_K3S_LEVEL", "db")
      end

      def tier_at_least?(tier)
        TIER_INDEX[current_tier] >= TIER_INDEX[tier.to_s]
      end

      def tier_gate(required:)
        level = current_tier
        raise PreflightFailed, "invalid SMOKE_K3S_LEVEL=#{level}" unless TIER_INDEX.key?(level)
        raise PreflightFailed, "invalid required=#{required}" unless TIER_INDEX.key?(required.to_s)
        if TIER_INDEX[level] < TIER_INDEX[required.to_s]
          raise TierInsufficient,
                "phase requires SMOKE_K3S_LEVEL >= #{required} (current: #{level})"
        end
        level
      end

      # ── Preflight (8-item env check, level-gated) ─────────────────────
      def preflight!(level: current_tier)
        step("Preflight (tier=#{level})")
        preflight_db!
        return ok("preflight ok (db tier)") if level == "db"

        preflight_libvirt_mode!
        preflight_kvm!
        preflight_virsh!
        preflight_initramfs!
        preflight_fwcfg_dir!
        ok("preflight ok (#{level} tier)")
      end

      def preflight_db!
        account = ::Account.first
        raise PreflightFailed, "no Account exists — seed accounts first" unless account

        # Clusters whose IDs appear in the state sidecar are "mine" —
        # left behind by a prior phase and intentionally consumed by
        # the current phase. They're not stale.
        sidecar_cluster_ids = state_read.values_at(*state_read.keys.grep(/cluster_id\z/)).compact
        unowned = ::Devops::KubernetesCluster.where(account: account)
                                              .where.not(id: sidecar_cluster_ids)
        if unowned.exists?
          if ENV["SMOKE_K3S_AUTO_CLEAN"] == "1"
            ids = unowned.pluck(:id).map { |i| i[0, 8] }.join(", ")
            count = unowned.count
            unowned.destroy_all
            warn_msg("auto-cleaned #{count} unowned Devops::KubernetesCluster row(s): [#{ids}]")
          else
            ids = unowned.pluck(:id, :status).map { |i, s| "#{i[0, 8]}=#{s}" }.join(", ")
            raise PreflightFailed,
                  "stale Devops::KubernetesCluster rows present in account (not in state sidecar): [#{ids}]. " \
                  "Set SMOKE_K3S_AUTO_CLEAN=1 to auto-destroy, or clean manually. " \
                  "If these are intentional, delete /tmp/smoke-k3s-state.json + re-run from phase 1."
          end
        end

        warn_if_federation_child!(account)
      end

      def warn_if_federation_child!(account)
        return unless defined?(::System::FederationPeer)
        if ::System::FederationPeer.where(account: account, spawn_role: "child").exists?
          warn_msg("Account '#{account.name}' appears to be a federation child " \
                   "(System::FederationPeer with spawn_role=child exists). " \
                   "Smoke results may be skewed; consider running on the primary account.")
        end
      end

      def preflight_libvirt_mode!
        mode = ENV["POWERNODE_LIBVIRT_MODE"].to_s
        return if mode == "real"
        raise PreflightFailed,
              "SMOKE_K3S_LEVEL >= single requires POWERNODE_LIBVIRT_MODE=real " \
              "(got #{mode.inspect}). See runbooks/k3s-smoke-full-lifecycle.md for the env template."
      end

      def preflight_kvm!
        if File.readable?("/dev/kvm")
          @kvm_available = true
          return
        end

        if ENV["SMOKE_K3S_KVM_AVAILABLE"] == "0"
          @kvm_available = false
          warn_msg("/dev/kvm unavailable; wait_until timeouts will be multiplied × 6 (TCG fallback)")
          return
        end

        raise PreflightFailed,
              "/dev/kvm not readable (uid=#{Process.uid}). " \
              "Either run with sudo / add user to kvm group, or set SMOKE_K3S_KVM_AVAILABLE=0 " \
              "to accept slow TCG-only emulation."
      end

      def preflight_virsh!
        stdout, stderr, status = Open3.capture3("virsh", "uri")
        unless status.success?
          err = stderr.to_s.strip.empty? ? "(no stderr; command-not-found?)" : stderr.to_s.strip[0, 240]
          raise PreflightFailed, "virsh uri failed (#{status.exitstatus}): #{err}"
        end

        actual_uri = stdout.to_s.strip
        expected_uri = ENV["POWERNODE_LIBVIRT_URI"].to_s
        if expected_uri.present? && actual_uri != expected_uri
          warn_msg("virsh uri = #{actual_uri.inspect}, but POWERNODE_LIBVIRT_URI = #{expected_uri.inspect}; " \
                   "a system LIBVIRT_DEFAULT_URI may be overriding. Verify the env alignment.")
        end
      end

      def preflight_initramfs!
        unless File.exist?(INITRAMFS_KERNEL)
          raise PreflightFailed,
                "initramfs kernel missing at #{INITRAMFS_KERNEL}. " \
                "Build via extensions/system/initramfs/build.sh first."
        end
        unless File.exist?(INITRAMFS_CPIO)
          raise PreflightFailed,
                "initramfs cpio missing at #{INITRAMFS_CPIO}. " \
                "Build via extensions/system/initramfs/build.sh first."
        end

        # Head-byte check to catch the cross-arch-build case (an arm64
        # kernel sitting in amd64/ would silently boot-fail at QEMU).
        # ELF magic = 0x7f 'E' 'L' 'F'; EFI stub magic = 'M' 'Z'.
        head = File.binread(INITRAMFS_KERNEL, 4)
        unless head.bytes[0..3] == [ 0x7f, 0x45, 0x4c, 0x46 ] || head[0, 2] == "MZ"
          raise PreflightFailed,
                "initramfs kernel at #{INITRAMFS_KERNEL} does not start with ELF or EFI magic " \
                "(got bytes=#{head.bytes.inspect}). Wrong arch? Corrupted artifact?"
        end
      end

      def preflight_fwcfg_dir!
        dir = ENV.fetch("POWERNODE_FWCFG_DIR", "/var/run/powernode-fwcfg")
        FileUtils.mkdir_p(dir)
        probe = File.join(dir, ".smoke-write-probe")
        File.write(probe, "ok")
        File.delete(probe)
      rescue StandardError => e
        raise PreflightFailed, "POWERNODE_FWCFG_DIR=#{dir.inspect} not writable: #{e.class}: #{e.message}"
      end

      # ── Polling ───────────────────────────────────────────────────────
      def wait_until(timeout:, poll: 2, label: nil)
        effective_timeout = @kvm_available == false ? timeout * 6 : timeout
        deadline = Time.now + effective_timeout
        print "    polling #{label}" if label
        last_result = nil
        while Time.now < deadline
          last_result = yield
          if last_result
            elapsed = (effective_timeout - (deadline - Time.now)).round(1)
            puts " ✓ (#{elapsed}s)" if label
            return last_result
          end
          print "."
          sleep poll
        end
        puts ""
        raise Timeout::Error,
              "wait_until #{label.inspect} timed out after #{effective_timeout}s; last=#{last_result.inspect}"
      end

      # ── State sidecar IO ──────────────────────────────────────────────
      def state_read
        return {} unless File.exist?(STATE_PATH)
        JSON.parse(File.read(STATE_PATH))
      rescue JSON::ParserError
        warn_msg("#{STATE_PATH} unparseable; treating as empty")
        {}
      end

      def state_write(hash)
        current = state_read
        merged = current.merge(hash.transform_keys(&:to_s))
        File.write(STATE_PATH, JSON.pretty_generate(merged))
        merged
      end

      # ── Account + bootstrap helpers ───────────────────────────────────
      def discover_or_create_account!
        account = ::Account.first
        fail_with("no Account exists") unless account
        warn_if_federation_child!(account)
        account
      end

      # Idempotent: ensures Node + NodeInstance + Sdwan::Peer + module
      # assignment exist for a given site identity. Re-running picks up
      # the existing rows by name + account scope.
      def bootstrap_node_instance!(name:, network:, role: :server, k3s_module: nil)
        account = ::Account.first
        module_name = (role.to_sym == :server ? "k3s-server" : "k3s-agent")
        k3s_module ||= ::System::NodeModule.find_by(account: account, name: module_name)
        fail_with("#{module_name} module not seeded — run k3s_modules.rb first") unless k3s_module

        template = ::System::NodeTemplate.find_by(account: account, name: "base")
        fail_with("base template not seeded — run node_module_catalog.rb first") unless template

        node = ::System::Node.find_or_create_by!(account: account, name: name) do |n|
          n.node_template = template
          n.description   = "smoke-k3s — auto-created"
        end

        instance = ::System::NodeInstance.find_or_initialize_by(node: node, name: "#{name}-instance")
        if instance.new_record?
          provider = ::System::Provider.find_by(account: account, provider_type: "local_qemu")
          if provider
            region = provider.provider_regions.find_by(region_code: "local")
            itype  = provider.provider_instance_types.find_by(instance_type_code: "qemu.small")
            instance.assign_attributes(
              provider_region:        region,
              provider_instance_type: itype
            ) if region && itype
          end
          instance.assign_attributes(variety: "cloud", status: "pending")
          instance.save!
        end

        peer = ::Sdwan::Peer.find_or_create_by!(
          account: account,
          sdwan_network_id: network.id,
          node_instance: instance
        ) do |p|
          p.publicly_reachable = false
        end

        ::System::NodeModuleAssignment.find_or_create_by!(node: node, node_module: k3s_module) do |a|
          a.enabled = true
        end

        [ instance, peer ]
      end

      # Polls Devops::KubernetesCluster scoped to the account until
      # status=="active". On timeout, dumps the cluster's bootstrap_events
      # history + kube_node statuses for diagnostic context.
      def wait_for_cluster_active!(account:, timeout: 600)
        wait_until(timeout: timeout, label: "cluster active") do
          ::Devops::KubernetesCluster.where(account: account, status: "active").order(:created_at).last
        end
      rescue Timeout::Error => e
        cluster = ::Devops::KubernetesCluster.where(account: account).order(:created_at).last
        events = Array(cluster&.metadata&.dig("bootstrap_events")).last(20)
        events_str = events.map { |ev| "  #{ev['ts']} #{ev['phase']}/#{ev['status']} #{ev['message']}" }.join("\n")
        kube_nodes = cluster&.kubernetes_nodes&.map { |n| "#{n.role}=#{n.status}" }&.join(", ")
        fail_with(<<~DIAG)
          cluster never reached active
          last status:    #{cluster&.status.inspect}
          node_count:     #{cluster&.node_count}
          cni_plugin:     #{cluster&.cni_plugin}
          pod_cidr:       #{cluster&.metadata&.dig('pod_cidr').inspect}
          api_vip_id:     #{cluster&.metadata&.dig('api_vip_id').inspect}
          kube_nodes:     #{kube_nodes}
          recent events:
          #{events_str}
          elapsed:        #{e.message}
        DIAG
      end

      # ── Tier-branching bootstrap contract ─────────────────────────────
      # db tier: operator-driven (call provisioner directly).
      # single+ tier: agent-driven (boot VM, agent POSTs phase=bootstrap).
      def run_bootstrap_phase(account:, instance:, network:, k8s_version: "v1.30.5+k3s1", cni_plugin: nil)
        if tier_at_least?("single")
          step("Boot VM (#{instance.name}) — agent will drive bootstrap")
          provision_via_local_qemu!(instance: instance)
          wait_for_cluster_active!(account: account, timeout: 600)
        else
          step("Synth bootstrap via KubernetesClusterProvisionerService (db tier)")
          peer = ::Sdwan::Peer.where(node_instance: instance).where.not(assigned_address: nil).first
          fail_with("instance #{instance.name} has no SDWAN peer with assigned_address") unless peer

          cluster = ::System::KubernetesClusterProvisionerService.bootstrap!(
            node_instance: instance,
            kubeconfig:    synth_kubeconfig_yaml(peer.assigned_address),
            server_token:  "K10smoke-#{SecureRandom.hex(8)}",
            agent_token:   "K10smoke-#{SecureRandom.hex(8)}",
            k8s_version:   k8s_version,
            cni_plugin:    cni_plugin
          )
          ::System::KubernetesClusterProvisionerService.mark_node_ready!(
            node_instance: instance, k8s_version: k8s_version
          )
          cluster.reload
          cluster
        end
      end

      # LocalQemu real-mode boot. Mirrors the pattern in smoke_test_provision.rb.
      def provision_via_local_qemu!(instance:)
        account = instance.account
        provider = ::System::Provider.find_by(account: account, provider_type: "local_qemu")
        fail_with("no local_qemu provider — run node_module_catalog.rb first") unless provider

        connection = provider.provider_connections.find_by(name: "qemu-conn")
        fail_with("no qemu-conn — run node_module_catalog.rb first") unless connection

        region = provider.provider_regions.find_by(region_code: "local")
        adapter = ::System::Providers::Registry.for(connection, region: region)

        result = adapter.create_instance(
          instance: instance,
          name:     "powernode-k3s-smoke-#{instance.id[0..7]}",
          arch:     "amd64",
          memory_mb: 2048,
          vcpus:    2,
          options:  {}
        )
        ok("VM created (runner=#{::System::Providers::LocalQemuProvider.runner.class.name})")
        result
      end

      # Minimal kubeconfig YAML for db-tier seeds. The real kubeconfig
      # comes from the on-VM k3s install; at db tier we synthesize what
      # the provisioner needs (a parseable YAML string is enough — the
      # provisioner stores it encrypted and clients fetch it later).
      def synth_kubeconfig_yaml(server_addr)
        <<~YAML.strip
          apiVersion: v1
          kind: Config
          clusters:
          - cluster:
              server: https://[#{server_addr.split('/').first}]:6443
            name: smoke-k3s
          contexts: []
          users: []
        YAML
      end

      # ── Checkpoint ────────────────────────────────────────────────────
      def checkpoint(label)
        if ENV["SMOKE_K3S_PAUSE"] == "1"
          if $stdin.tty?
            puts "\n[CHECKPOINT] #{label} — press Enter to continue"
            $stdin.gets
          else
            puts "\n[CHECKPOINT] #{label} (pause skipped — no TTY)"
          end
        else
          puts "\n[CHECKPOINT] #{label}"
        end
      end

      # ── kubectl helpers (site+ tier) ──────────────────────────────────

      def kubectl_binary
        ENV.fetch("SMOKE_K3S_KUBECTL", "kubectl")
      end

      def kubectl_available?
        system("which #{kubectl_binary} > /dev/null 2>&1")
      end

      # Fetch a kubeconfig YAML for the given cluster via the platform's
      # MCP tool (matches the real operator path). Writes to dest_path
      # and returns the path. Caller is responsible for cleanup.
      def fetch_kubeconfig!(cluster:, user:, dest_path:)
        prov_tool = ::Ai::Tools::KubernetesProvisioningTool.new(
          account: cluster.account, agent: nil, user: user
        )
        result = prov_tool.send(:call, action: "kubernetes_get_kubeconfig", cluster_id: cluster.id)
        fail_with("kubeconfig retrieval failed: #{result.inspect[0, 200]}") unless result[:success]
        File.write(dest_path, result[:kubeconfig])
        dest_path
      end

      # Apply YAML via kubectl. Returns the kubectl exit status.
      def kubectl_apply!(kubeconfig:, yaml:)
        Open3.popen3("#{kubectl_binary} --kubeconfig=#{kubeconfig} apply -f -") do |stdin, _stdout, stderr, wait|
          stdin.write(yaml)
          stdin.close
          status = wait.value
          unless status.success?
            err = stderr.read.to_s[0, 240]
            fail_with("kubectl apply failed (#{status.exitstatus}): #{err}")
          end
          status
        end
      end

      # Run kubectl get with -o jsonpath and return the trimmed stdout.
      # Returns nil if the command fails (caller decides how to react).
      def kubectl_get_jsonpath(kubeconfig:, args:, jsonpath:)
        cmd = "#{kubectl_binary} --kubeconfig=#{kubeconfig} get #{args} -o jsonpath='#{jsonpath}' 2>/dev/null"
        out = `#{cmd}`.to_s.strip
        $?.success? ? out : nil
      end

      def kubectl_delete!(kubeconfig:, resource:)
        system("#{kubectl_binary} --kubeconfig=#{kubeconfig} delete #{resource} --wait=false > /dev/null 2>&1")
      end

      # Poll until `count` pods matching `label` are Ready, or timeout.
      def wait_for_pods_ready!(kubeconfig:, label:, count:, timeout: 180)
        wait_until(timeout: timeout, label: "#{count} pods Ready (label=#{label})") do
          out = kubectl_get_jsonpath(
            kubeconfig: kubeconfig,
            args: "pods -l #{label} -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}'",
            jsonpath: "{.items[*].status.conditions[?(@.type==\"Ready\")].status}"
          )
          # Each pod's Ready condition adds a token; count True tokens.
          out.to_s.split.count { |s| s == "True" } >= count
        end
      end

      # Returns [{name:, node_name:, ip:}, ...] for pods matching label.
      def pod_ips_by_node(kubeconfig:, label:)
        # jsonpath gives us aligned arrays — names, nodes, ips — separated by spaces
        names = kubectl_get_jsonpath(
          kubeconfig: kubeconfig,
          args: "pods -l #{label}",
          jsonpath: "{.items[*].metadata.name}"
        ).to_s.split
        nodes = kubectl_get_jsonpath(
          kubeconfig: kubeconfig,
          args: "pods -l #{label}",
          jsonpath: "{.items[*].spec.nodeName}"
        ).to_s.split
        ips = kubectl_get_jsonpath(
          kubeconfig: kubeconfig,
          args: "pods -l #{label}",
          jsonpath: "{.items[*].status.podIP}"
        ).to_s.split

        names.each_with_index.map do |n, i|
          { name: n, node_name: nodes[i], ip: ips[i] }
        end
      end

      # ── tcpdump helper (site+ tier) ───────────────────────────────────

      # Captures up to `packet_count` packets on `iface` matching `filter`.
      # Returns the integer count of packets captured. Blocks until tcpdump
      # exits (either packet_count reached or timeout). Caller must have
      # sudo for tcpdump.
      #
      # The capture runs in foreground; for parallel-with-traffic use,
      # caller should fork (see tcpdump_in_background below).
      def tcpdump_capture!(iface:, packet_count: 20, filter: "", timeout: 30)
        sudo = ENV.fetch("SMOKE_K3S_TCPDUMP_SUDO", "sudo")
        cmd = [
          sudo, "tcpdump", "-i", iface, "-n", "-q",
          "-c", packet_count.to_s,
          *(filter.empty? ? [] : filter.split)
        ]
        out, err, status = Open3.capture3(*cmd)
        captured = out.lines.grep(/^\d/).count
        if !status.success? && captured == 0
          warn_msg("tcpdump exited #{status.exitstatus}: #{err.to_s[0, 240]}")
        end
        captured
      end

      # Start tcpdump in background, return the PID. Caller stops it via
      # tcpdump_stop(pid) after the workload has run. Output goes to
      # /tmp/smoke-k3s-tcpdump-<iface>.log. Returns the (pid, log_path).
      def tcpdump_in_background!(iface:, packet_count: 50, filter: "")
        sudo = ENV.fetch("SMOKE_K3S_TCPDUMP_SUDO", "sudo")
        log_path = "/tmp/smoke-k3s-tcpdump-#{iface}-#{SecureRandom.hex(3)}.log"
        cmd = [
          sudo, "tcpdump", "-i", iface, "-n", "-q",
          "-c", packet_count.to_s,
          *(filter.empty? ? [] : filter.split)
        ]
        # Redirect both stdout + stderr to the log file
        pid = Process.spawn(*cmd, out: log_path, err: log_path)
        sleep 1 # let tcpdump open the socket
        [ pid, log_path ]
      end

      def tcpdump_stop(pid:)
        sudo = ENV.fetch("SMOKE_K3S_TCPDUMP_SUDO", "sudo")
        # tcpdump runs under sudo; kill it via sudo to avoid permission issues
        system("#{sudo} kill #{pid} > /dev/null 2>&1")
        Process.wait(pid) rescue nil
      end

      def tcpdump_count(log_path:)
        return 0 unless File.exist?(log_path)
        File.readlines(log_path).count { |line| line =~ /^\d/ }
      end
    end
  end
end
