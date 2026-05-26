# frozen_string_literal: true

# Worker-as-NodeInstance provisioning (Stage 8b.3).
#
# A Sidekiq Worker is now backed by a NodeInstance — the NodeInstance
# carries the mTLS identity (cert at /persist/var/lib/powernode/pki/,
# rotation via the agent's CertRotator), and the Worker row carries the
# domain-specific configuration (permissions, queue assignments, etc.).
#
# Two tasks here:
#
#   - `powernode:worker:link_existing` (one-shot migration)
#     For each existing Worker row that lacks a node_instance_id,
#     either link it to an existing NodeInstance (by name match) or
#     report it for operator review. Idempotent.
#
#   - `powernode:worker:provision NAME=... TEMPLATE_SLUG=powernode-hub`
#     Atomic two-step: (1) create a NodeInstance via the standard
#     provisioning flow, (2) create the Worker row linked to it. The
#     NodeInstance will enroll, receive its cert, and the agent will
#     reconcile the assigned template (which includes powernode-hub-worker).
#     The Worker row is what InternalBaseController resolves via
#     `Worker.find_by(node_instance_id: cert_cn)`.
namespace :powernode do
  namespace :worker do
    desc "Link existing Worker rows to NodeInstances by name match (one-shot migration)"
    task link_existing: :environment do
      linked = 0
      orphans = []

      ::Worker.where(node_instance_id: nil).find_each do |worker|
        # Match on name — operators commonly name a Worker after the host
        # ("ops-sidekiq-01", "worker-host-a") and the NodeInstance has the
        # same name. Conservative match: name + account.
        instance = ::System::NodeInstance.joins(node: :account)
                                          .where(accounts: { id: worker.account_id })
                                          .where("system_node_instances.config->>'name' = ? OR system_nodes.name = ?",
                                                 worker.name, worker.name)
                                          .first
        if instance
          worker.update!(node_instance_id: instance.id)
          linked += 1
          puts "  linked Worker(#{worker.name}) → NodeInstance(#{instance.id})"
        else
          orphans << worker
        end
      end

      puts ""
      puts "Linked #{linked} workers."
      if orphans.any?
        puts "#{orphans.size} orphan Workers (no NodeInstance match — review):"
        orphans.each { |w| puts "  Worker(id=#{w.id} name=#{w.name} account_id=#{w.account_id})" }
      end
    end

    desc "Provision a worker NodeInstance + linked Worker row (NAME, ACCOUNT_ID, TEMPLATE_SLUG required)"
    task provision: :environment do
      name = ENV["NAME"] or abort("Set NAME=<worker-hostname>")
      account_id = ENV["ACCOUNT_ID"] or abort("Set ACCOUNT_ID=<uuid>")
      template_slug = ENV["TEMPLATE_SLUG"] || "powernode-hub"

      account = ::Account.find(account_id)
      template = ::System::NodeTemplate.where(account_id: account.id, slug: template_slug).first ||
                 abort("Template not found: account=#{account_id} slug=#{template_slug}")

      ActiveRecord::Base.transaction do
        # 1. Standard NodeInstance provisioning. The operator picks a
        # provider/region via the existing flow; here we just create the
        # row + assign template. Actual VM spawning is the provider's job.
        node = ::System::Node.create!(
          account: account,
          name:    name,
          node_template: template
        )
        instance = ::System::NodeInstance.create!(
          node: node,
          status: "pending",
          config: { "name" => name, "role" => "worker" }
        )

        # 2. Worker row, linked to the NodeInstance via node_instance_id.
        # Domain-specific config (permissions, roles, queue list) is
        # operator-assigned post-provisioning via the standard Worker admin
        # surface. We just create the linking row here.
        worker = ::Worker.create!(
          name:             name,
          account:          account,
          status:           "active",
          node_instance_id: instance.id
        )

        puts "Provisioned:"
        puts "  NodeInstance: #{instance.id}"
        puts "  Worker:       #{worker.id} (linked via node_instance_id=#{instance.id})"
        puts "  Template:     #{template.slug} (agent will reconcile powernode-hub-worker module)"
        puts ""
        puts "Next: trigger the provider to spawn the VM (`system_provision_instance`"
        puts "or via the operator UI). On boot, the agent enrolls + receives its mTLS"
        puts "cert; once active_certificate is present, the Worker can authenticate"
        puts "to /api/v1/internal/* immediately."
      end
    end

    desc "Bootstrap a SELF-HOST worker cert (mints cert directly; no agent enrollment). \
For platform hosts where Sidekiq is co-resident with Rails. Required env: NAME, ACCOUNT_ID; \
optional: OUT_DIR (default /persist/var/lib/powernode/pki), TTL_DAYS (default 90)."
    task bootstrap_self_host: :environment do
      name = ENV["NAME"] or abort("Set NAME=<host-name> (e.g., ops-sidekiq)")
      account_id = ENV["ACCOUNT_ID"] or abort("Set ACCOUNT_ID=<uuid>")
      out_dir = ENV["OUT_DIR"] || "/persist/var/lib/powernode/pki"
      ttl_days = (ENV["TTL_DAYS"] || "90").to_i

      account = ::Account.find(account_id)
      template = ::System::NodeTemplate.where(account_id: account.id, slug: "powernode-hub").first ||
                 abort("powernode-hub template not found on this account")

      result = ActiveRecord::Base.transaction do
        # Skip the standard provisioning flow — this host already exists,
        # we just need a NodeInstance + Worker shell to anchor the cert.
        node = ::System::Node.find_or_create_by!(account: account, name: name) do |n|
          n.node_template = template
        end
        instance = ::System::NodeInstance.where(node: node).first ||
                   ::System::NodeInstance.create!(
                     node: node,
                     status: "running",  # already running — this is the local host
                     config: { "name" => name, "role" => "worker", "self_host" => true }
                   )
        worker = ::Worker.where(node_instance_id: instance.id).first ||
                 ::Worker.create!(
                   name:             name,
                   account:          account,
                   status:           "active",
                   node_instance_id: instance.id
                 )

        # Mint cert directly via InternalCaService — no agent enrollment,
        # no bootstrap token. Operator runs this on the platform host
        # itself, so the cert material can land at the agent's standard
        # path (/persist/var/lib/powernode/pki/) directly.
        require "openssl"
        key = OpenSSL::PKey.generate_key("ED25519")
        csr = OpenSSL::X509::Request.new
        csr.subject = OpenSSL::X509::Name.new([ [ "CN", instance.id ] ])
        csr.public_key = key
        csr.sign(key, nil)

        issued = ::System::InternalCaService.issue_certificate(
          csr_pem:     csr.to_pem,
          ttl_seconds: ttl_days * 24 * 3600,
          common_name: instance.id
        )

        { worker: worker, instance: instance, key: key, issued: issued }
      end

      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "node.key"),       result[:key].private_to_pem, mode: "w", perm: 0o600)
      File.write(File.join(out_dir, "node.crt"),       result[:issued][:cert_pem],  mode: "w", perm: 0o644)
      File.write(File.join(out_dir, "ca-bundle.crt"),  result[:issued][:ca_chain_pem] || ::System::InternalCaService.ca_chain_pem, mode: "w", perm: 0o644)

      puts "Self-host worker bootstrapped:"
      puts "  Worker:       #{result[:worker].id}"
      puts "  NodeInstance: #{result[:instance].id} (CN of cert)"
      puts "  PKI dir:      #{out_dir}"
      puts "  Files:        node.key (0600), node.crt (0644), ca-bundle.crt (0644)"
      puts "  Expires:      #{result[:issued][:not_after]&.iso8601}"
      puts ""
      puts "Next: restart powernode-worker@default — Sidekiq will pick up the"
      puts "new mTLS material on boot. Cert rotation via the standard agent path"
      puts "is NOT available for self-host (no agent here); operator must re-run"
      puts "this task before NotAfter."
    end
  end
end
