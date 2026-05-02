# frozen_string_literal: true

# SystemChannel - Real-time updates for Powernode System infrastructure
#
# Provides WebSocket updates for:
# - Task status changes (progress, completion, failure)
# - Node status changes
# - Instance status changes
# - System statistics updates
#
# Broadcast events from models/jobs using:
#   SystemChannel.broadcast_task_update(account, task)
#   SystemChannel.broadcast_node_update(account, node)
#   SystemChannel.broadcast_stats_update(account)
#
class SystemChannel < ApplicationCable::Channel
  def subscribed
    account_id = params[:account_id]

    if current_user && authorized_for_account?(account_id)
      stream_from stream_name(account_id)
      stream_for_account(current_account)

      Rails.logger.info "User #{current_user.id} subscribed to System updates for account #{account_id}"

      # Send connection confirmation
      transmit({
        type: "connection_established",
        account_id: account_id,
        timestamp: Time.current.iso8601
      })
    else
      Rails.logger.warn "Unauthorized System channel subscription attempt for account #{account_id} by user #{current_user&.id}"
      reject
    end
  end

  def unsubscribed
    Rails.logger.info "User #{current_user&.id} unsubscribed from System updates"
  end

  # Client requests a refresh of tasks list
  def refresh_tasks
    return reject_unauthorized unless current_account

    tasks = System::Task.where(account: current_account)
                        .order(created_at: :desc)
                        .limit(50)

    transmit({
      type: "tasks_list",
      tasks: tasks.map { |t| serialize_task(t) },
      timestamp: Time.current.iso8601
    })
  end

  # Client requests a specific task's status
  def get_task(data)
    return reject_unauthorized unless current_account

    task = System::Task.find_by(id: data["task_id"], account: current_account)

    if task
      transmit({
        type: "task_status",
        task: serialize_task(task),
        timestamp: Time.current.iso8601
      })
    else
      transmit({
        type: "error",
        message: "Task not found",
        task_id: data["task_id"]
      })
    end
  end

  # Client requests system statistics
  def refresh_stats
    return reject_unauthorized unless current_account

    transmit({
      type: "system_stats",
      stats: build_system_stats,
      timestamp: Time.current.iso8601
    })
  end

  # Ping for connection health check
  def ping
    transmit({ type: "pong", timestamp: Time.current.iso8601 })
  end

  # Class methods for broadcasting updates from models/jobs
  class << self
    def broadcast_task_update(account, task)
      ActionCable.server.broadcast(
        stream_name_for(account.id),
        {
          type: "task_updated",
          task: serialize_task_static(task),
          timestamp: Time.current.iso8601
        }
      )
    end

    def broadcast_task_progress(account, task)
      ActionCable.server.broadcast(
        stream_name_for(account.id),
        {
          type: "task_progress",
          task_id: task.id,
          status: task.status,
          progress: task.progress,
          description: task.description,
          timestamp: Time.current.iso8601
        }
      )
    end

    def broadcast_node_update(account, node)
      ActionCable.server.broadcast(
        stream_name_for(account.id),
        {
          type: "node_updated",
          node: serialize_node_static(node),
          timestamp: Time.current.iso8601
        }
      )
    end

    def broadcast_instance_update(account, instance)
      ActionCable.server.broadcast(
        stream_name_for(account.id),
        {
          type: "instance_updated",
          instance: serialize_instance_static(instance),
          timestamp: Time.current.iso8601
        }
      )
    end

    def broadcast_stats_update(account)
      ActionCable.server.broadcast(
        stream_name_for(account.id),
        {
          type: "stats_updated",
          timestamp: Time.current.iso8601
        }
      )
    end

    def stream_name_for(account_id)
      "system_channel_#{account_id}"
    end

    private

    def serialize_task_static(task)
      {
        id: task.id,
        command: task.command,
        status: task.status,
        progress: task.progress,
        description: task.description,
        error_message: task.error_message,
        scheduled_at: task.scheduled_at&.iso8601,
        started_at: task.started_at&.iso8601,
        completed_at: task.completed_at&.iso8601,
        operable_type: task.operable_type,
        operable_id: task.operable_id,
        created_at: task.created_at.iso8601,
        updated_at: task.updated_at.iso8601
      }
    end

    def serialize_node_static(node)
      {
        id: node.id,
        name: node.name,
        enabled: node.enabled,
        public_address: node.public_address,
        instances_count: node.node_instances.count,
        created_at: node.created_at.iso8601,
        updated_at: node.updated_at.iso8601
      }
    end

    def serialize_instance_static(instance)
      {
        id: instance.id,
        name: instance.name,
        status: instance.status,
        variety: instance.variety,
        private_ip_address: instance.private_ip_address,
        public_ip_address: instance.public_ip_address,
        node_id: instance.node_id,
        created_at: instance.created_at.iso8601,
        updated_at: instance.updated_at.iso8601
      }
    end
  end

  private

  def stream_name(account_id)
    self.class.stream_name_for(account_id)
  end

  def reject_unauthorized
    transmit({ type: "error", message: "Unauthorized" })
  end

  def serialize_task(task)
    self.class.send(:serialize_task_static, task)
  end

  def build_system_stats
    return {} unless current_account

    {
      nodes: {
        total: System::Node.where(account: current_account).count,
        enabled: System::Node.where(account: current_account, enabled: true).count
      },
      instances: {
        total: System::NodeInstance.joins(:node).where(system_nodes: { account_id: current_account.id }).count,
        running: System::NodeInstance.joins(:node).where(system_nodes: { account_id: current_account.id }, status: "running").count,
        stopped: System::NodeInstance.joins(:node).where(system_nodes: { account_id: current_account.id }, status: "stopped").count
      },
      tasks: {
        total: System::Task.where(account: current_account).count,
        pending: System::Task.where(account: current_account, status: "pending").count,
        running: System::Task.where(account: current_account, status: "running").count
      }
    }
  end
end
