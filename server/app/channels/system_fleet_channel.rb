# frozen_string_literal: true

# SystemFleetChannel — live FleetEvent stream for the operator UI.
# Decoupled from the existing SystemChannel so dashboards can subscribe
# only to fleet observability traffic without consuming task/node
# lifecycle messages.
#
# Stream name: "system_fleet:<account_id>" (matches FleetEventBroadcaster).
# Publish path: System::Fleet::EventBroadcaster.emit! → ActionCable broadcast.
#
# Reference: Golden Eclipse plan M7 observability + Track C M-FE-3 dashboard.
class SystemFleetChannel < ApplicationCable::Channel
  def subscribed
    account_id = params[:account_id]

    if current_user && authorized_for_account?(account_id)
      stream_from "system_fleet:#{account_id}"
      transmit({
        type: "connection_established",
        channel: "system_fleet",
        account_id: account_id,
        timestamp: Time.current.iso8601
      })
    else
      reject
    end
  end

  def unsubscribed
    Rails.logger.info "User #{current_user&.id} unsubscribed from SystemFleetChannel"
  end

  # Client requests recent events. Useful on initial subscription so the UI
  # has a backlog before live events start landing.
  def recent_events(data)
    return reject_unauthorized unless current_account

    limit = (data["limit"] || 50).to_i.clamp(1, 200)
    since = parse_iso(data["since"])

    scope = ::System::FleetEvent.where(account: current_account).recent.limit(limit)
    scope = scope.since(since) if since
    scope = scope.by_kind(data["kind"]) if data["kind"].present?

    transmit({
      type: "recent_events",
      events: scope.map(&:as_broadcast),
      count: scope.size,
      timestamp: Time.current.iso8601
    })
  end

  # Client requests events with the same correlation_id (e.g., to trace
  # a single tick's full chain).
  def correlation(data)
    return reject_unauthorized unless current_account
    return transmit({ type: "error", message: "correlation_id required" }) if data["correlation_id"].blank?

    events = ::System::FleetEvent
      .where(account: current_account, correlation_id: data["correlation_id"])
      .order(:emitted_at)

    transmit({
      type: "correlation_chain",
      correlation_id: data["correlation_id"],
      events: events.map(&:as_broadcast),
      count: events.size,
      timestamp: Time.current.iso8601
    })
  end

  def ping
    transmit({ type: "pong", timestamp: Time.current.iso8601 })
  end

  private

  def parse_iso(str)
    return nil if str.blank?
    Time.iso8601(str)
  rescue ArgumentError
    nil
  end

  def reject_unauthorized
    transmit({ type: "error", message: "Unauthorized" })
  end
end
