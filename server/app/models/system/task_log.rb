# frozen_string_literal: true

module System
  # The full scrubbed log of a System::Task, uploaded by the on-node agent
  # (IMP-dbc22946e05c). Written ONLY by System::TaskLogStore, which redacts and
  # bounds it; read ONLY through TaskLogStore.read_page, which redacts again.
  # `content` is therefore never served raw: there is no controller or serializer
  # that exposes this row.
  class TaskLog < BaseRecord
    belongs_to :account
    belongs_to :task, class_name: "System::Task"

    validates :expires_at, presence: true
    validates :task_id, uniqueness: true

    scope :live, ->(now = Time.current) { where("expires_at > ?", now) }
  end
end
