# frozen_string_literal: true

module ::Jobs
  # Flags topics whose solutions were saved before has_blackboard_solution
  # existed. Runs once; later saves set the flag themselves.
  class BackfillBlackboardSolutionFlag < ::Jobs::Onceoff
    def execute_onceoff(_args)
      topic_ids = DiscourseFcmNotifications::BlackboardSolution
        .where(status: 'ready', schema_version: 3)
        .distinct
        .pluck(:topic_id)
      Topic.where(id: topic_ids).find_each do |topic|
        topic.upsert_custom_fields(DiscourseFcmNotifications::BLACKBOARD_SOLUTION_FIELD => true)
      end
    end
  end
end
