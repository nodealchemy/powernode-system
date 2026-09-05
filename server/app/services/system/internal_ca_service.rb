# frozen_string_literal: true

require "openssl"
require "ipaddr"
require "socket"
require "securerandom"

module System
  # Issues mTLS certificates for NodeInstances against the platform's
  # internal Certificate Authority. Two adapters:
  #
  # - LocalCaAdapter (test/dev + Vault-less production) : generates an Ed25519
  #   CA on first use and PERSISTS it (root.key 0600, root.crt) under
  #   POWERNODE_CA_LOCAL_DIR so it is stable across process restarts. Selected
  #   when POWERNODE_CA_MODE=local, in non-production, or when Vault is
  #   unconfigured/unavailable (a Vault-less hub mints its own node certs).
  #
  # - VaultCaAdapter (production) : delegates to HashiCorp Vault's PKI
  #   secrets engine via Security::VaultClient. The CA root key never
  #   leaves Vault. Sealing model is whatever the platform's Vault is
  #   configured for (cloud KMS auto-unseal or transit; manual unseals
  #   are explicitly NOT supported per Golden Eclipse Decision 5).
  #
  # Both adapters implement the same surface:
  #   InternalCaService.issue_certificate(csr_pem:, ttl_seconds:, common_name:)
  #     -> { cert_pem:, ca_chain_pem:, serial:, not_before:, not_after: }
  #
  # Reference: Golden Eclipse plan — Security Architecture (Key Custody),
  # M0.N (Vault PKI bootstrap + InternalCaService).
  class InternalCaService
    class CaError < StandardError; end
    class CsrError < CaError; end

    DEFAULT_TTL_SECONDS = 90 * 24 * 3600 # 90 days

    # Fully-qualified audit-action tokens this service emits. Registered
    # into AuditActions.all_actions by the system engine initializer
    # (single source of truth, mirrors
    # System::LifecycleAuditable::AUDITED_ACTIONS).
    AUDITED_ACTIONS = %w[
      system.internal_ca.issue
      system.internal_ca.revoke
    ].freeze

    class << self
      def adapter
        @adapter ||= build_adapter
      end

      # Test seam: lets specs swap the adapter (and reset between examples).
      def adapter=(replacement)
        @adapter = replacement
      end

      def reset!
        @adapter = nil
      end

      # Operator-facing preflight that verifies the configured adapter can
      # actually issue certificates before any caller tries. Returns
      #   { status: :ok | :error, message: String, details: Hash }
      # so operators / bootstrap tooling can fail fast with an actionable
      # error rather than discovering misconfiguration on first issue.
      # See Golden Eclipse plan M0.N + project_vault_pki_state for the
      # production Vault PKI bootstrap context.
      def preflight_check
        adapter.preflight_check
      rescue StandardError => e
        {
          status: :error,
          message: "InternalCaService.preflight_check raised #{e.class}: #{e.message}",
          details: { adapter: adapter.class.name }
        }
      end

      # sans: optional Subject Alternative Names for SERVER certs (e.g. a
      # localhost/overlay serving cert). Go (and modern TLS stacks) require a
      # SAN match — CN alone no longer satisfies verification — so any cert a
      # daemon will verify by hostname/IP must carry them. Node CLIENT certs
      # (CN = instance id) don't need SANs and pass [] (the default).
      def issue_certificate(csr_pem:, ttl_seconds: DEFAULT_TTL_SECONDS, common_name: nil, sans: [])
        result = adapter.issue_certificate(
          csr_pem: csr_pem,
          ttl_seconds: ttl_seconds,
          common_name: common_name,
          sans: sans
        )
        emit_audit_event!(
          event_type: "system.internal_ca.issue",
          serial: result[:serial],
          common_name: common_name,
          ttl_seconds: ttl_seconds
        )
        result
      end

      def ca_chain_pem
        adapter.ca_chain_pem
      end

      # SHA-256 fingerprint of the ISSUING CA — "who signs here". The value an
      # operator should compare when asking "is this the same CA?", and the one
      # federation diagnostics quote. A subject DN cannot answer that question:
      # hubs provisioned before hub-specific subjects all present the identical
      # "CN=Powernode Internal CA (local-dev)" over different keys.
      #
      # On a flat (anchor-only) deployment this EQUALS #anchor_fingerprint.
      # Under a hierarchy they diverge, and the distinction matters: this one
      # answers "who signed this leaf", the other "which tree is this".
      def ca_fingerprint
        adapter.ca_fingerprint
      end

      # SHA-256 fingerprint of the TERMINAL self-signed cert in our chain —
      # "which tree". This is the value two hubs compare to decide whether they
      # belong to the same tree; #ca_fingerprint cannot answer that once
      # intermediates exist, because siblings have different issuing CAs and the
      # SAME anchor.
      def anchor_fingerprint
        adapter.anchor_fingerprint
      end

      # Parsed certs, for callers that need the object rather than the PEM.
      # These replace the deleted #root_cert, which took the FIRST cert of
      # ca_chain_pem — an assumption that silently changes referent the moment
      # the chain has more than one element.
      def issuing_cert
        adapter.issuing_cert
      end

      def anchor_cert
        adapter.anchor_cert
      end

      # Audit plan P1.4 — surface adapter#revoke through the service. LocalCaAdapter
      # returns a no-op `{ ok: true, mode: "local-noop" }`; VaultCaAdapter actually
      # POSTs to `<pki_int>/revoke`. Audit log entry recorded for both paths.
      def revoke_certificate(serial:)
        raise ArgumentError, "serial is required" if serial.to_s.strip.empty?

        result = adapter.revoke(serial: serial)
        emit_audit_event!(
          event_type: "system.internal_ca.revoke",
          serial: serial,
          common_name: nil,
          ttl_seconds: nil
        )
        result
      end

      private

      # Crypto-safety rule: log only the SERIAL + COMMON_NAME + TTL.
      # NEVER include the cert_pem, key, or CSR contents in audit log
      # metadata — they're not needed for audit and risk leaking material.
      def emit_audit_event!(event_type:, serial:, common_name:, ttl_seconds:)
        return unless defined?(::AuditLog)
        ::AuditLog.create!(
          account: audit_account,
          action: event_type,
          resource_type: "InternalCaCertificate",
          resource_id: serial.to_s,
          source: "system",
          metadata: {
            adapter: adapter.class.name,
            common_name: common_name,
            ttl_seconds: ttl_seconds
          }.compact
        )
      rescue StandardError => e
        Rails.logger.warn("[InternalCaService] audit log emit failed: #{e.class}: #{e.message}")
      end

      # InternalCaService is a platform-wide singleton (one CA per install,
      # not per-account), so there's no account to thread through
      # issue_certificate/revoke_certificate — mirrors AuditLog.log_system_event's
      # fallback-account resolution.
      def audit_account
        ::Account.find_by(name: "System") || ::Account.first
      end

      public

      private

      def build_adapter
        mode = ENV["POWERNODE_CA_MODE"].presence || resolve_default_mode
        case mode
        when "vault"
          VaultCaAdapter.new
        when "local"
          LocalCaAdapter.new
        else
          raise CaError, "Unknown POWERNODE_CA_MODE: #{mode.inspect} (expected 'vault' or 'local')"
        end
      end

      # Adapter chosen when POWERNODE_CA_MODE is unset. Non-production keeps the
      # local adapter (no Vault dependency). Production PREFERS Vault, but only
      # when it is genuinely configured + reachable — a Vault-less hub (no Vault
      # deployment) auto-selects the local adapter so it can still mint node
      # mTLS certs from its own on-disk CA instead of 500ing on first issue with
      # a Vault error. An explicit POWERNODE_CA_MODE always overrides this.
      #
      # CAVEAT: vault_usable? is a live probe, so a Vault-BACKED deployment that
      # leaves POWERNODE_CA_MODE unset could transiently flip to the local
      # adapter during a Vault outage (minting certs from a different CA). A
      # deployment committed to Vault should set POWERNODE_CA_MODE=vault
      # EXPLICITLY so an outage surfaces as a clear error rather than a silent
      # CA switch. (A Vault-less hub like ops-hub is unaffected — always local.)
      def resolve_default_mode
        return "local" unless Rails.env.production?

        vault_usable? ? "vault" : "local"
      end

      # Fail-closed Vault probe: ANY inability to confirm a healthy, reachable
      # Vault resolves to "not usable" so we fall back to local rather than
      # raise. Uses the core class-level Security::VaultClient.healthy? (an
      # extension may depend on core security). That predicate is fail-closed
      # once fix/vault-unconfigured-failsafe lands; the rescue keeps an
      # unconfigured-Vault raise on current code resolving to false as well.
      def vault_usable?
        return false unless defined?(::Security::VaultClient)

        ::Security::VaultClient.healthy?
      rescue StandardError => e
        Rails.logger.warn("[InternalCaService] Vault probe failed; defaulting to local CA: #{e.class}: #{e.message}") if defined?(Rails)
        false
      end
    end

    # ----------------------------------------------------------------------
    # Local CA adapter (on-disk persisted; test/dev + Vault-less production)
    # ----------------------------------------------------------------------
    class LocalCaAdapter
      attr_reader :ca_cert, :ca_key, :ca_chain

      # On-disk persistence path. Without persistence, each rails-runner /
      # rails-server / rake-task process generates its own CA — so a cert
      # minted in one process can't be verified by a Traefik that loaded
      # the CA from a different process. Persistence makes the local CA
      # behave like a real CA: stable across process restarts. Operator-
      # overridable via POWERNODE_CA_LOCAL_DIR. Default lives under the
      # platform's storage tree so it's not lost on /tmp cleanup.
      DEFAULT_PERSIST_DIR = "/var/lib/powernode/internal-ca"

      # Subject components for a NEWLY generated root. The old value —
      # "/CN=Powernode Internal CA (local-dev)" — was both hub-agnostic AND
      # misleading on deployed hubs (the local adapter is the normal posture
      # for any Vault-less hub, not a dev-only fallback).
      CA_SUBJECT_ORG       = "Powernode"
      CA_SUBJECT_CN_PREFIX = "Powernode Internal CA"

      # v2 on-disk layout (§3). A CA generation is an IMMUTABLE version dir;
      # `live` is a symlink naming the current one. Readers resolve the symlink
      # ONCE and open every file through the resolved dir, so a reader can never
      # straddle a flip and see one generation's key beside another's cert.
      #
      #   <persist_dir>/
      #     live -> versions/<id>      symlink, flipped atomically
      #     versions/<id>/ca.key       0600  this CA's private key
      #     versions/<id>/ca.crt       0644  this CA's certificate
      #     versions/<id>/chain.crt    0644  ca.crt + ancestors, anchor last
      #     .lock                      flock target; writers only
      #
      # The v1 layout (root.key/root.crt at the top level) is still READ — see
      # #load_legacy_pair. It is deleted in the final increment, after the §11
      # cutover, not here: refusing it now would de-authenticate every existing
      # deployment on the increment advertised as additive (§15.1).
      LIVE_LINK    = "live"
      VERSIONS_DIR = "versions"
      LOCK_FILE    = ".lock"

      def initialize
        @persist_dir = ENV.fetch("POWERNODE_CA_LOCAL_DIR", DEFAULT_PERSIST_DIR)
        load_or_create_ca
      end

      # Loads the live CA, or generates an anchor when the store is genuinely
      # empty. Never rewrites existing material — every worker, agent, node and
      # federation cert on a running hub chains to it, so re-minting would
      # de-authenticate the fleet. Adopting a new subject or key on a
      # provisioned hub is a deliberate CA ROTATION (§10), not this method.
      #
      # Retry-once (F-6): a reader that resolves `live` while a writer flips it
      # can read a stale target that vanishes mid-read. That is transient, so
      # re-resolve once before concluding the store is damaged. A SECOND
      # failure is real and fails closed.
      def load_or_create_ca
        attempts = 0
        begin
          attempts += 1
          return if load_live
          return if load_legacy_pair

          generate_anchor!
        rescue Errno::ENOENT, Errno::ESTALE => e
          retry if attempts < 2
          raise CaError, "internal CA store unreadable at #{@persist_dir}: #{e.class}: #{e.message}"
        end
      end

      private

      # Resolves `live` ONCE (§3.1 F-6) and reads the generation through the
      # resolved path, so every file comes from the same version dir even if a
      # flip lands mid-load. Returns false when there is no live generation.
      def load_live(dir: @persist_dir)
        link = File.join(dir, LIVE_LINK)
        return false unless File.symlink?(link)

        version_dir = File.expand_path(File.readlink(link), dir)
        key_pem  = File.read(File.join(version_dir, "ca.key"))
        cert_pem = File.read(File.join(version_dir, "ca.crt"))
        chain_path = File.join(version_dir, "chain.crt")
        chain_pem  = File.exist?(chain_path) ? File.read(chain_path) : cert_pem

        adopt!(key_pem: key_pem, cert_pem: cert_pem, chain_pem: chain_pem, source: version_dir)
        true
      end

      # v1 compatibility read, retained for this increment only (see the layout
      # comment above). A v1 store is by construction depth-1: its chain is the
      # single self-signed root, so issuing and anchor coincide.
      def load_legacy_pair(dir: @persist_dir)
        key_path  = File.join(dir, "root.key")
        cert_path = File.join(dir, "root.crt")
        key_present  = File.exist?(key_path)
        cert_present = File.exist?(cert_path)

        if key_present && cert_present
          cert_pem = File.read(cert_path)
          adopt!(key_pem: File.read(key_path), cert_pem: cert_pem,
                 chain_pem: cert_pem, source: dir)
          return true
        end

        # A HALF-PRESENT pair is a damaged restore, never a "mint a fresh root"
        # signal: generating would overwrite the survivor and de-authenticate
        # everything chained to it. DAMAGED — refuse and make an operator look.
        if key_present || cert_present
          present, missing = key_present ? [ key_path, cert_path ] : [ cert_path, key_path ]
          raise CaError,
                "refusing to generate a new internal CA: #{present} exists but #{missing} is missing. " \
                "Generating would overwrite the surviving half of an existing CA and de-authenticate " \
                "every certificate chained to it. Restore the missing file, or move the whole " \
                "directory aside deliberately if a NEW CA is genuinely intended."
        end

        false
      end

      # Installs a loaded generation after asserting the key and cert are a
      # PAIR (§3.1). A mismatch means the store is DAMAGED: signing with a key
      # whose certificate advertises a different public key produces
      # certificates that verify nowhere, so refuse service instead. This is
      # reachable from an interrupted hand-restore or a partially-copied dir.
      def adopt!(key_pem:, cert_pem:, chain_pem:, source:)
        key  = OpenSSL::PKey.read(key_pem)
        cert = OpenSSL::X509::Certificate.new(cert_pem)

        unless cert.check_private_key(key)
          raise CaError,
                "internal CA store at #{source} is DAMAGED: ca.key does not match ca.crt " \
                "(the certificate advertises a different public key). Certificates signed " \
                "with this pair would verify nowhere. Restore a consistent generation."
        end

        @ca_key   = key
        @ca_cert  = cert
        @ca_chain = parse_chain(chain_pem, fallback: cert)
      end

      # Chain order is issuing-first, anchor-last (§4.1). An unparseable or
      # empty chain file degrades to the issuing cert alone rather than failing
      # the load: the pair itself already verified, and a depth-1 chain is the
      # correct degenerate answer for an anchor.
      def parse_chain(chain_pem, fallback:)
        certs = chain_pem.to_s.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
                         .filter_map do |block|
          begin
            OpenSSL::X509::Certificate.new(block)
          rescue OpenSSL::X509::CertificateError
            nil
          end
        end
        certs.empty? ? [ fallback ] : certs
      end

      # Generates this deployment's own anchor. Serialized under flock and
      # RE-CHECKED after acquiring it (§3.1) — without the re-check, two
      # processes that both observed an empty store would each mint a root and
      # the loser's issued certs would verify nowhere.
      #
      # Persistence is NO LONGER best-effort. The previous code logged a warning
      # and kept an in-memory CA, which on an unwritable dir gave every process
      # its own silently-ephemeral root — certs that verify nowhere and a fleet
      # that fails in a way nothing reports. Losing issuance loudly is the
      # correct failure (§15.1 row 1).
      def generate_anchor!
        with_lock do
          return if load_live
          return if load_legacy_pair
          return if adopt_legacy_store!

          key   = OpenSSL::PKey.generate_key("ED25519")
          cert  = build_self_signed_root(key)
          write_generation!(key: key, cert: cert, chain: [ cert ])
          adopt!(key_pem: key.private_to_pem, cert_pem: cert.to_pem,
                 chain_pem: cert.to_pem, source: @persist_dir)
        end
      end

      # One-time adoption of a CA store left behind at DEFAULT_PERSIST_DIR by a
      # revision that ran before POWERNODE_CA_LOCAL_DIR pointed elsewhere.
      #
      # WHY THIS EXISTS. Moving the store's path does not move the store. Without
      # adoption, the first adapter built after the path changes finds an empty
      # dir and mints a NEW anchor -- silently de-authenticating every cert
      # chained to the old one, which is the precise outcome generate_anchor!'s
      # half-pair guard exists to prevent. That guard cannot help here: it
      # inspects the CURRENT dir, and the old store is somewhere else entirely.
      #
      # WHY IN THE SERVICE AND NOT IN rails-start.sh. A shell `mv` was the
      # obvious fix and is the wrong one. Across filesystems (/var/lib -> /persist)
      # mv is copy+unlink in readdir order, so it can copy versions/ and die
      # before `live` -- leaving a store that load_live rejects, load_legacy_pair
      # cannot see (it only knows the v1 root.key/root.crt names), and
      # generate_anchor! therefore mints straight over. Doing it here inherits
      # three properties bash would have to reimplement badly:
      #   - atomicity: write_generation! fsyncs then flips `live` by rename(2),
      #     so the destination is never partially valid;
      #   - single-writer discipline: we are already inside with_lock, the same
      #     flock every writer takes, so a concurrent out-of-band process cannot
      #     observe a half-migrated store;
      #   - validation: the material goes through adopt!'s check_private_key, so
      #     a damaged old store fails CLOSED instead of being copied faithfully.
      # It also covers EVERY consumer -- a `rails runner` that resolves the
      # default path benefits too, not just puma's process tree.
      #
      # The source is deliberately LEFT IN PLACE. An import that deletes what it
      # read turns any latent bug in this method into unrecoverable key loss;
      # reclaiming the old directory is a separate, later decision.
      #
      # Returns true when a legacy store was adopted and re-persisted here.
      def adopt_legacy_store!
        return false if @persist_dir == DEFAULT_PERSIST_DIR
        # Reading the old store ADOPTS it into memory (both readers call adopt!),
        # so a successful read leaves @ca_key/@ca_cert/@ca_chain populated and a
        # half-pair over there raises rather than returning false.
        return false unless load_live(dir: DEFAULT_PERSIST_DIR) ||
                            load_legacy_pair(dir: DEFAULT_PERSIST_DIR)

        Rails.logger.warn(
          "[InternalCaService] adopting the internal CA found at #{DEFAULT_PERSIST_DIR} " \
          "into #{@persist_dir}; the source is left in place"
        ) if defined?(Rails)

        write_generation!(key: @ca_key, cert: @ca_cert, chain: @ca_chain)
        true
      rescue Errno::ENOENT, Errno::ESTALE => e
        # Without this, the error escapes to load_or_create_ca's handler, which
        # names @persist_dir -- pointing the operator at the NEW directory while
        # the damage is at the legacy one. Its retry-once is also useless here:
        # it exists for a live-flip race at the ACTIVE store, not a persistently
        # broken directory we are importing from.
        #
        # Fail CLOSED, deliberately: a legacy store we cannot read is EVIDENCE a
        # CA existed, so minting over it would de-authenticate whatever it
        # signed. This is a new way for issuance to stop (previously the old dir
        # was simply ignored) and that is the correct trade -- but the message
        # must name the directory an operator has to go look at.
        raise CaError,
              "internal CA store at #{DEFAULT_PERSIST_DIR} is unreadable (#{e.class}: #{e.message}), " \
              "so it cannot be adopted into #{@persist_dir}. Refusing to mint a new anchor over an " \
              "existing CA: certificates chained to it would stop verifying. Repair that directory, " \
              "or move it aside deliberately if a NEW CA is genuinely intended."
      end

      # Assembles an immutable version dir and flips `live` onto it atomically.
      # Every file is fsynced, then the version dir, then — after the rename —
      # the PARENT dir (F6: rename durability across power loss is otherwise
      # not guaranteed). A crash at any point leaves either the old live intact
      # or the new one complete; no partial generation is ever live.
      def write_generation!(key:, cert:, chain:)
        versions = File.join(@persist_dir, VERSIONS_DIR)
        FileUtils.mkdir_p(versions, mode: 0o700)
        version_dir = File.join(versions, SecureRandom.uuid)
        FileUtils.mkdir_p(version_dir, mode: 0o700)

        write_synced(File.join(version_dir, "ca.key"),    key.private_to_pem,      0o600)
        write_synced(File.join(version_dir, "ca.crt"),    cert.to_pem,             0o644)
        write_synced(File.join(version_dir, "chain.crt"), chain.map(&:to_pem).join, 0o644)
        fsync_dir(version_dir)

        # Atomic flip: rename(2) over an existing symlink replaces it in one step.
        tmp_link = File.join(@persist_dir, ".#{LIVE_LINK}.#{SecureRandom.hex(8)}")
        File.symlink(File.join(VERSIONS_DIR, File.basename(version_dir)), tmp_link)
        File.rename(tmp_link, File.join(@persist_dir, LIVE_LINK))
        fsync_dir(@persist_dir)
      rescue SystemCallError => e
        refuse_unpersistable_store!(e)
      end

      # The ONE refusal for a store this process cannot write. Raised from both
      # places the store is first touched — #with_lock creates the directory
      # and the lock file before #write_generation! ever runs, so an
      # unwritable path used to surface there as a bare Errno with none of
      # the operator guidance below, and only a path that failed LATER (inside
      # the generation write) got the message. Same refusal, whichever call
      # hits the wall first.
      def refuse_unpersistable_store!(error)
        raise CaError,
              "could not persist the internal CA to #{@persist_dir}: #{error.class}: #{error.message}. " \
              "Refusing to continue with an in-memory CA — it would be unique per process and " \
              "every certificate it signed would verify nowhere. Fix the path or set " \
              "POWERNODE_CA_LOCAL_DIR to a writable, DURABLE location (§17)."
      end

      def write_synced(path, contents, perm)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, perm) do |f|
          f.write(contents)
          f.flush
          f.fsync
        end
      end

      # fsync(2) on the DIRECTORY, which is what makes a rename durable across
      # power loss (F6) — syncing the files alone does not.
      #
      # Dir#fsync only exists on Ruby >= 3.3, so open the directory as a file
      # descriptor and fsync that: fsync(2) on a directory fd is exactly what
      # Dir#fsync does, and it works on every POSIX filesystem we run on.
      def fsync_dir(path)
        # RDONLY only: File::DIRECTORY (O_DIRECTORY) is not exposed by this
        # Ruby, and opening a directory read-only is sufficient — fsync(2) on
        # the resulting fd is what Dir#fsync does on 3.3+.
        fd = IO.sysopen(path, File::RDONLY)
        io = IO.for_fd(fd)
        begin
          io.fsync
        ensure
          io.close
        end
      rescue NotImplementedError, SystemCallError, NoMethodError
        # Some filesystems refuse a directory fsync. The file writes already
        # synced, so only rename durability across power loss degrades — §17
        # names durable storage as a precondition rather than something this
        # can repair.
        nil
      end

      # Single-writer discipline (§3.1). Writers only: readers are lockless
      # because version dirs are immutable and `live` resolves in one readlink.
      def with_lock
        begin
          FileUtils.mkdir_p(@persist_dir, mode: 0o700)
          lock = File.open(File.join(@persist_dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600)
        rescue SystemCallError => e
          refuse_unpersistable_store!(e)
        end

        begin
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.close
        end
      end

      public

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil, sans: [])
        csr = begin
          OpenSSL::X509::Request.new(csr_pem)
        rescue OpenSSL::X509::RequestError, ArgumentError, TypeError => e
          raise CsrError, "malformed CSR PEM: #{e.message}"
        end
        raise CsrError, "CSR signature invalid" unless csr.verify(csr.public_key)

        cert = OpenSSL::X509::Certificate.new
        cert.serial = SecureRandom.random_number(2**127)
        cert.version = 2
        cert.not_before = Time.current
        cert.not_after  = Time.current + ttl_seconds
        cert.public_key = csr.public_key
        cert.subject    = subject_for(csr, common_name: common_name)
        cert.issuer     = ca_cert.subject

        ef = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(ef.create_extension("keyUsage", "digitalSignature, keyEncipherment", true))
        # clientAuth: node calls the platform + peers. serverAuth: node also
        # ACCEPTS inbound agent-to-agent (A2A) MCP calls (substrate L2.5), where
        # it presents this same cert as its TLS server cert. (The Vault PKI role
        # used in prod needs server_flag=true for the same reason.)
        cert.add_extension(ef.create_extension("extendedKeyUsage", "clientAuth, serverAuth", false))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        san_value = san_extension_value(sans)
        cert.add_extension(ef.create_extension("subjectAltName", san_value, false)) if san_value
        cert.sign(ca_key, nil) # Ed25519 — no digest (must be nil)

        {
          cert_pem: cert.to_pem,
          ca_chain_pem: ca_cert.to_pem,
          serial: cert.serial.to_s(16),
          not_before: cert.not_before,
          not_after:  cert.not_after,
          subject:    cert.subject.to_s
        }
      end

      # Issuing-first, anchor-last (§4.1). One cert for an anchor deployment,
      # which is byte-identical to what v1 returned — the degenerate case, not
      # a special case.
      def ca_chain_pem
        ca_chain.map(&:to_pem).join
      end

      # The cert this CA signs with.
      def issuing_cert
        ca_cert
      end

      # The terminal self-signed cert — the tree's root of trust. Equals
      # #issuing_cert on a flat deployment.
      def anchor_cert
        ca_chain.last || ca_cert
      end

      # THE identity of this CA. The subject is a label the CA names itself;
      # only the fingerprint distinguishes two CAs (and every hub provisioned
      # before hub-specific subjects landed still shares one DN with every
      # other such hub).
      def ca_fingerprint
        ::Security::CaFingerprint.of(issuing_cert)
      end

      # "Which tree" — the value two hubs compare to decide whether they share
      # a root of trust. Diverges from #ca_fingerprint only under a hierarchy.
      def anchor_fingerprint
        ::Security::CaFingerprint.of(anchor_cert)
      end

      def preflight_check
        {
          status: :ok,
          message: "LocalCaAdapter active. On-disk CA persisted at #{@persist_dir}.",
          details: {
            adapter: "local",
            persist_dir: @persist_dir,
            subject: ca_cert.subject.to_s,
            fingerprint: ca_fingerprint,
            not_after: ca_cert.not_after.iso8601
          }
        }
      end

      # No-op revocation for the in-memory adapter. The local CA has no
      # CRL/OCSP responder — issued certs simply remain valid until their
      # not_after. Returns a structured result for parity with VaultCaAdapter.
      def revoke(serial:)
        { ok: true, mode: "local-noop", serial: serial }
      end

      private

      def build_self_signed_root(key)
        cert = OpenSSL::X509::Certificate.new
        cert.serial = 1
        cert.version = 2
        cert.not_before = Time.current
        cert.not_after  = Time.current + (10 * 365 * 24 * 3600) # 10 years
        cert.public_key = key
        cert.subject    = new_root_subject
        cert.issuer     = cert.subject # self-signed

        ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.sign(key, nil)
        cert
      end

      # Subject stamped on a NEWLY GENERATED root. Never applied to a root
      # already on disk — load_or_create_root returns an existing root
      # untouched, because rewriting a live CA's subject invalidates every
      # worker/agent/node cert chaining to it (see the class comment).
      #
      # Every hub used to mint "/CN=Powernode Internal CA (local-dev)", so
      # separately-generated roots were indistinguishable BY NAME while having
      # different keys. That is not cosmetic: OpenSSL resolves a leaf's issuer
      # by subject DN, so two same-named roots in one federated client-auth
      # bundle collide and the second one's leaves are rejected outright.
      # A hub-specific subject makes the collision structurally impossible for
      # new CAs; Security::CaFingerprint remains the identity of record.
      def new_root_subject
        OpenSSL::X509::Name.new(
          [ [ "O",  CA_SUBJECT_ORG,                                  OpenSSL::ASN1::UTF8STRING ],
            [ "OU", ca_instance_token,                               OpenSSL::ASN1::UTF8STRING ],
            [ "CN", "#{CA_SUBJECT_CN_PREFIX} #{ca_host_identity}",   OpenSSL::ASN1::UTF8STRING ] ]
        )
      end

      # The hub's own name, as peers address it. Deliberately drawn from
      # process-level sources ONLY: the local CA is generated lazily on first
      # `InternalCaService.adapter` — which happens from rake tasks, the
      # reverse-proxy writer and boot-time config paths — so a DB-backed
      # identifier is not dependably reachable that early. Specifically NOT
      # used, and why:
      #   - NodeInstance id: a hub has no "self" NodeInstance row; the closest
      #     thing (SiteSetting system.self_hosting_node_id) is DB-backed AND
      #     unset by default (SelfManagementFence's inert default).
      #   - Account id: the CA is a platform-wide singleton, not per-account
      #     (see #audit_account) — there is no one account to name.
      # POWERNODE_INGRESS_HOST is the same value Core::IngressConfigWriter
      # already treats as this hub's identity, so the CA name matches the name
      # peers reach us by.
      def ca_host_identity
        raw = ENV["POWERNODE_CA_SUBJECT_HOST"].presence ||
              ENV["POWERNODE_INGRESS_HOST"].presence ||
              hostname ||
              "unidentified-hub"
        sanitize_dn_value(raw)
      end

      # Minted once, at generation, and frozen into the persisted root. Two
      # hubs that genuinely share a hostname (a cloned image, an unset
      # POWERNODE_INGRESS_HOST) would otherwise still collide; this guarantees
      # distinctness without needing any external identifier to be correct.
      def ca_instance_token
        @ca_instance_token ||= SecureRandom.uuid
      end

      def hostname
        Socket.gethostname.presence
      rescue StandardError
        nil
      end

      # A DN travels into logs, TLS acceptable-CA lists and forwarded headers,
      # so keep it to characters that survive all of them, and inside X.509's
      # 64-char upper bound for a CN (prefix included).
      def sanitize_dn_value(raw)
        cleaned = raw.to_s.scrub("-").strip.gsub(/[^A-Za-z0-9._:-]+/, "-").gsub(/\A-+|-+\z/, "")
        cleaned = "unidentified-hub" if cleaned.empty?
        cleaned[0, 64 - CA_SUBJECT_CN_PREFIX.length - 1]
      end

      def subject_for(csr, common_name:)
        return csr.subject unless common_name

        OpenSSL::X509::Name.parse("/CN=#{common_name}")
      end

      # Build an OpenSSL subjectAltName value (e.g. "DNS:localhost,IP:127.0.0.1")
      # from a list of names. Entries that parse as an IP become IP: SANs, the
      # rest DNS:. Returns nil when there are no SANs so the caller skips the
      # extension entirely.
      def san_extension_value(sans)
        entries = Array(sans).map(&:to_s).map(&:strip).reject(&:empty?).uniq
        return nil if entries.empty?

        entries.map { |name| ip_literal?(name) ? "IP:#{name}" : "DNS:#{name}" }.join(",")
      end

      def ip_literal?(name)
        IPAddr.new(name)
        true
      rescue IPAddr::InvalidAddressError, ArgumentError
        false
      end
    end

    # ----------------------------------------------------------------------
    # Vault PKI adapter (production)
    # ----------------------------------------------------------------------
    class VaultCaAdapter
      DEFAULT_PKI_MOUNT = "pki_int"
      DEFAULT_ROLE      = "node"

      # Audit plan P1.4 — accepts an optional pki_client kwarg so smoke
      # tests can inject a Security::VaultPkiClient pointing at a dev
      # vault without authenticating through Security::VaultClient's
      # AppRole login flow. Production callers leave it nil and get the
      # default client (which reads VAULT_ADDR + VAULT_TOKEN from env).
      def initialize(mount: nil, role: nil, pki_client: nil)
        @mount = mount || ENV.fetch("POWERNODE_PKI_MOUNT", DEFAULT_PKI_MOUNT)
        @role  = role  || ENV.fetch("POWERNODE_PKI_ROLE", DEFAULT_ROLE)
        @pki   = pki_client || ::Security::VaultPkiClient.new(mount: @mount, role: @role)
      end

      def issue_certificate(csr_pem:, ttl_seconds:, common_name: nil, sans: [])
        data = @pki.sign(csr_pem: csr_pem, ttl_seconds: ttl_seconds, common_name: common_name, sans: sans)

        # ca_chain_pem can be either a single ca cert or full chain;
        # join multi-element chains into one PEM stream for callers.
        chain_pems = Array(data[:ca_chain])
        chain_pems << data[:issuing_ca] if chain_pems.empty? && data[:issuing_ca]

        {
          cert_pem:     data[:certificate],
          ca_chain_pem: chain_pems.compact.join("\n"),
          serial:       data[:serial_number],
          not_before:   nil, # Vault doesn't return — caller parses the PEM if needed
          not_after:    data[:expiration] ? Time.at(data[:expiration].to_i) : nil,
          subject:      common_name
        }
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI sign failed: #{e.message}"
      end

      def ca_chain_pem
        @pki.root_certificate_pem
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI ca_chain fetch failed: #{e.message}"
      end

      # Parity with LocalCaAdapter#ca_fingerprint so callers never have to ask
      # which adapter is live before they can identify the CA.
      def ca_fingerprint
        ::Security::CaFingerprint.of(issuing_cert)
      end

      # Parity surface for the §4.1 contract. HONEST LIMITATION: this adapter's
      # #ca_chain_pem calls Vault's `/ca/pem`, which returns the mount's OWN
      # certificate — one cert, not a chain (the client's comment overclaims it;
      # the endpoint does not). So on a Vault-backed SUBORDINATE these three
      # currently describe the intermediate, and #anchor_fingerprint would
      # answer "which tree" with the intermediate's fingerprint — wrong.
      #
      # That is correct-and-equal at depth 1, which is every Vault deployment
      # today, and it is why §1.1 lists a chain-aware fetch
      # (`/cert/ca_chain`) as required work. Deliberately NOT faked here:
      # returning the mount cert while claiming it is the anchor is the failure
      # this comment exists to prevent. The Vault arm lands with the new
      # VaultPkiClient verbs and is labelled offline-UNPROVEN until then (§15).
      def issuing_cert
        chain_certs.first || raise(CaError, "Vault PKI returned no parseable CA certificate")
      end

      def anchor_cert
        chain_certs.last || issuing_cert
      end

      def anchor_fingerprint
        ::Security::CaFingerprint.of(anchor_cert)
      end

      # Parses whatever #ca_chain_pem returned into certs, order preserved.
      def chain_certs
        ca_chain_pem.to_s.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
                    .filter_map do |block|
          begin
            ::OpenSSL::X509::Certificate.new(block)
          rescue ::OpenSSL::X509::CertificateError
            nil
          end
        end
      end

      # Audit plan P1.4 — revoke a previously-issued cert by serial.
      # Returns the revocation_time epoch + RFC3339 form per Vault response.
      # Idempotent: revoking an already-revoked serial returns the original
      # revocation_time without erroring.
      def revoke(serial:)
        result = @pki.revoke(serial_number: serial)
        { ok: true,
          serial: serial,
          revocation_time: result[:revocation_time],
          revocation_time_rfc3339: result[:revocation_time_rfc3339] }
      rescue ::Security::VaultPkiClient::PkiError => e
        raise CaError, "Vault PKI revoke failed: #{e.message}"
      end

      # Probes the configured PKI role to verify Vault is reachable AND
      # the PKI engine is mounted AND the issuing role exists. Specific
      # error classes drive specific operator messaging so failure mode
      # (network vs mount vs role) is visible without enabling debug logs.
      def preflight_check
        @pki.role_config
        {
          status: :ok,
          message: "VaultCaAdapter active. PKI mount '#{@mount}' role '#{@role}' is reachable.",
          details: { adapter: "vault", mount: @mount, role: @role }
        }
      rescue ::Security::VaultPkiClient::PkiError => e
        {
          status: :error,
          message: "Vault PKI preflight failed: #{e.message}. " \
                   "Bootstrap the PKI engine + role, or override via " \
                   "POWERNODE_PKI_MOUNT / POWERNODE_PKI_ROLE. " \
                   "To run without Vault, set POWERNODE_CA_MODE=local.",
          details: { adapter: "vault", mount: @mount, role: @role }
        }
      end
    end
  end
end
