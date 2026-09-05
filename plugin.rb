# frozen_string_literal: true

# name: discourse-fcm-notifications
# about: Plugin for integrating firebase notifications to a custom app
# version: 0.2.0
# authors: Judith Meyer, Jeff Wong (original plugin: discourse-pushover-notifications)
# url: https://github.com/sprachprofi/discourse-fcm-notifications

enabled_site_setting :fcm_notifications_enabled
gem 'signet', '0.17.0'
gem 'os', '1.1.4'
gem 'memoist', '0.16.2'
gem 'googleauth', '1.7.0'
gem 'fcm', '1.0.8'

module ::DiscourseFcmNotifications
  PLUGIN_NAME = "discourse-fcm-notifications"
  #autoload :Pusher, "#{Rails.root}/plugins/discourse-fcm-notifications/services/discourse_fcm_notifications/pusher"
end

require_relative "lib/discourse_fcm_notifications/engine"

after_initialize do
  User.register_custom_field_type(DiscourseFcmNotifications::PLUGIN_NAME, :json)
  allow_staff_user_custom_field DiscourseFcmNotifications::PLUGIN_NAME

  # Discourse does not guarantee that Jobs::Base is loaded while plugin.rb is
  # being evaluated. Defer both plugin job files until the application has
  # finished initialization, and fail closed if the job API is unavailable.
  jobs_ready = begin
    require_dependency "jobs/base" unless defined?(::Jobs::Base)
    require_dependency File.expand_path("app/jobs/regular/weekly_smart_recap", __dir__)
    defined?(::Jobs::Base) && defined?(::Jobs::WeeklySmartRecap)
  rescue StandardError => e
    Rails.logger.error(
      "discourse-fcm-notifications jobs disabled: #{e.class}: #{e.message}",
    )
    false
  end

  if jobs_ready
    module ::Jobs
      unless const_defined?(:SendFcmNotifications, false)
        class SendFcmNotifications < ::Jobs::Base
          def execute(args)
            return unless SiteSetting.fcm_notifications_enabled?

            user = User.find(args[:user_id])
            DiscourseFcmNotifications::Pusher.push(user, args[:payload])
          end
        end
      end
    end

    DiscourseEvent.on(:push_notification) do |user, payload|
      if SiteSetting.fcm_notifications_enabled?
        token = user&.custom_fields&.[](DiscourseFcmNotifications::PLUGIN_NAME)
        next if token.blank?
        Jobs.enqueue(:send_fcm_notifications, user_id: user.id, payload: payload)
      end
    end

    # The job self-schedules hourly and evaluates each user's local Sunday
    # 19:00 window before sending a compact recap.
    Jobs.enqueue_in(1.hour, :weekly_smart_recap)
  else
    Rails.logger.error(
      "discourse-fcm-notifications: Discourse job API unavailable; " \
        "FCM and Smart Recap jobs will not be registered",
    )
  end
end
