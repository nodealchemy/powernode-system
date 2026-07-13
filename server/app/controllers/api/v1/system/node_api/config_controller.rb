# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Instance configuration endpoint
        # Provides instance with its configuration data
        class ConfigController < BaseController
          # Fallback source repo (owner/repo) the dev-cell clones + registers its
          # deploy key on, when no SiteSetting/ENV override is set — configurable,
          # mirroring the PACKAGE_BUILD_DEFAULT_REPO pattern.
          DEV_CELL_SOURCE_REPO_DEFAULT = "powernode/powernode-platform"

          # The NodeModule name whose presence on the calling node marks it a
          # genuine dev-cell. dev_cell_bootstrap is gated to instances actually
          # provisioned with this module — mTLS enrollment alone is NOT enough
          # (otherwise ANY fleet node could self-grant the dev-loop MCP tools +
          # mint a repo-write deploy key).
          DEV_CELL_MODULE_NAME = "dev-cell"

          # The NodeModule name whose presence on the calling node marks it a
          # genuine gitea-act-runner CI builder. ci_runner_registration is
          # gated to instances actually provisioned with this module — same
          # fail-closed shape as DEV_CELL_MODULE_NAME above (otherwise ANY
          # fleet node could self-mint an org-scope Gitea runner
          # registration token).
          CI_RUNNER_MODULE_NAME = "gitea-act-runner"

          # GET /api/v1/system/node_api/config
          # Returns instance configuration
          def show
            render_success(
              instance: serialize_instance,
              node: serialize_node,
              template: serialize_template,
              architecture: serialize_architecture
            )
          end

          # GET /api/v1/system/node_api/config/authorized_keys
          # Returns aggregated SSH authorized keys for the instance plus the
          # unix user whose ~/.ssh/authorized_keys file the on-node agent
          # should manage. Aggregation logic lives on System::Node#authorized_keys
          # so it is testable and reusable from worker dispatch and operator UI.
          def authorized_keys
            keys = current_node.authorized_keys

            render_success(
              authorized_keys: keys.join("\n"),
              keys_count: keys.length,
              target_user: target_admin_user
            )
          end

          # GET /api/v1/system/node_api/config/host_keys
          # Returns SSH host PUBLIC keys for the instance.
          # Note: this returns the public host key; the private host key is never
          # served over the API (an earlier revision incorrectly returned the private
          # key under :default — fixed in Golden Eclipse M0.H).
          def host_keys
            host_keys = {}

            if current_node.ssh_host_public_key.present?
              host_keys[:default] = current_node.ssh_host_public_key
            end

            # Instance-specific host keys (e.g. additional services on the box)
            # are still merged in from the instance config.
            if current_instance.config&.dig("host_keys").present?
              host_keys.merge!(current_instance.config["host_keys"])
            end

            render_success(host_keys: host_keys)
          end

          # GET /api/v1/system/node_api/config/network
          # Returns network configuration for the instance
          def network
            render_success(
              private_ip_address: current_instance.private_ip_address,
              public_ip_address: current_instance.public_ip_address,
              allocate_public_ip: current_node.allocate_public_ip,
              provider_region: serialize_provider_region
            )
          end

          # GET /api/v1/system/node_api/config/claude_code_credential
          #
          # Returns the Claude Code CLI credential (Anthropic API key) for
          # THIS mTLS-authenticated instance — consumed by the claude-tmux /
          # dev-cell NodeModules' boot-time fetch script. Scoped strictly to
          # current_instance (resolved by BaseController#authenticate_instance!
          # from the verified mTLS subject), so one instance can never read
          # another instance's credential.
          #
          # Resolution order:
          #   1. The instance's own System::ClaudeCodeCredential (Vault-backed),
          #      set by an operator via ClaudeCodeCredentialsController.
          #   2. FALLBACK — the account's active Anthropic Ai::Provider
          #      credential. Lets a dev-cell inherit the account's existing
          #      Anthropic *Providers* key instead of requiring a separate
          #      per-instance key for every cell. Resolved + decrypted
          #      server-side and returned over this same mTLS channel.
          # 404 only when neither is configured.
          #
          # IMPORTANT (CryptoMaterialSafety): the plaintext is read from Vault
          # (or the account provider credential's server-side decryption) and
          # returned ONLY in this response body — never logged, never cached,
          # never persisted anywhere else on the platform side.
          def claude_code_credential
            credential = ::System::ClaudeCodeCredential.find_by(node_instance: current_instance)

            if credential
              # Explicit per-instance credential: resolve from Vault. A broken /
              # empty Vault for an explicitly-configured row is a SERVICE error
              # (503) — never silently fall back to the account key for a
              # credential an operator deliberately set.
              plaintext = vault_provider.get_credential(
                credential_type: :claude_code_api_key,
                credential_id: credential.id,
                record: credential
              )
              # VaultCredentialProvider#get_credential returns a SYMBOL-keyed
              # hash ({ api_key:, stored_at: }); accept the string key too for
              # safety. (BUG-M: reading only ["api_key"] returned nil for every
              # correctly-stored per-instance credential → a spurious 503.)
              api_key = plaintext.is_a?(Hash) ? (plaintext[:api_key] || plaintext["api_key"]) : nil
              return render_error("Vault has no credential for this instance", :service_unavailable) if api_key.blank?

              source = "instance"
            else
              # No per-instance credential: fall back to the account's active
              # Anthropic AI provider key so a dev-cell inherits it with zero
              # per-instance setup.
              api_key = account_anthropic_provider_api_key
              if api_key.blank?
                return render_not_found(
                  "Claude Code credential (no per-instance credential and no active Anthropic AI provider on the account)"
                )
              end

              source = "account_provider"
            end

            if defined?(::System::Fleet::EventBroadcaster)
              ::System::Fleet::EventBroadcaster.emit!(
                account: current_account,
                kind: "system.claude_code_credential_issued",
                severity: :low,
                payload: { "instance_id" => current_instance.id, "source" => source },
                source: "node_api.config"
              )
            end

            render_success(api_key: api_key)
          end

          # GET /api/v1/system/node_api/config/dev_cell_bootstrap
          #
          # Delivers what a pooled dev-cell NodeInstance needs to act as an
          # autonomous campaign executor WITHOUT minting any account-wide secret:
          #
          #   * mcp   — { mcp_url } ONLY. The cell authenticates to /mcp by
          #             presenting its node client cert (mTLS), which resolves to
          #             an Mcp::Principal.for_instance_cn scoped by this
          #             instance's NodeInstancePeer grant. Bootstrap ensures the
          #             instance has announced as a peer and grants it EXACTLY the
          #             three dev-loop tools (default-deny everything else). No
          #             token is issued here — the cell runs a local mTLS proxy
          #             presenting the node cert (the dev-cell MODULE's concern).
          #   * gitea — { clone_url (SSH), private_key, known_hosts }. A per-repo
          #             read-WRITE Ed25519 DEPLOY KEY on ONLY the source repo (not
          #             an account-wide PAT). The private key is generated
          #             in-service, stored in Vault, and returned ONLY here.
          #             ff-only is enforced by source-repo branch protection.
          #
          # Scoped strictly to current_instance (mTLS subject) — same auth as
          # claude_code_credential. One instance can never bootstrap another's
          # credentials.
          #
          # IMPORTANT (CryptoMaterialSafety): the deploy-key private key is
          # assembled and returned ONLY in this response body — never logged,
          # echoed, or persisted anywhere except Vault (the emitted fleet event
          # carries ids only).
          def dev_cell_bootstrap
            # Authorization gate (BEFORE any side effect): only an instance whose
            # node is actually provisioned with the dev-cell module may bootstrap.
            unless dev_cell_instance?
              return render_error("Instance is not provisioned as a dev-cell", :forbidden)
            end

            result = ::System::DevCellBootstrapService.new(
              node_instance: current_instance,
              platform_base_url: platform_base_url,
              source_repo: dev_cell_source_repo
            ).call

            unless result.ok?
              message =
                if result.error == "gitea_unavailable"
                  "Dev-cell Gitea provisioning unavailable"
                else
                  "Dev-cell MCP grant unavailable"
                end
              return render_error(message, :service_unavailable)
            end

            if defined?(::System::Fleet::EventBroadcaster)
              ::System::Fleet::EventBroadcaster.emit!(
                account: current_account,
                kind: "system.dev_cell_bootstrap_issued",
                severity: :low,
                payload: { "instance_id" => current_instance.id },
                source: "node_api.config"
              )
            end

            render_success(mcp: result.mcp, gitea: result.gitea)
          end

          # GET /api/v1/system/node_api/config/ci_runner_registration
          #
          # Live-mints a Gitea Actions runner registration token for THIS
          # mTLS-authenticated instance — consumed by the gitea-act-runner
          # NodeModule's `runner` service ExecStartPre
          # (gitea-act-runner-register.sh). NO token is ever persisted on the
          # platform side or on the instance across restarts: a fresh one is
          # minted on every service start via
          # Devops::RunnerLifecycleService#registration_token_for_scope
          # (campaign 019f5885 inc1), which this endpoint calls with an
          # org-scope credential by default.
          #
          # Authorization gate (BEFORE any side effect): only an instance
          # whose node is actually provisioned with the gitea-act-runner
          # module may mint a token — mTLS enrollment alone is NOT enough,
          # same fail-closed shape as #dev_cell_bootstrap.
          #
          # inc5 HOOK POINT: this module-presence gate is the INTERIM
          # authorization the campaign 019f5885 design accepted for inc2 (a
          # multi-use org-scope token, gated only by module presence). inc5
          # replaces/augments this with a require-active-ci_build-lease
          # check right here, before minting.
          #
          # Credential resolution: SiteSetting "ci_runner_git_credential_id"
          # if set, else the account's single active Gitea credential.
          # Absent or AMBIGUOUS (more than one active Gitea credential with
          # no override configured) → 404, same "don't guess" posture as
          # every other credential-resolution path in this controller.
          #
          # IMPORTANT (CryptoMaterialSafety): the token is minted server-side
          # and returned ONLY in this response body — never logged, never
          # persisted, never included in the emitted fleet event (ids only).
          def ci_runner_registration
            unless ci_runner_instance?
              return render_error("Instance is not provisioned as a gitea-act-runner", :forbidden)
            end

            resolver = ::System::CiRunnerRegistrationResolver.new(account: current_account)
            credential = resolver.credential
            return render_not_found("Gitea credential for CI runner registration") if credential.nil?

            result = ::Devops::RunnerLifecycleService.new(account: current_account).registration_token_for_scope(
              credential: credential,
              scope: resolver.scope,
              owner: resolver.owner,
              repo: resolver.repo
            )

            if result[:token].blank?
              return render_error("Gitea runner registration token unavailable", :service_unavailable)
            end

            if defined?(::System::Fleet::EventBroadcaster)
              ::System::Fleet::EventBroadcaster.emit!(
                account: current_account,
                kind: "system.ci_runner_registration_issued",
                severity: :low,
                payload: { "instance_id" => current_instance.id },
                source: "node_api.config"
              )
            end

            render_success(
              gitea_instance_url: credential.provider.effective_web_base_url,
              registration_token: result[:token],
              runner_name: ::System::CiRunnerRegistrationResolver.runner_name(current_instance),
              labels: [ resolver.label ],
              ephemeral: resolver.ephemeral?
            )
          end

          private

          # True when the calling node is actually provisioned with the dev-cell
          # NodeModule (per-node NodeModuleAssignment → what's really on the box,
          # not merely the template's desired set). Fail-closed: no dev-cell
          # module → not a dev-cell → 403.
          def dev_cell_instance?
            current_node.node_modules.exists?(name: DEV_CELL_MODULE_NAME)
          end

          # True when the calling node is actually provisioned with the
          # gitea-act-runner NodeModule (per-node NodeModuleAssignment → what's
          # really on the box, not merely the template's desired set).
          # Fail-closed: no gitea-act-runner module → not a CI runner → 403.
          def ci_runner_instance?
            current_node.node_modules.exists?(name: CI_RUNNER_MODULE_NAME)
          end

          # "owner/repo" of the source repo the cell clones. Config-driven
          # (SiteSetting → ENV → default) so a non-default deployment can point
          # cells at its own fork without a code change.
          def dev_cell_source_repo
            ::SiteSetting.get("dev_cell_source_repo").presence ||
              ENV["POWERNODE_DEV_CELL_SOURCE_REPO"].presence ||
              DEV_CELL_SOURCE_REPO_DEFAULT
          end

          # Externally-reachable platform base (scheme+host, no trailing slash)
          # via the canonical PublicUrlResolver seam; falls back to the URL the
          # cell reached us on over mTLS when nothing is configured.
          def platform_base_url
            ::PublicUrlResolver.base_url(account: current_account).presence || request.base_url
          end

          def vault_provider
            @vault_provider ||= ::Security::VaultCredentialProvider.new(account_id: current_account.id)
          end

          # Active Anthropic AI-provider API key for the account, decrypted
          # server-side — the fallback source for #claude_code_credential when
          # the instance has no per-instance credential. Mirrors the resolution
          # shape of Ai::AudioTranscriptionService#resolve_credential
          # (account.ai_provider_credentials.active + a provider check) and reads
          # the value via Ai::ProviderCredential#decrypted_api_key. Defensive:
          # any resolution failure → nil, so the caller falls through to 404.
          def account_anthropic_provider_api_key
            # Opt-in, default OFF: a dev-cell inherits the account's Anthropic
            # provider key ONLY when the operator has explicitly enabled the
            # fallback. Otherwise every provisioned dev-cell would auto-consume
            # the account's API credits via its executor's real `claude` runs
            # (observed: burned two credit autorefills). Flip SiteSetting
            # "dev_cell_account_provider_credential_fallback"=true to enable;
            # otherwise an explicit per-instance ClaudeCodeCredential is required.
            return nil unless ::SiteSetting.get("dev_cell_account_provider_credential_fallback").to_s == "true"
            return nil unless current_account.respond_to?(:ai_provider_credentials)

            cred = current_account.ai_provider_credentials
                                  .active
                                  .includes(:provider)
                                  .detect { |c| c.provider&.is_active? && c.provider.provider_type == "anthropic" }
            cred&.decrypted_api_key.presence
          rescue StandardError
            nil
          end

          def serialize_instance
            {
              id: current_instance.id,
              name: current_instance.name,
              variety: current_instance.variety,
              status: current_instance.status,
              private_ip_address: current_instance.private_ip_address,
              public_ip_address: current_instance.public_ip_address,
              cloud_instance_id: current_instance.cloud_instance_id,
              config: current_instance.config
            }
          end

          def serialize_node
            {
              id: current_node.id,
              name: current_node.name,
              allocate_public_ip: current_node.allocate_public_ip,
              config: current_node.config,
              # Phase 3 — disk_policy is consumed by the agent's
              # volume-setup CLI to drive parted + mkfs sequencing.
              # Stored on node.config as a free-form JSONB block; the
              # platform's operator UI ensures the schema is sane,
              # but the agent treats it as data.
              disk_policy: current_node.config&.dig("disk_policy") || default_disk_policy
            }
          end

          # default_disk_policy returns a conservative default profile
          # used when a node has no explicit disk_policy configured.
          # Single root partition, ext4, no LUKS — minimum viable for
          # bare-metal nodes that don't need data partitions.
          def default_disk_policy
            {
              "profiles" => {
                "default" => {
                  "layout" => [
                    { "name" => "boot", "type" => "efi", "size_mb" => 512 },
                    { "name" => "root", "type" => "linux", "size_mb" => -1 }
                  ],
                  "format" => {
                    "boot" => { "fs" => "vfat", "label" => "EFI" },
                    "root" => { "fs" => "ext4", "label" => "root" }
                  },
                  "mount" => {
                    "boot" => { "path" => "/boot/efi", "opts" => "umask=0077,nofail" }
                  }
                }
              }
            }
          end

          def serialize_template
            return nil unless current_template

            {
              id: current_template.id,
              name: current_template.name,
              platform_id: current_template.node_platform_id,
              architecture_id: current_template.node_architecture_id,
              config: current_template.config
            }
          end

          def serialize_architecture
            return nil unless current_template&.node_architecture

            arch = current_template.node_architecture
            {
              id: arch.id,
              name: arch.name,
              config: arch.respond_to?(:config) ? arch.config : nil
            }
          end

          def serialize_provider_region
            return nil unless current_instance.provider_region

            region = current_instance.provider_region
            {
              id: region.id,
              name: region.name,
              region_code: region.region_code
            }
          end

          # The unix user whose ~/.ssh/authorized_keys the on-node agent
          # should manage. Resolution order: instance-level override →
          # node-level default → "pnadmin". The platform standardizes
          # the human-login account name to "pnadmin" (UID 1000, present
          # in the on-node agent's etcidentity baseline).
          # Per-instance/per-node overrides still work for legacy or
          # cloud-image-derived bootstraps (e.g., admin_user: "ubuntu").
          def target_admin_user
            current_instance.config&.dig("admin_user").presence ||
              current_node.config&.dig("admin_user").presence ||
              "pnadmin"
          end
        end
      end
    end
  end
end
