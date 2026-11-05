# frozen_string_literal: true

module ::Jobs
  # Tells the asker that someone else's request gave their question its first
  # video solution. Nobody asked for this push, so it stays within the user's
  # push preference and skips old questions.
  class BlackboardOwnerPush < ::Jobs::Base
    MAX_TOPIC_AGE = 30.days

    def execute(args)
      return unless SiteSetting.fcm_notifications_enabled?

      solution = DiscourseFcmNotifications::BlackboardSolution.find_by(id: args[:solution_id])
      topic = solution && Topic.find_by(id: solution.topic_id)
      return if topic.blank? || topic.private_message? || topic.created_at < MAX_TOPIC_AGE.ago
      return if earlier_solution?(solution)

      owner = topic.user
      return if owner.blank? || owner.bot? || owner.suspended? || owner.id == solution.generated_by_id
      return if DiscourseFcmNotifications::Pusher.push_disabled_by_user?(owner)
      return unless Guardian.new(owner).can_see?(topic)

      DiscourseFcmNotifications::Pusher.push_blackboard_owner(owner, topic_id: topic.id)
    end

    private

    def earlier_solution?(solution)
      DiscourseFcmNotifications::BlackboardSolution
        .where(topic_id: solution.topic_id, status: 'ready')
        .where('id < ?', solution.id)
        .exists?
    end
  end
end
