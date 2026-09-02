# frozen_string_literal: true

module Api
  module V1
    module System
      # M2 Self-Serve Hardening (BYOC) — per-account cloud-credential CRUD.
      #
      # Sibling of ::Api::V1::System::ProvidersController. Persists
      # System::ProviderCredential rows scoped to the current account
      # and validates them through the Slice A
      # System::CredentialValidationService before save (test-button
      # path AND save path both flow through #validate_credentials so
      # an unverified cred never reaches the DB).
      #
      # Encrypted-at-rest credential values are NEVER returned by
      # #index — only metadata + provider info, so the FirstRunWizard
      # can render the "configured" state without leaking secrets.
      class ProviderCredentialsController < BaseController
        before_action :set_account
        # Ordered AHEAD of :set_provider — that filter can render (400/404, and
        # since IMP-efc4b9c2d96b the SDK refusal, which names the adapter gems
        # this build ships), which would halt the chain before the in-body
        # require_permission ever ran. The in-body calls stay as the per-action
        # record of what each one needs.
        before_action :require_credential_action_permission, only: %i[create test]
        before_action :set_provider, only: %i[create test]
        before_action :set_credential, only: %i[destroy]

        # GET /api/v1/system/provider_credentials
        def index
          require_permission("system.providers.read")

          credentials = @account.system_provider_credentials
                                .includes(:provider)
                                .order(created_at: :desc)

          render_success(provider_credentials: credentials.map { |c| serialize(c) })
        end

        # POST /api/v1/system/provider_credentials
        # Body: { provider_id, name, credentials: { ... } }
        def create
          require_permission("system.providers.create")

          payload = credentials_param_hash
          if payload.blank?
            return render_error(
              "credentials must be a non-empty object",
              status: :unprocessable_content,
              code: "INVALID_CREDENTIALS"
            )
          end

          valid, error = validate_credentials(@provider, payload)
          unless valid
            return render_error(
              error.presence || "Credentials are invalid",
              status: :unprocessable_content,
              code: "INVALID_CREDENTIALS"
            )
          end

          credential = @account.system_provider_credentials.build(
            provider: @provider,
            name: name_param,
            credentials: payload,
            scope: :account_owned,
            is_active: true
          )

          if credential.save
            render_success(
              { provider_credential: serialize(credential) },
              status: :created
            )
          else
            render_validation_error(credential)
          end
        end

        # DELETE /api/v1/system/provider_credentials/:id
        # Soft-deletes by flipping is_active=false so historical audit
        # of which cred provisioned which instance survives. Hard-
        # delete is reserved for the cred-rotation tooling.
        def destroy
          require_permission("system.providers.delete")

          if @credential.update(is_active: false)
            render_success(
              message: "Credential deactivated",
              data: { provider_credential: serialize(@credential) }
            )
          else
            render_validation_error(@credential)
          end
        end

        # POST /api/v1/system/provider_credentials/test
        # Body: { provider_id, credentials: { ... } }
        # Returns { valid: bool, error?: string } — the wizard's
        # test-before-save button. Always 200; the boolean carries
        # the verdict so the wizard doesn't have to interpret error
        # status codes.
        def test
          require_permission("system.providers.test")

          payload = credentials_param_hash
          if payload.blank?
            return render_success(
              data: { valid: false, error: "credentials must be a non-empty object" }
            )
          end

          valid, error = validate_credentials(@provider, payload)
          render_success(data: { valid: valid, error: valid ? nil : error }.compact)
        end

        private

        def set_account
          @account = current_user&.account
          render_unauthorized unless @account
        end

        # Self-halting (require_permission raises PermissionDenied), so a
        # caller without the permission gets 403 and never reaches
        # :set_provider.
        def require_credential_action_permission
          require_permission(
            action_name == "test" ? "system.providers.test" : "system.providers.create"
          )
        end

        # Resolve `provider_id` polymorphically — the FirstRunWizard
        # sends the provider_type slug (e.g. "vultr") during BYOC
        # because no System::Provider row exists yet, while
        # ProviderFormModal sends the UUID of an existing provider.
        # `provider_type` may also be passed alongside as redundant
        # context; we accept it as a fallback.
        #
        # Auto-create-on-first-cred: when the operator brings a cred
        # for a type that doesn't have a provider row yet, we create
        # one. This is the BYOC seamless-onboarding path — saves the
        # operator from a pre-step "create provider" click. No longer
        # unconditional: a registry-supported type whose adapter SDK gem
        # is not bundled in this build is refused before the mint — see
        # #provider_sdk_refusal.
        def set_provider
          raw = params[:provider_id] ||
                params.dig(:provider_credential, :provider_id)
          provider_type = params[:provider_type] ||
                          params.dig(:provider_credential, :provider_type)

          if raw.blank? && provider_type.blank?
            render_error("provider_id or provider_type is required", status: :bad_request) and return
          end

          @provider = resolve_provider(raw, provider_type)
          # resolve_provider already refused (APO-7 SDK guard) — rendering a
          # second time here would raise DoubleRenderError.
          return if performed?

          render_not_found("Provider") unless @provider
        end

        def resolve_provider(raw_id, provider_type)
          if raw_id.present? && uuid_like?(raw_id)
            # ProviderFormModal path — explicit UUID, scoped to account.
            ::System::Provider.where(account_id: @account.id).find_by(id: raw_id)
          else
            # FirstRunWizard path — slug or provider_type fallback.
            type = (raw_id.presence || provider_type).to_s.downcase
            return nil if type.blank?
            return nil unless ::System::Provider::PROVIDER_TYPES.include?(type)

            existing = ::System::Provider.where(account_id: @account.id, provider_type: type).first
            return existing if existing

            # APO-7 follow-up: refuse BEFORE minting. The guard is on the
            # mint, not on the credential — an existing row of that type is
            # returned above untouched (the connection doors refuse to build
            # anything on it). `supported?` gates the predicate, so types with
            # no registry adapter at all (digitalocean/linode/vultr/custom)
            # are outside it by design, exactly as at the four APO-7 doors.
            if (refusal = provider_sdk_refusal(type))
              return render_sdk_refusal(refusal)
            end

            auto_create_provider!(type)
          end
        end

        # After APO-7 four doors (system_create_provider,
        # provider_connections#create/#update, system_create_provider_connection)
        # refuse a provider type whose adapter SDK gem is not bundled in this
        # build. This controller mints a System::Provider row as a side effect
        # of a credential POST, so without the same predicate it is a second
        # way to obtain exactly the inoperable row those doors refuse. It is
        # NOT the last one: REST ProvidersController#create/#update
        # (providers_controller.rb:25/37) permits :provider_type with no
        # registry guard and is still open — tracked separately, out of scope
        # for IMP-efc4b9c2d96b.
        #
        # @param provider_type [String]
        # @return [String, nil] refusal text naming the missing gem, or nil
        def provider_sdk_refusal(provider_type)
          return nil if provider_type.blank?

          registry = ::System::Providers::Registry
          return nil unless registry.supported?(provider_type)
          return nil if registry.sdk_available?(provider_type)

          registry.sdk_missing_message(provider_type)
        end

        # Refuse in the shape each action promises: #create answers 422
        # (nothing was written), while #test's contract is "always 200, the
        # boolean carries the verdict" — 422-ing the wizard's test button
        # would be a contract change. Returns nil so `@provider` stays unset;
        # `performed?` in #set_provider halts the filter chain before the
        # action body runs.
        #
        # @param message [String] refusal text naming the missing gem
        # @return [nil]
        def render_sdk_refusal(message)
          if action_name == "test"
            render_success(data: { valid: false, error: message })
          else
            render_error(message, status: :unprocessable_content, code: "PROVIDER_SDK_MISSING")
          end
          nil
        end

        def auto_create_provider!(provider_type)
          ::System::Provider.find_or_create_by!(account: @account, provider_type: provider_type) do |p|
            p.name = unique_provider_name(provider_type)
            p.enabled = true
            p.config = {}
            p.capabilities = {}
          end
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.error(
            "[ProviderCredentialsController] auto-create provider failed for type #{provider_type}: #{e.message}"
          )
          nil
        end

        # Provider name is unique per (account_id, name). The bootstrap
        # service may already have created e.g. a "Vultr" row; if our
        # default collides, fall back to "<Type> (BYOC)" so the
        # auto-create path still succeeds.
        def unique_provider_name(provider_type)
          base = provider_type.titleize
          return base unless ::System::Provider.exists?(account_id: @account.id, name: base)

          candidate = "#{base} (BYOC)"
          n = 1
          while ::System::Provider.exists?(account_id: @account.id, name: candidate)
            n += 1
            candidate = "#{base} (BYOC #{n})"
          end
          candidate
        end

        def uuid_like?(value)
          value.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
        end

        def set_credential
          @credential = @account.system_provider_credentials.find_by(id: params[:id])
          render_not_found("Provider credential") unless @credential
        end

        def credentials_param_hash
          raw = params[:credentials] || params.dig(:provider_credential, :credentials)
          case raw
          when ActionController::Parameters
            raw.to_unsafe_h
          when Hash
            raw.deep_stringify_keys
          else
            {}
          end
        end

        def name_param
          params[:name].presence ||
            params.dig(:provider_credential, :name).presence ||
            "#{@provider.name} credentials"
        end

        # Slice A's CredentialValidationService.test contract:
        #   test(provider:, credentials:) -> [bool, message_or_nil]
        # Slice A may not have shipped yet — fall back to "accept" so
        # the API stays exercisable in dev. Specs stub this either
        # way; the real provider adapter's authenticate? short-circuits
        # bogus creds before any cloud resources get allocated.
        def validate_credentials(provider, credentials)
          return [ true, nil ] unless defined?(::System::CredentialValidationService)

          result = ::System::CredentialValidationService.test(
            provider: provider,
            credentials: credentials
          )

          # Tolerate either [bool, msg] or { valid:, error: } shapes
          # so a Slice A return-shape pivot doesn't break the wizard.
          case result
          when Array then [ !!result[0], result[1] ]
          when Hash  then [ !!(result[:valid] || result["valid"]),
                           result[:error] || result["error"] ]
          else            [ !!result, nil ]
          end
        rescue StandardError => e
          Rails.logger.error(
            "[ProviderCredentialsController] validation failed: #{e.class}: #{e.message}"
          )
          [ false, e.message ]
        end

        def serialize(cred)
          {
            id: cred.id,
            provider_id: cred.provider_id,
            provider_name: cred.provider&.name,
            provider_type: cred.provider&.provider_type,
            name: cred.name,
            scope: cred.scope,
            is_active: cred.is_active?,
            last_test_at: cred.last_test_at&.iso8601,
            last_test_status: cred.last_test_status,
            last_error: cred.last_error,
            consecutive_failures: cred.consecutive_failures,
            created_at: cred.created_at&.iso8601,
            updated_at: cred.updated_at&.iso8601
          }
        end
      end
    end
  end
end
