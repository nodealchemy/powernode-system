# frozen_string_literal: true

# SELF-SERVICE retrieval of a user's OWN SDWAN VPN config.
#
# The sibling BootstrapController serves the same config text to an ANONYMOUS
# caller holding a one-shot signed URL. That path stays exactly as it is — it is
# the operator hand-off vehicle and there are live links in flight. This
# controller is the second, independent route to the same artefact, for the case
# where no such URL exists or the URL was consumed.
#
# WHY IT EXISTS (increment 2 of the agent-issued-device design):
# Sdwan::UserDeviceIssuer.issue! gained `mint_bootstrap_token: false` so a
# non-operator issuer (the MCP arm, increment 4) can mint a device WITHOUT
# minting a bootstrap URL — that URL is the sole auth for an anonymous endpoint
# serving a WireGuard private key, and an MCP tool result is forwarded to a model
# provider and persisted in a conversation record. A device issued that way is
# STRANDED unless something else can deliver its config. This is that something.
#
# WHY OWNERSHIP ALONE AUTHORIZES, WITH NO PERMISSION STRING
# --------------------------------------------------------
# Sdwan::AccessGrant `belongs_to :user` is REQUIRED (`granted_by` two lines below
# it is `optional: true`, so the required one is genuinely the recipient, not the
# issuer). The grant row IS the authorization record — its own class comment says
# it "lives at the granular layer below dot-string permissions (which gate what
# operators can DO; this row gates what one specific user can REACH)". Asking for
# a second, coarser check on top would be asking the wrong layer.
#
# A named permission here would be a trap, not a hardening. Every recipient of a
# VPN grant is an ORDINARY user, and on this platform a permission name that is
# not code-defined and granted degrades to admin-only — which would lock out
# precisely the person the endpoint exists to serve, while leaving admins (who
# can already issue a fresh device for that user and read the bootstrap token
# straight out of the create response) no new capability. The disclosure surface
# is exactly one user's own key material, so there is nothing for a permission to
# scope that the ownership predicate does not already scope more tightly.
#
# Impersonation sessions resolve `current_user` to the IMPERSONATED user, so an
# impersonating admin reads the impersonated user's device. That is the
# platform-wide semantics of every user-scoped endpoint and grants no privilege
# an operator does not already hold via user_devices.manage. Note the WRITE side
# too: such a fetch stamps `last_downloaded_at` as though the USER had
# downloaded, which both feeds the staleness sensor a download that never
# reached them and spends any bootstrap link they were still holding. Support
# should read "already used" on an untouched link as "someone fetched it for
# you", not as a bug.
#
# Response is text/plain, matching BootstrapController: the body is the file the
# user pastes into wg-quick / a WireGuard client, and a JSON envelope would only
# make the console re-extract it.
module Api
  module V1
    module System
      module Sdwan
        class MyDevicesController < ::Api::V1::System::BaseController
          # authz-ok: authorization here is OWNERSHIP, not a permission string —
          # `own_device` scopes the relation to the caller's own Sdwan::AccessGrant
          # rows (`belongs_to :user`, required), so a device the caller does not own
          # is unreachable by construction rather than by a check that could be
          # deleted. A dot-string permission would be a REGRESSION, not a
          # hardening: the recipients are ordinary users, an undefined permission
          # name degrades to admin-only on this platform, and the sole disclosure
          # surface is the caller's own key material — nothing a coarser gate
          # could scope more tightly. See the class comment above for the full
          # argument, and my_device_config_spec.rb / my_devices_index_spec.rb
          # for the ownership, cross-account, unauthenticated, revoked, and
          # grant-suspended refusals that pin it. (check-authz-coverage.sh
          # flags this file on the private helpers `own_device` /
          # `owned_devices`, neither of which is an action — the only actions
          # are the read shapes `index` and `show`, both ownership-scoped
          # through the same `owned_devices` predicate.)

          # GET /api/v1/system/sdwan/my_devices
          #
          # Increment 3a: the caller's own devices, so the frontend (and the
          # caller) can discover the id `#show` needs — increment 2 built the
          # retrieval route but nothing surfaced the id to retrieve. Same
          # ownership scope as `#show` (`owned_devices`, below), so a device
          # this endpoint lists is exactly the set `#show` can serve; no
          # separate rule to drift.
          #
          # `index` is a safe action name here: nothing in the
          # AbstractController/ActionController ancestry defines `index`
          # (unlike `config`, see the comment on `#show`), so there is no
          # shadow-and-recurse hazard to check for.
          #
          # Returns JSON, not text/plain like `#show` — this lists metadata
          # for a list-plus-download-button UI, not a config file to paste
          # into a WireGuard client. It never reads `private_key_b64` (or any
          # Vault-backed field) at all, so there is no code path here that
          # could leak key material — the absence is structural, not a
          # redaction step someone could forget.
          def index
            # See the identical guard in `#show`: authenticate_request also
            # succeeds for a worker principal (bearer worker token, or
            # forwarded mTLS client cert), which leaves current_user nil.
            # There is no "a worker's own devices" concept, so refuse on the
            # identity rather than falling through to an always-empty scope.
            return render_unauthorized("authentication required") if current_user.blank?

            devices = owned_devices.order(created_at: :desc)
            render_success(devices: devices.map { |d| serialize_device(d) })
          end

          # GET /api/v1/system/sdwan/my_devices/:id/config
          #
          # The action is `show`, NOT `config`, even though the URL segment is
          # `/config`. `AbstractController` (via ActiveSupport::Configurable)
          # already defines an instance method named `config`, and `render`
          # calls it internally — an action of that name shadows it and every
          # response recurses into the action until SystemStackError. Same
          # hazard class as `#dispatch` on the metrics controller a few routes
          # up, which is renamed to `#index` for the identical reason.
          def show
            # `authenticate_request` also succeeds for a WORKER principal (bearer
            # worker token, or a forwarded mTLS client cert) which leaves
            # current_user nil. The scope below would return no rows for such a
            # caller anyway, but failing on the identity rather than on an empty
            # scope keeps the reason for the refusal legible.
            return render_text_error("authentication required", 401) if current_user.blank?

            device = own_device
            # 404, NOT 403, for a device the caller does not own: a 403 on an id
            # that exists and a 404 on one that does not would let anyone
            # enumerate device ids. The body carries no device fact either way.
            return render_text_error("device not found", 404) unless device

            unless device.owner_retrievable?
              return render_text_error(
                device.revoked? ? "device has been revoked" : "underlying access grant is not active",
                410
              )
            end

            # FAIL CLOSED ON MISSING KEY MATERIAL — checked BEFORE rendering.
            #
            # Sdwan::WgConfigRenderer does not raise when private_key_b64 is nil;
            # it substitutes a "<vault-unavailable: ...>" placeholder into the
            # PrivateKey line and returns a 200-shaped config that a WireGuard
            # client will accept and then silently fail to connect with. Without
            # this guard a Vault outage is indistinguishable from success at
            # every observable point.
            #
            # The check is the MECHANISM (the renderer's only nil path), not a
            # string match on the placeholder text — a wording change in the
            # renderer would silently stop matching, which is the failure mode
            # this guard exists to prevent.
            #
            # SCOPE OF THIS GUARD: KEY MATERIAL ONLY. The renderer has two OTHER
            # degraded outputs it signals with a `# WARNING:` comment rather than
            # an error — a network with no publicly-reachable hub, and hubs that
            # all lack an active key. Both return 200 here with a config carrying
            # zero [Peer] sections, which cannot connect. That is deliberate and
            # NOT extended into a refusal: the private half is the irreplaceable,
            # single-issuance part and the device becomes usable the moment an
            # operator adds a hub, whereas refusing would strand the user over a
            # server-side misconfiguration they cannot fix and would silently
            # diverge from BootstrapController on a SHARED renderer. The in-band
            # warning is the operator's signal. So read the sentence above
            # narrowly: absent KEY MATERIAL is what is indistinguishable from
            # success without this guard; hub problems announce themselves.
            #
            # `private_key_b64` reads through VaultCredential#vault_credentials,
            # which memoizes under a `defined?` guard. Reading it here and again
            # inside the renderer therefore hits the SAME memo on the SAME
            # instance, so the guard cannot pass while the render degrades.
            #
            # NOTE FOR ANY FUTURE CALLER: that memo is also a live hazard.
            # `store_in_vault` assigns `@vault_credentials = nil` INTO the memo,
            # and `reload` does not clear an ivar — so a device instance carried
            # over from an issuance answers nil for private_key_b64 forever, in
            # every environment. This action is safe because it loads the device
            # fresh from the database and never issues. An endpoint that ever
            # issues and serves in one request MUST re-fetch by id first.
            if device.private_key_b64.blank?
              return render_text_error(
                "device key material is unavailable; ask an operator to re-issue this device", 503
              )
            end

            body = ::Sdwan::WgConfigRenderer.render(device)

            # Stamped AFTER the text is built, unlike the bootstrap path which
            # stamps first to burn a one-shot URL even on a failed transfer.
            # Nothing is burned here (see UserDevice#owner_retrievable?), so the
            # column is free to mean what the staleness sensor reads it as: when
            # the config the user holds was rendered.
            device.mark_downloaded!

            render plain: body, content_type: "text/plain", status: :ok
          end

          private

          # POSITIVE SCOPE, not find-then-compare. Restricting the relation to
          # the caller's own grants makes "not mine" indistinguishable from "does
          # not exist" by construction; a separate `device.access_grant.user_id ==
          # current_user.id` line after a global find is one deleted line away
          # from serving anyone's key to anyone.
          #
          # Account scoping is implied and not restated: user_id is a UUIDv7 and
          # a User belongs to exactly one Account, so grant.user_id ==
          # current_user.id already pins the account.
          # eager_load, not joins: `owner_retrievable?` reads through
          # access_grant immediately afterwards, so a bare join would authorize
          # off one query and then fire a second to answer the very row it just
          # filtered on. The LEFT OUTER JOIN eager_load emits is still fail
          # closed — `system_sdwan_access_grants.user_id = <caller>` is never
          # true for a NULL-joined row, so a device whose grant was hard-deleted
          # stays unreachable exactly as it was under the inner join.
          #
          # SHARED by `#index` and `#show` (via `own_device` below) — this is
          # the ONE ownership rule for this controller. Do not add a second
          # `.merge(::Sdwan::AccessGrant.where(user_id: ...))` anywhere else;
          # two copies of the same predicate are free to drift apart.
          def owned_devices
            ::Sdwan::UserDevice
              .eager_load(:access_grant)
              .merge(::Sdwan::AccessGrant.where(user_id: current_user.id))
          end

          def own_device
            owned_devices.find_by(id: params[:id])
          end

          # NO KEY MATERIAL: deliberately omits public_key, private_key_b64,
          # and everything VaultCredential-backed. An index has no reason to
          # touch key material at all — see the class comment on `#index`.
          # `network_id` reads through the already eager_load'ed access_grant,
          # so this stays a single query for the whole list (CLAUDE.md
          # eager-loading rule).
          def serialize_device(d)
            {
              id: d.id,
              label: d.label,
              status: device_status(d),
              retrievable: d.owner_retrievable?,
              network_id: d.access_grant.sdwan_network_id,
              created_at: d.created_at.iso8601,
              last_downloaded_at: d.last_downloaded_at&.iso8601
            }
          end

          # Derived, not stored: UserDevice has no `status` column, only the
          # revoked_at / last_downloaded_at timestamps `#show` already reads.
          # Mirrors the model's `active` / `downloaded` / `pending_download`
          # scopes so this string means the same thing everywhere it appears.
          def device_status(d)
            return "revoked" if d.revoked?
            return "downloaded" if d.last_downloaded_at.present?

            "pending_download"
          end

          # Mirrors BootstrapController's private helper rather than sharing one:
          # extracting a concern would mean editing that controller, and its
          # anonymous serving path is explicitly frozen while agent-issued
          # devices are still gated off.
          def render_text_error(message, status)
            render plain: "# #{message}\n", content_type: "text/plain", status: status
          end
        end
      end
    end
  end
end
