# frozen_string_literal: true

require "open3"

module System
  module Gitops
    # IMP-1e5db5e6aefb — the git host's SSH PUBLIC key(s) a GitopsRepository
    # is verified against, stored on GitopsRepository#ssh_host_keys in the
    # same document shape as NodeInstance#ssh_host_keys:
    #
    #   { "keys" => [{ "type", "key", "fingerprint" }],
    #     "recorded_at" => iso8601, "source" => "explicit" | "keyscan" | "tofu" }
    #
    # System::SshHostKeys is the one validator, on the way in (an operator's
    # explicit value, ssh-keyscan's stdout) and on the way out (.recorded_for,
    # which every known_hosts render reads). Nothing here trusts raw text.
    #
    # Sources: "explicit" is a key the operator supplied at registration or
    # update; "keyscan" is a scan performed at registration; "tofu" is a scan
    # the sync itself performed because nothing was recorded (trust on first
    # use), announced by RECORDED_EVENT_KIND. The sync NEVER replaces a
    # recorded key: a host presenting a different one fails the sync
    # (RepoSyncService::HostKeyMismatchError, MISMATCH_EVENT_KIND) until an
    # operator records the new key explicitly.
    #
    # Public keys and fingerprints only. Nothing here reads, accepts, logs or
    # emits private material; a private-key-shaped value fails normalization
    # and its content is never echoed.
    module RepositoryHostKey
      # Raised for an explicit value that is not a valid public host key line.
      # The message describes the expected shape only, never the value.
      class InvalidHostKey < StandardError; end
      # Raised by .scan when the ssh-keyscan binary itself is missing: a hub
      # deploy defect, distinct from a host that answered with no key.
      class ScannerUnavailable < StandardError; end

      # HostKeyAlias for the sync's known_hosts. Keyed on the repository, not
      # the host: it is port- and IPv6-safe under SshHostKeys::ALIAS_FORMAT,
      # a URL respelling keeps the recorded key, and ssh names it in its
      # strict-checking stderr, which is how a mismatch is attributed to THIS
      # connection (mirrors SshExecutionService::HOST_KEY_ALIAS_PREFIX).
      HOST_KEY_ALIAS_PREFIX = "powernode-gitops-repository-"

      RECORDED_EVENT_KIND = "system.gitops.host_key_recorded"
      MISMATCH_EVENT_KIND = "system.gitops.host_key_mismatch"
      EVENT_SOURCE        = "system/gitops/repo_sync_service"
      # One mismatch event per repository per window; the sync retries every
      # five minutes and the condition persists until an operator acts.
      MISMATCH_EVENT_WINDOW = 15.minutes

      SOURCES = %w[explicit keyscan tofu].freeze

      # ssh-keyscan's per-connection timeout. Short and fixed: the scan runs
      # inline in a registration request or a reconcile tick.
      KEYSCAN_TIMEOUT_SECONDS = 5

      module_function

      def alias_for(repository)
        "#{HOST_KEY_ALIAS_PREFIX}#{repository.id}"
      end

      # The repository's recorded keys, re-validated. [] when none.
      def recorded_for(repository)
        ::System::SshHostKeys.recorded_for(repository)
      end

      # Whether a record EXISTS: a document holding at least one entry,
      # validated or not. This, not recorded_for's emptiness, is what the
      # sync keys trust-on-first-use on — a present record that no longer
      # validates must refuse, never be scanned over.
      def recorded?(repository)
        document = repository.ssh_host_keys
        document.is_a?(Hash) && document["keys"].is_a?(Array) && document["keys"].any?
      end

      def fingerprints_for(repository)
        ::System::SshHostKeys.fingerprints(recorded_for(repository))
      end

      # Validated entries from an operator-supplied value: one or more lines
      # of "<type> <key> [comment]" or known_hosts-style "<host> <type> <key>
      # [comment]" (what ssh-keyscan prints). EVERY line must normalize, or the
      # whole value is refused: a partially trusted value is how a marker line
      # (`@cert-authority *`) would ride in behind a valid key.
      def parse_explicit(value)
        raise InvalidHostKey, invalid_message unless value.is_a?(String)

        lines = value.lines.map(&:strip).reject(&:empty?)
        raise InvalidHostKey, invalid_message if lines.empty?

        entries = lines.map { |line| entry_from_line(line) }
        raise InvalidHostKey, invalid_message if entries.any?(&:nil?)

        normalized = ::System::SshHostKeys.normalize_all(entries)
        raise InvalidHostKey, invalid_message if normalized.size != entries.uniq { |e| e["key"] }.size

        normalized
      end

      # Validated entries from a live `ssh-keyscan` of host:port. Array-form
      # Open3 (no shell), bounded timeout, stdout only (the banner goes to
      # stderr). [] on any host-side failure, never raising for those: the
      # caller decides whether an empty scan is fatal (the sync refuses;
      # registration leaves the key unrecorded for the sync to pin on first
      # use). A MISSING ssh-keyscan binary is the one exception — it raises
      # ScannerUnavailable, because "not installed on this host" and "the
      # host returned no key" call for different operators.
      def scan(host:, port:)
        out, _err, status = ::Open3.capture3(
          "ssh-keyscan", "-T", KEYSCAN_TIMEOUT_SECONDS.to_s, "-p", port.to_i.to_s, host.to_s
        )
        return [] unless status.success?

        entries = out.to_s.each_line.filter_map do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          entry_from_line(line)
        end
        ::System::SshHostKeys.normalize_all(entries)
      rescue Errno::ENOENT
        Rails.logger.error("[Gitops::RepositoryHostKey] ssh-keyscan is not installed on this host (Errno::ENOENT)")
        raise ScannerUnavailable, "ssh-keyscan is not installed on this host (Errno::ENOENT); " \
                                  "install openssh-client, or record the host key on the repository (ssh_host_key)"
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepositoryHostKey] ssh-keyscan #{host}:#{port} failed: #{e.class}: #{e.message}")
        []
      end

      # Scan the repository's own remote. [] for a non-ssh URL. Propagates
      # ScannerUnavailable.
      def scan_for(repository)
        endpoint = ::System::Gitops::SshRemote.parse(repository.repo_url)
        return [] unless endpoint

        scan(host: endpoint.host, port: endpoint.port)
      end

      def document(entries, source:)
        raise ArgumentError, "unknown host key source #{source.inspect}" unless SOURCES.include?(source)

        {
          "keys" => ::System::SshHostKeys.normalize_all(entries),
          "recorded_at" => Time.current.utc.iso8601,
          "source" => source
        }
      end

      # Persists without validations or callbacks: the sync's trust-on-first-use
      # write must not depend on unrelated model state.
      def record!(repository, entries, source:)
        repository.update_columns(ssh_host_keys: document(entries, source: source))
      end

      # Registration: an explicit value wins and is validated here (raises
      # InvalidHostKey); otherwise an ssh remote is scanned. Assigns on the
      # (unsaved) record; the caller saves. Returns the entries recorded.
      def assign_for_registration!(repository, explicit: nil)
        if explicit.present?
          entries = parse_explicit(explicit)
          repository.ssh_host_keys = document(entries, source: "explicit")
          return entries
        end

        return [] unless ::System::Gitops::SshRemote.ssh?(repository.repo_url)

        entries = scan_for(repository)
        repository.ssh_host_keys = document(entries, source: "keyscan") if entries.any?
        entries
      rescue ScannerUnavailable => e
        # Registration's scan is best-effort by design (an empty scan leaves
        # the key for the sync to pin); the sync names the missing binary on
        # its first tick. Logged here so the registration is attributable.
        Rails.logger.error("[Gitops::RepositoryHostKey] registration scan skipped for #{repository.name}: #{e.message}")
        []
      end

      def emit_recorded!(repository, entries, source:)
        endpoint = ::System::Gitops::SshRemote.parse(repository.repo_url)
        ::System::Fleet::EventBroadcaster.emit!(
          account: repository.account,
          kind: RECORDED_EVENT_KIND,
          severity: :low,
          payload: {
            repository_id: repository.id,
            source: source,
            host: endpoint&.host,
            port: endpoint&.port,
            fingerprints: ::System::SshHostKeys.fingerprints(entries),
            key_types: entries.map { |entry| entry["type"] }
          },
          source: EVENT_SOURCE
        )
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepositoryHostKey] recorded event failed for #{repository.id}: #{e.class}")
      end

      # Fingerprints only, never a key blob. Rate-limited per repository.
      def emit_mismatch!(repository, entries)
        return unless Rails.cache.write("system:gitops_host_key_mismatch:#{repository.id}", true,
                                        unless_exist: true, expires_in: MISMATCH_EVENT_WINDOW)

        endpoint = ::System::Gitops::SshRemote.parse(repository.repo_url)
        ::System::Fleet::EventBroadcaster.emit!(
          account: repository.account,
          kind: MISMATCH_EVENT_KIND,
          severity: :high,
          payload: {
            repository_id: repository.id,
            host: endpoint&.host,
            port: endpoint&.port,
            recorded_fingerprints: ::System::SshHostKeys.fingerprints(entries)
          },
          source: EVENT_SOURCE
        )
      rescue StandardError => e
        Rails.logger.warn("[Gitops::RepositoryHostKey] mismatch event failed for #{repository.id}: #{e.class}")
      end

      # "<type> <key> ..." or "<host> <type> <key> ...". nil when neither.
      def entry_from_line(line)
        fields = line.split(/\s+/)
        type_index = ::System::SshHostKeys::ALLOWED_TYPES.include?(fields[0]) ? 0 : 1
        type = fields[type_index]
        key  = fields[type_index + 1]
        return nil unless type && key
        return nil unless ::System::SshHostKeys::ALLOWED_TYPES.include?(type)

        { "type" => type, "key" => key }
      end

      def invalid_message
        "ssh_host_key is not a valid OpenSSH public host key: expected one or more lines of " \
          "'<type> <base64-key>' (as printed by ssh-keyscan), types #{::System::SshHostKeys::ALLOWED_TYPES.join(', ')}"
      end
    end
  end
end
