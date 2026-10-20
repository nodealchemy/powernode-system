# frozen_string_literal: true

# System extension association for the core Ai::Mission model: a mission's
# project metrics go with it (system_project_metrics.mission_id has no ON
# DELETE, so a mission -- or an account teardown destroying its missions --
# would otherwise fail on the foreign key).
Ai::Mission.class_eval do
  has_many :system_project_metrics,
           class_name: "System::ProjectMetric", foreign_key: "mission_id", dependent: :destroy
end
