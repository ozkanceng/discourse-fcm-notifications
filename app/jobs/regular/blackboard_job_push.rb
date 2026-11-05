# frozen_string_literal: true

module ::Jobs
  # Tells a student that the Kara Tahta job they asked to be notified about is
  # over. The student asked for this push, so the forum's push level is ignored.
  class BlackboardJobPush < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.fcm_notifications_enabled?

      user = User.find_by(id: args[:user_id])
      return if user.blank?

      # The API may repeat a report it did not see answered; one push per job.
      key = "sorumatik:blackboard:job_push:#{args[:job_id]}"
      return unless Discourse.redis.set(key, '1', nx: true, ex: 86_400)

      begin
        DiscourseFcmNotifications::Pusher.push_blackboard_job(
          user, topic_id: args[:topic_id], status: args[:status], language: args[:language]
        )
      rescue DiscourseFcmNotifications::Pusher::TransientDeliveryError
        Discourse.redis.del(key) # Sidekiq retries the delivery.
        raise
      end
    end
  end
end
