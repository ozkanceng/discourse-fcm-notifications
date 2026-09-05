# frozen_string_literal: true

module ::Jobs
  class WeeklySmartRecap < ::Jobs::Base
    WINDOW = 7.days

    def execute(args)
      users = if args[:user_id].present?
                [User.find_by(id: args[:user_id])].compact
              else
                user_ids = DiscourseFcmNotifications::SorumatikStudyEvent
                  .where("occurred_at >= ?", WINDOW.ago)
                  .distinct
                  .pluck(:user_id)
                User.where(id: user_ids).to_a
              end

      users.each { |user| send_recap_if_due(user) }
    ensure
      # Run hourly so a worker restart cannot miss a user's local 19:00 slot.
      Jobs.enqueue_in(1.hour, :weekly_smart_recap) if defined?(Jobs)
    end

    private

    def send_recap_if_due(user)
      return unless user

      zone = ActiveSupport::TimeZone[user.timezone.to_s] || Time.zone
      now = zone.now
      return unless now.sunday? && now.hour == 19

      key = "sorumatik:smart_recap:#{user.id}:#{now.to_date}"
      return if Discourse.redis.get(key)

      events = DiscourseFcmNotifications::SorumatikStudyEvent
        .where(user_id: user.id, occurred_at: 7.days.ago..Time.zone.now)
      return if events.empty?

      areas = Hash.new(0)
      events.each do |event|
        payload = event.payload.is_a?(Hash) ? event.payload : {}
        area = payload['focus_area'] || payload['topic'] || payload['category'] || event.event_type
        area = area.to_s.strip
        areas[area] += 1 unless area.empty?
      end
      top_areas = areas.sort_by { |area, count| [-count, area] }.first(3)
      summary = top_areas.each_with_index.map do |(area, count), index|
        "#{index + 1}. #{area}: #{count} etkinlik"
      end.join("\n")
      summary = "Bu hafta çalışma etkinliğin kaydedildi." if summary.empty?

      if DiscourseFcmNotifications::Pusher.push_smart_recap(user, summary, locale: user.locale)
        Discourse.redis.setex(key, 8.days.to_i, 'sent')
      end
    rescue StandardError => e
      Rails.logger.error("Sorumatik Smart Recap failed for user #{user&.id}: #{e.class}: #{e.message}")
    end
  end
end
