# frozen_string_literal: true

require "open3"

module System
  # Assembles the two things a pooled dev-cell NodeInstance needs to act as an
  # autonomous campaign executor, WITHOUT ever minting an account-wide secret:
  #
  #   MCP   — the cell authenticates to /mcp by presenting its node client cert
  #           (mTLS; resolved by Mcp::Principal.for_instance_cn). We only have
  #           to (a) ensure the instance has announced as a NodeInstancePeer and
  #           (b) grant that peer EXACTLY the three dev-loop tools. No token,
  #           no OAuth client, no operator-user binding. The returned block is
  #           just { mcp_url } — the cell runs a local mTLS proxy that presents
  #           the node cert; that proxy is the dev-cell MODULE's concern.
  #
  #   Gitea — a per-repo, read-WRITE deploy key on ONLY the source repo (not an
  #           account-wide PAT). The Ed25519 keypair is generated in-service; the
  #           private half is stored in Vault (System::DevCellDeployKey) and
  #           returned ONLY in the mTLS bootstrap body. ff-only is enforced by
  #           branch protection on the source repo (develop/master refuse direct
  #           push + force-push; loop/* stay protected → no force-push).
  #
  # SECURITY: the private key flows generator -> Vault + response body ONLY. It
  # is never logged. The fleet event (emitted by the caller) carries ids only.
  class DevCellBootstrapService
    # Raised when a Vault-only credential does not confirm a real Vault store —
    # forces the bootstrap to fail CLOSED (roll back + delete the Gitea key)
    # rather than hand out a key whose private half was persisted nowhere.
    class VaultStoreError < StandardError; end

    Result = Struct.new(:ok?, :mcp, :gitea, :error, keyword_init: true)

    # FIXED, server-defined dev-loop tool grant (NOT caller-specified). The
    # dev-cell peer may invoke EXACTLY these three platform MCP tools and
    # nothing else (default-deny). These are the /mcp catalog names
    # ("platform.<tool>") that Mcp::Principal#may_invoke? fnmatches the request
    # tool name against — verified against Ai::Tools::PlatformApiToolRegistry,
    # where each Ai::Tools::DevLoopTool action (dev_next_task / dev_complete_task
    # / dev_list_tasks) is registered as its own `platform.<action>` catalog
    # entry (registry all_tools map + tool_definitions). `delegate_ralph_task`
    # (also DevLoopTool) is intentionally NOT granted.
    DEV_LOOP_MCP_TOOLS = %w[
      platform.dev_next_task
      platform.dev_complete_task
      platform.dev_list_tasks
    ].freeze

    # Capability marker recorded on the peer so fleet views / the operator UI
    # can distinguish a dev-cell executor peer from a general announced peer.
    DEV_CELL_CAPABILITY = { "role" => "dev_cell_executor" }.freeze

    # Read-WRITE deploy key on the source repo (the cell pushes loop/* branches).
    DEPLOY_KEY_READ_ONLY = false

    # Advisory-lock namespace ("DVCL") — serialises per-instance deploy-key
    # rotation (delete→create + DB/Vault persist) against a concurrent re-boot
    # of the same cell. Session-level (paired lock/unlock), so no DB transaction
    # is pinned across the external Gitea HTTP calls.
    ADVISORY_LOCK_NAMESPACE = 0x4456_434C

    def initialize(node_instance:, platform_base_url:, source_repo:)
      @instance = node_instance
      @account = node_instance.account
      @platform_base_url = platform_base_url.to_s.chomp("/")
      @source_repo = source_repo.to_s
    end

    def call
      # Fail-closed ordering (A1' rework): fully provision Gitea FIRST — branch
      # protection is asserted BEFORE the write key is issued, and the Vault
      # store is confirmed — THEN grant MCP LAST. So a Gitea/Vault failure
      # returns 503 with NO persisted MCP grant left behind (the grant is the
      # last, only-on-full-success side effect).
      gitea = build_gitea
      return Result.new(ok?: false, error: "gitea_unavailable") unless gitea

      mcp = build_mcp
      return Result.new(ok?: false, error: "mcp_grant_failed") unless mcp

      Result.new(ok?: true, mcp: mcp, gitea: gitea)
    end

    private

    # ---- MCP: instance principal + narrow grant ---------------------------

    def build_mcp
      result = ::System::AgentPeeringService.announce!(
        node_instance: @instance,
        capabilities: DEV_CELL_CAPABILITY,
        skills: [],
        addresses: []
      )
      return nil unless result.ok? && result.peer

      # mode: :replace so the dev-cell peer is scoped to ONLY these three tools
      # (default-deny everything else) even across re-boots / prior grants.
      result.peer.grant_mcp_tools!(DEV_LOOP_MCP_TOOLS, mode: :replace)

      # The MCP streamable-HTTP endpoint is /api/v1/mcp/message (routes.rb:
      # `post "message" => streamable_http#message`), NOT a bare /mcp. The
      # dev-cell mcp-proxy forwards to this URL verbatim; a bare /mcp 404s and
      # the executor can't pull/complete dev-loop tasks. (BUG-P)
      { mcp_url: "#{@platform_base_url}/api/v1/mcp/message" }
    end

    # ---- Gitea: per-repo deploy key + branch protection -------------------

    def build_gitea
      credential = ::System::DevCellDeployKey.gitea_credential_for(@account)
      return nil unless credential

      owner, repo = @source_repo.split("/", 2)
      return nil if owner.blank? || repo.blank?

      client = ::Devops::Git::ApiClient.for(credential)

      # ff-only, fail-CLOSED and BEFORE the key is issued: develop + master
      # protection must be set AND read back as blocking direct push. If either
      # can't be confirmed, abort the whole bootstrap (→ 503) so a read-write
      # deploy key is NEVER minted against an unprotected develop/master.
      # Operator-configurable (default ON): SiteSetting
      # "dev_cell_branch_protection_enabled" — this platform's own operator
      # runs single-tenant and does not want Gitea branch protection managed
      # by dev-cell bootstrap; every bootstrap was silently re-applying it
      # out from under manual disables in the Gitea UI.
      if branch_protection_enabled?
        ensure_protected_branch!(client, owner, repo, "develop")
        ensure_protected_branch!(client, owner, repo, "master")
        # loop/* stays best-effort (the cell pushes here; protected ⇒ no force-push).
        safe_branch_protection(client, owner, repo, "loop/*", enable_push: true)
      end

      keypair = ::System::DevCell::SshKeyGenerator.generate(comment: deploy_key_title)
      register_deploy_key!(client, owner, repo, keypair)

      {
        clone_url: ssh_clone_url(client, credential, owner, repo),
        private_key: keypair.private_key_openssh,
        known_hosts: bundle_known_hosts(client, credential, owner, repo)
      }
    rescue ::Devops::Git::ApiClient::ApiError, VaultStoreError => e
      Rails.logger.warn(
        "[DevCellBootstrap] gitea provisioning failed for instance #{@instance.id}: #{e.class}: #{e.message}"
      )
      nil
    end

    # Rotate-on-bootstrap. The Gitea rotate (list→delete→create) is serialised
    # per-instance by a SESSION advisory lock (not a txn-wrapped one), so no DB
    # transaction is pinned across the external HTTP calls. The DB row + Vault
    # store happen in a short inner transaction; if that or the Vault confirm
    # fails, the just-created Gitea key is deleted so nothing usable is left
    # behind against a rolled-back row (fail-closed, no orphan key).
    def register_deploy_key!(client, owner, repo, keypair)
      title = deploy_key_title

      with_instance_advisory_lock do
        remove_existing_deploy_keys!(client, owner, repo, title)

        created = client.create_deploy_key(
          owner, repo, title, keypair.public_key_openssh,
          read_only: DEPLOY_KEY_READ_ONLY
        )
        unless created.is_a?(Hash) && created[:success]
          raise ::Devops::Git::ApiClient::ApiError,
                "deploy key create failed: #{created.is_a?(Hash) ? created[:error] : created.inspect}"
        end
        key_id = created.dig(:key, "id")

        begin
          persist_and_store!(keypair: keypair, owner: owner, repo: repo, key_id: key_id, title: title)
        rescue StandardError => e
          # Fail-closed: the Gitea key exists but persistence/Vault failed —
          # delete it so no usable read-write key survives without a DB row.
          begin
            client.delete_deploy_key(owner, repo, key_id)
          rescue StandardError => cleanup_err
            Rails.logger.warn(
              "[DevCellBootstrap] orphan deploy-key cleanup failed for instance #{@instance.id}: #{cleanup_err.message}"
            )
          end
          raise e
        end
      end
    end

    # Persist the (public) key metadata + store the PRIVATE key in Vault (or,
    # on a Vault-less deployment, the encrypted_credentials column via the
    # same VaultCredential DB-fallback path other credential models use), in
    # a short transaction. :vault and :database are both confirmed, real
    # storage — accept either. Anything else (nil, an unrecognized shape) is
    # a HARD failure: rolls the row back and fails closed (the caller then
    # deletes the Gitea key) rather than let an unconfirmed store read as OK.
    def persist_and_store!(keypair:, owner:, repo:, key_id:, title:)
      record = ::System::DevCellDeployKey.find_or_initialize_by(node_instance_id: @instance.id)

      ::System::DevCellDeployKey.transaction do
        record.assign_attributes(
          algorithm: keypair.algorithm,
          public_key_openssh: keypair.public_key_openssh,
          fingerprint: keypair.fingerprint,
          deploy_key_id: key_id,
          source_repo: "#{owner}/#{repo}",
          title: title
        )
        record.save!

        stored = record.store_in_vault("private_key_openssh" => keypair.private_key_openssh)
        unless stored.is_a?(Hash) && %i[vault database].include?(stored[:stored_in])
          raise VaultStoreError, "neither vault nor database confirmed secure storage (got #{stored.inspect})"
        end
      end

      record
    end

    def remove_existing_deploy_keys!(client, owner, repo, title)
      Array(client.list_deploy_keys(owner, repo))
        .select { |k| k["title"] == title }
        .each { |k| client.delete_deploy_key(owner, repo, k["id"]) }
    end

    # Default true (existing safety-by-default behavior for anyone else
    # deploying this platform); nil (row absent) also reads as enabled — only
    # an explicit false disables it. SiteSetting#get on a boolean row already
    # coerces to true/false; nil only occurs when the row doesn't exist.
    def branch_protection_enabled?
      ::SiteSetting.get("dev_cell_branch_protection_enabled") != false
    end

    # FATAL, read-back-confirmed protection for develop/master: set enable_push
    # false (blocks ALL direct push — a bare write deploy key is not whitelisted,
    # and a protected branch refuses force-push), then READ IT BACK and confirm.
    # Raises (→ build_gitea returns nil → 503) if the update fails or the
    # read-back can't confirm the branch blocks push. The ff-only guarantee is
    # thus enforced BEFORE the write key is issued, not fail-open after it.
    def ensure_protected_branch!(client, owner, repo, branch)
      result = client.update_branch_protection(owner, repo, branch, enable_push: false)
      unless result.is_a?(Hash) && result[:success]
        raise ::Devops::Git::ApiClient::ApiError,
              "branch protection update failed for #{owner}/#{repo}@#{branch}"
      end

      confirmed = client.get_branch_protection(owner, repo, branch)
      return if protection_blocks_push?(confirmed)

      raise ::Devops::Git::ApiClient::ApiError,
            "branch protection not confirmed for #{owner}/#{repo}@#{branch}"
    end

    def protection_blocks_push?(protection)
      protection.is_a?(Hash) && protection["enable_push"] == false
    end

    # Best-effort protection for loop/* (the cell DOES push these; the rule just
    # keeps them protected so force-push is refused). Non-fatal by design.
    def safe_branch_protection(client, owner, repo, branch, enable_push:)
      client.update_branch_protection(owner, repo, branch, enable_push: enable_push)
    rescue ::Devops::Git::ApiClient::ApiError => e
      Rails.logger.info(
        "[DevCellBootstrap] branch protection #{branch} on #{owner}/#{repo} skipped: #{e.message}"
      )
    end

    # Reachable SSH clone URL for the deploy-key clone/push.
    #
    # The clone host+port MUST match the host key pinned in
    # dev_cell_gitea_known_hosts (StrictHostKeyChecking), and Gitea
    # self-reports its CONTAINER-INTERNAL SSH_PORT (e.g. :220) which is often
    # not the published/reachable port — trusting it verbatim yields
    # "connect to <host> port 220: Connection refused". So derive the endpoint
    # in preference order:
    #   1. the pinned known_hosts line (host[+port]) — consistent by
    #      construction with the host key the cell verifies against;
    #   2. else Gitea's reported ssh_url HOST (the host IS correct) with a
    #      config-driven port (dev_cell_gitea_ssh_port / ENV), default 22 —
    #      Gitea's self-reported port is deliberately ignored;
    #   3. else the provider's web host (last resort — may differ from SSH host);
    #   4. else the https web URL.
    def ssh_clone_url(client, credential, owner, repo)
      host, port = resolved_ssh_endpoint(client, credential, owner, repo)
      return "#{credential.provider.effective_web_base_url}/#{owner}/#{repo}.git" if host.blank?

      if port == 22
        "git@#{host}:#{owner}/#{repo}.git"
      else
        "ssh://git@#{host}:#{port}/#{owner}/#{repo}.git"
      end
    end

    # [host, port] to reach Gitea over SSH — the SINGLE source of truth shared
    # by BOTH the clone URL (above) and the known_hosts host-key pin
    # (bundle_known_hosts, below), so the two can never disagree (a mismatch
    # would make StrictHostKeyChecking reject the clone). Preference order is
    # unchanged from the original ssh_clone_url derivation (see the doc comment
    # above): pinned known_hosts line → Gitea's reported ssh host (config-driven
    # port; Gitea's self-reported internal port ignored) → provider web host.
    # Memoised: owner/repo are constant per bootstrap, and this avoids a second
    # get_repository round-trip now that known_hosts also consumes it.
    def resolved_ssh_endpoint(client, credential, owner, repo)
      @resolved_ssh_endpoint ||= begin
        host, port = endpoint_from_known_hosts(known_hosts_for(credential))
        host = host.presence || gitea_ssh_host(client, owner, repo) || web_host(credential)
        port ||= configured_ssh_port
        [ host, port ]
      end
    end

    # [host, port] parsed from the FIRST real known_hosts line, or [nil, nil].
    # Handles "[host]:port key..." (non-standard port) and "host key..." (→ 22),
    # plus comma-separated host aliases ("host,1.2.3.4 key...").
    def endpoint_from_known_hosts(known_hosts)
      line = known_hosts.to_s.lines.map(&:strip).find { |l| l.present? && !l.start_with?("#") }
      return [ nil, nil ] if line.blank?

      token = line.split(/\s+/).first.to_s.split(",").first
      return [ nil, nil ] if token.blank?

      if (m = token.match(/\A\[([^\]]+)\]:(\d+)\z/))
        [ m[1], m[2].to_i ]
      else
        [ token, 22 ]
      end
    end

    # Host (only) from Gitea's reported ssh_url, in either ssh://user@host:port/…
    # or scp-style user@host:path form. The port is intentionally NOT taken here.
    def gitea_ssh_host(client, owner, repo)
      ssh = begin
        client.get_repository(owner, repo)&.dig("ssh_url")
      rescue ::Devops::Git::ApiClient::ApiError
        nil
      end
      return nil if ssh.blank?

      if ssh.start_with?("ssh://")
        begin
          URI.parse(ssh).host
        rescue URI::InvalidURIError
          nil
        end
      elsif (m = ssh.match(%r{\A(?:[^@/]+@)?([^:/]+):}))
        m[1]
      end
    end

    def web_host(credential)
      URI(credential.provider.effective_web_base_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    # Published/reachable SSH port. Config-driven (must match the known_hosts
    # pin); defaults to the standard 22. Gitea's self-reported port is ignored.
    def configured_ssh_port
      raw = ::SiteSetting.get("dev_cell_gitea_ssh_port").presence ||
            ENV["POWERNODE_DEV_CELL_GITEA_SSH_PORT"].presence
      port = raw.to_i
      port.positive? ? port : 22
    end

    # Operator-PINNED SSH host key line for StrictHostKeyChecking, sourced from
    # config (SiteSetting → ENV). Empty string when nothing is on record. This
    # is the authoritative/offline pin and also drives endpoint derivation
    # (resolved_ssh_endpoint, preference #1). The bundle's actual known_hosts is
    # produced by bundle_known_hosts, which keyscans when this is empty.
    def known_hosts_for(_credential)
      ::SiteSetting.get("dev_cell_gitea_known_hosts").presence ||
        ENV["POWERNODE_DEV_CELL_GITEA_KNOWN_HOSTS"].presence ||
        ""
    end

    # ssh-keyscan timeout (seconds). Fixed + short: this runs inline in the
    # bootstrap request path, which must not hang on an unreachable Gitea.
    SSH_KEYSCAN_TIMEOUT_SECONDS = 5

    # The known_hosts line(s) actually shipped in the bootstrap bundle.
    #
    # Preference:
    #   1. operator-pinned config (known_hosts_for) — authoritative, offline,
    #      highest assurance; when set, NO scan is performed.
    #   2. else a live `ssh-keyscan` of the SAME endpoint the clone URL uses
    #      (resolved_ssh_endpoint) — removes the manual prerequisite that
    #      previously left this empty and crash-looped provision.service with
    #      "known_hosts is empty in the bootstrap bundle". This is trust-on-
    #      first-use performed at the platform (a controlled position) once at
    #      bootstrap, then pinned for the node — strictly better than the node
    #      itself doing TOFU. Operators wanting strict pinning set option #1,
    #      which suppresses the scan.
    #
    # Best-effort: returns "" on any scan failure (unreachable Gitea, ssh-keyscan
    # not installed on the platform host, empty output). The node then still
    # fails closed — but a reachable Gitea with no pin now self-provisions
    # instead of dead-looping.
    def bundle_known_hosts(client, credential, owner, repo)
      pinned = known_hosts_for(credential)
      return pinned if pinned.present?

      host, port = resolved_ssh_endpoint(client, credential, owner, repo)
      return "" if host.blank?

      scan_ssh_host_key(host, port)
    end

    # Live host-key scan via `ssh-keyscan`, hardened for unattended server use:
    # array-form Open3 (no shell → no injection via a hostile host string),
    # fixed timeout, output validated as real (non-comment) key lines. Returns
    # "" and never raises, so bootstrap degrades gracefully if ssh-keyscan is
    # missing or Gitea is unreachable.
    def scan_ssh_host_key(host, port)
      return "" if host.blank?

      port = port.to_i
      port = 22 unless port.positive?

      # capture3 (not capture2e): ssh-keyscan writes host-key lines to STDOUT
      # and its informational banner ("# host:port SSH-2.0-...") to STDERR —
      # parse STDOUT only so a stderr line can never be mistaken for a key.
      out, _err, status = ::Open3.capture3(
        "ssh-keyscan", "-T", SSH_KEYSCAN_TIMEOUT_SECONDS.to_s, "-p", port.to_s, host
      )
      return "" unless status.success?

      lines = out.each_line.map(&:strip).reject { |l| l.blank? || l.start_with?("#") }
      return "" if lines.empty?

      "#{lines.join("\n")}\n"
    rescue StandardError => e
      Rails.logger.warn(
        "[DevCellBootstrap] ssh-keyscan #{host}:#{port} failed: #{e.class}: #{e.message}"
      )
      ""
    end

    def deploy_key_title
      @deploy_key_title ||= "dev-cell-#{@instance.id}"
    end

    # Session-level advisory lock (paired lock/unlock on the SAME connection),
    # so the Gitea rotate + DB/Vault persist are serialised per-instance WITHOUT
    # pinning a DB transaction across the external HTTP calls. Always unlocked in
    # an ensure so a mid-sequence raise can't leak the lock.
    def with_instance_advisory_lock
      conn = ::ActiveRecord::Base.connection
      conn.execute("SELECT pg_advisory_lock(#{ADVISORY_LOCK_NAMESPACE}, #{advisory_lock_key})")
      begin
        yield
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_NAMESPACE}, #{advisory_lock_key})")
      end
    end

    # Stable signed-int4 key from the instance id (pg advisory locks take two
    # int4s; map the CRC32 unsigned value into the signed range).
    def advisory_lock_key
      Zlib.crc32(@instance.id.to_s) - 2**31
    end
  end
end
