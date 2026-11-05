# frozen_string_literal: true

require "net/https"
require "fileutils"
require "json"

module ::DiscourseFcmNotifications
  # Raised when at least one device could not be reached because of a
  # temporary problem (429, 5xx, network). The Sidekiq job lets it propagate so
  # the delivery is retried; devices that already got the message are skipped
  # on retry by the per-token duplicate guard.
  class TransientDeliveryError < StandardError; end

  class Pusher
    PRIVATE_NOTIFICATION_TYPES = %i[
      private_message
      invited_to_private_message
      group_message_summary
    ].freeze

    DUPLICATE_WINDOW_SECONDS = 30

    def self.push(user, payload, raise_on_transient: false)
      return false if push_disabled_by_user?(user)

      raw_type = payload[:notification_type]
      type_key = if raw_type.is_a?(Symbol)
                   raw_type
                 elsif raw_type.is_a?(Integer) && defined?(Notification) && Notification.respond_to?(:types)
                   Notification.types.key(raw_type)
                 elsif raw_type.is_a?(String)
                   if raw_type =~ /^\d+$/ && defined?(Notification) && Notification.respond_to?(:types)
                     Notification.types.key(raw_type.to_i)
                   else
                     raw_type.to_sym
                   end
                 end

      title_key = type_key.present? ? "discourse_fcm_notifications.popup.#{type_key}" : nil
      fallback_title = if payload[:username].present? && payload[:topic_title].present?
                         "#{payload[:username]}: #{payload[:topic_title]}"
                       elsif payload[:topic_title].present?
                         payload[:topic_title].to_s
                       elsif payload[:username].present?
                         "#{payload[:username]} (#{SiteSetting.title})"
                       else
                         SiteSetting.title.to_s.presence || "Sorumatik"
                       end

      title = if title_key
                I18n.t(
                  title_key,
                  site_title: SiteSetting.title,
                  topic: payload[:topic_title],
                  username: payload[:username],
                  default: fallback_title
                )
              else
                fallback_title
              end

      body_text = payload[:excerpt].to_s.strip
      if hide_excerpt?(type_key)
        # Lock screens are visible to bystanders; never put private message
        # content into the push body.
        body_text = I18n.t("discourse_fcm_notifications.private_body", default: "You have a new private message.")
      elsif body_text.blank?
        body_text = I18n.t("discourse_fcm_notifications.confirm_body", default: "Yeni bir bildiriminiz var.")
      end

      topic_id = payload[:topic_id]
      if topic_id.blank? && payload[:post_url].present?
        match = payload[:post_url].to_s.match(/\/t\/[^\/]+\/(\d+)/)
        topic_id = match[1] if match
      end

      post_number = payload[:post_number]
      if post_number.blank? && payload[:post_url].present?
        match = payload[:post_url].to_s.match(/\/t\/[^\/]+\/\d+\/(\d+)/)
        post_number = match[1] if match
      end

      message = {
        title: title,
        message: body_text,
        url: "#{Discourse.base_url}/#{payload[:post_url]}",
        topic_id: topic_id,
        post_number: post_number,
        dedupe_key: [type_key, topic_id, post_number, payload[:username]].join(":")
      }
      self.send_notification(user, message, raise_on_transient: raise_on_transient)
    end

    # Respects the user's own Discourse preference (Preferences > Notifications
    # > push). The attribute only exists on recent Discourse versions.
    def self.push_disabled_by_user?(user)
      option = user&.user_option
      return false unless option && option.respond_to?(:push_notification_level)

      option.push_notification_level.to_s == "none"
    end

    def self.hide_excerpt?(type_key)
      return false unless type_key.present?
      return false unless SiteSetting.respond_to?(:fcm_notifications_hide_private_excerpt)

      SiteSetting.fcm_notifications_hide_private_excerpt &&
        PRIVATE_NOTIFICATION_TYPES.include?(type_key.to_sym)
    end

    # True when the same notification was already delivered to this device very
    # recently. The guard is per token so one failed device does not cause the
    # others to be skipped (or sent twice) on retry.
    def self.already_sent?(token, message_hash)
      identifier = message_hash[:dedupe_key].presence ||
        "#{message_hash[:url]}:#{message_hash[:title]}"
      key = "fcm_last_sent_#{Digest::MD5.hexdigest("#{token}:#{identifier}")}"

      if defined?(::Discourse) && ::Discourse.respond_to?(:redis) && ::Discourse.redis
        begin
          return true if ::Discourse.redis.get(key).present?
          return false
        rescue StandardError => e
          Rails.logger.warn "FCM redis duplicate check failed: #{e.message}"
        end
      end

      @msg_throttles ||= {}
      last_time = @msg_throttles[key]
      last_time.is_a?(Time) && last_time > DUPLICATE_WINDOW_SECONDS.seconds.ago
    end

    def self.mark_sent(token, message_hash)
      identifier = message_hash[:dedupe_key].presence ||
        "#{message_hash[:url]}:#{message_hash[:title]}"
      key = "fcm_last_sent_#{Digest::MD5.hexdigest("#{token}:#{identifier}")}"

      if defined?(::Discourse) && ::Discourse.respond_to?(:redis) && ::Discourse.redis
        begin
          ::Discourse.redis.setex(key, DUPLICATE_WINDOW_SECONDS, Time.now.to_i.to_s)
          return
        rescue StandardError => e
          Rails.logger.warn "FCM redis duplicate mark failed: #{e.message}"
        end
      end

      @msg_throttles ||= {}
      @msg_throttles[key] = Time.now
    end

    def self.confirm_subscribe(user)
      # Suppress sending a push notification for subscription confirmation.
      # Push notification confirmation causes unwanted spam alerts on client devices whenever token refreshes.
      true
    end

    def self.language_for(user, locale = nil)
      user_locale = if user.respond_to?(:effective_locale)
                      user.effective_locale
                    elsif user.respond_to?(:user_option)
                      user.user_option&.locale
                    end
      (locale.to_s.presence || user_locale.to_s.presence ||
        (SiteSetting.default_locale if defined?(SiteSetting)) || I18n.locale).to_s
    end

    # Sends the compact weekly study summary. The payload type is consumed by
    # the Flutter client to open the progress screen directly.
    def self.push_smart_recap(user, summary, locale: nil)
      title = case language_for(user, locale).downcase.split(/[-_]/).first
              when 'tr' then 'Haftalık çalışma özeti'
              when 'es' then 'Resumen semanal de estudio'
              when 'hi' then 'साप्ताहिक अध्ययन सारांश'
              when 'id' then 'Ringkasan belajar mingguan'
              else 'Weekly study recap'
              end
      self.send_notification(
        user,
        title: title,
        message: summary.to_s.truncate(240),
        url: Discourse.base_url,
        type: 'smart_recap'
      )
    end

    BLACKBOARD_JOB_TEXT = {
      'tr' => { 'ready' => ['Video çözümün hazır', 'İzlemek için dokun.'],
                'failed' => ['Video çözüm hazırlanamadı', 'Hakkın iade edildi. Tekrar denemek için dokun.'] },
      'en' => { 'ready' => ['Your video solution is ready', 'Tap to watch it.'],
                'failed' => ['Video solution failed', 'Your credit was returned. Tap to try again.'] },
      'es' => { 'ready' => ['Tu solución en video está lista', 'Toca para verla.'],
                'failed' => ['No se pudo preparar el video', 'Tu crédito fue devuelto. Toca para intentarlo de nuevo.'] },
      'hi' => { 'ready' => ['आपका वीडियो समाधान तैयार है', 'देखने के लिए टैप करें।'],
                'failed' => ['वीडियो समाधान तैयार नहीं हो सका', 'आपका क्रेडिट वापस कर दिया गया। फिर से कोशिश करने के लिए टैप करें।'] },
      'id' => { 'ready' => ['Solusi videomu sudah siap', 'Ketuk untuk menontonnya.'],
                'failed' => ['Solusi video gagal disiapkan', 'Kreditmu dikembalikan. Ketuk untuk mencoba lagi.'] },
    }.freeze

    # A Kara Tahta job ended. The deep link opens the topic and plays the video.
    def self.push_blackboard_job(user, topic_id:, status:, language: nil)
      texts = BLACKBOARD_JOB_TEXT[language.to_s.downcase.split('-').first] || BLACKBOARD_JOB_TEXT['en']
      title, message = texts.fetch(status.to_s)
      self.send_notification(
        user,
        {
          title: title,
          message: message,
          url: "#{Discourse.base_url}/t/#{topic_id}",
          type: "blackboard_#{status}",
          topic_id: topic_id,
          deep_link: "sorumatik://t/#{topic_id}?action=blackboard",
          group: "blackboard_#{topic_id}",
          skip_throttle: true,
        },
        raise_on_transient: true
      )
    end

    BLACKBOARD_OWNER_TEXT = {
      'tr' => ['Sorunun video çözümü hazır 🎬', 'Kara tahtada adım adım izle.'],
      'en' => ['Your question has a video solution 🎬', 'Watch it step by step on the blackboard.'],
      'es' => ['Tu pregunta tiene una solución en video 🎬', 'Mírala paso a paso en la pizarra.'],
      'hi' => ['आपके प्रश्न का वीडियो समाधान तैयार है 🎬', 'इसे ब्लैकबोर्ड पर चरण दर चरण देखें।'],
      'id' => ['Pertanyaanmu punya solusi video 🎬', 'Tonton langkah demi langkah di papan tulis.'],
    }.freeze

    # Someone else's request gave this user's question its first video.
    def self.push_blackboard_owner(user, topic_id:)
      language = language_for(user).downcase.split(/[-_]/).first
      title, message = BLACKBOARD_OWNER_TEXT[language] || BLACKBOARD_OWNER_TEXT['en']
      self.send_notification(
        user,
        {
          title: title,
          message: message,
          url: "#{Discourse.base_url}/t/#{topic_id}",
          type: 'blackboard_owner_ready',
          topic_id: topic_id,
          deep_link: "sorumatik://t/#{topic_id}?action=blackboard",
          group: "blackboard_#{topic_id}",
          skip_throttle: true,
        },
        raise_on_transient: true
      )
    end

    # +subscription+ is the registration token generated by the iPhone / Android
    # phone. The token is moved to +user+ if another account had it.
    def self.subscribe(user, subscription, device_id: nil, platform: nil)
      subscription = subscription.to_s.strip
      if subscription.blank? || subscription.length > DeviceToken::MAX_TOKEN_LENGTH
        raise ArgumentError, "Invalid FCM token"
      end

      DeviceToken.register!(user, subscription, device_id: device_id, platform: platform)
      clear_legacy_token(user)
    end

    def self.unsubscribe(user, token: nil, device_id: nil)
      DeviceToken.unregister!(user, token: token, device_id: device_id)
      clear_legacy_token(user) if token.blank? && device_id.blank?
    end

    # Device tokens of +user+. A token stored by the previous single-token
    # implementation (user custom field) is moved into the table on first use.
    def self.tokens_for(user)
      return [] unless user

      migrate_legacy_token(user)
      DeviceToken.where(user_id: user.id).order(:id).pluck(:token)
    end

    def self.has_tokens?(user)
      return false unless user

      DeviceToken.where(user_id: user.id).exists? ||
        user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME].present?
    end

    def self.migrate_legacy_token(user)
      legacy = user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME].to_s.strip
      return if legacy.blank?

      # Do not steal the token if a newer registration already moved it.
      unless DeviceToken.where(token: legacy).exists?
        DeviceToken.register!(user, legacy) if legacy.length <= DeviceToken::MAX_TOKEN_LENGTH
      end
      clear_legacy_token(user)
    end

    def self.clear_legacy_token(user)
      return if user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME].blank?

      user.custom_fields.delete(DiscourseFcmNotifications::PLUGIN_NAME)
      user.save_custom_fields(true)
    end

    # Turns an FCM v1 error response into :invalid_token, :transient or :other.
    def self.classify_failure(response)
      code = response[:status_code].to_i
      body = response[:body].to_s
      error_code = begin
        details = JSON.parse(body).dig("error", "details")
        Array(details).map { |d| d.is_a?(Hash) ? d["errorCode"] : nil }.compact.first
      rescue StandardError
        nil
      end

      if code == 404 || error_code == "UNREGISTERED" || error_code == "SENDER_ID_MISMATCH"
        :invalid_token
      elsif code == 400 && body =~ /registration token/i
        :invalid_token
      elsif code == 429 || code >= 500 || code == 0
        :transient
      else
        :other
      end
    end

    def self.fcm_client
      filename = Rails.root.join("tmp", "discourse_fcm_notifications", "gcp_key.json").to_s
      FileUtils.mkdir_p(File.dirname(filename))
      json = SiteSetting.fcm_notifications_google_json
      if json.present?
        current_content = begin
          File.read(filename) if File.exist?(filename)
        rescue StandardError
          nil
        end
        File.write(filename, json, mode: "w", perm: 0o600) if current_content != json
      end
      raise "Error: Missing google json for push notifications" unless File.exist?(filename)

      FCM.new(SiteSetting.fcm_notifications_api_key, filename, SiteSetting.fcm_notifications_project_id)
    end

    # Unread count for the iOS app icon badge. Nil when the Discourse version
    # does not expose it, in which case no badge is set.
    def self.badge_count_for(user)
      return nil unless user.respond_to?(:all_unread_notifications_count)

      user.all_unread_notifications_count.to_i
    rescue StandardError => e
      Rails.logger.warn "FCM badge count failed for #{user&.username}: #{e.message}"
      nil
    end

    def self.build_message(token, message_hash, badge: nil)
      data_payload = {
        "linked_obj_type" => 'link',
        "linked_obj_data" => message_hash[:url].to_s,
        "type" => message_hash[:type].to_s.presence || 'notification_tab',
      }
      data_payload["topic_id"] = message_hash[:topic_id].to_s if message_hash[:topic_id].present?
      data_payload["post_number"] = message_hash[:post_number].to_s if message_hash[:post_number].present?
      data_payload["deep_link"] = message_hash[:deep_link].to_s if message_hash[:deep_link].present?

      # Same topic => same group: Android replaces the earlier notification of
      # the topic, iOS stacks them in one thread.
      group = message_hash[:group].presence
      group ||= message_hash[:topic_id].present? ? "topic_#{message_hash[:topic_id]}" : nil
      android_notification = {
        "channel_id": "sorumatik_notifications_v4",
        "sound": "default",
        "default_sound": true,
        "default_vibrate_timings": true,
        "notification_priority": "PRIORITY_MAX"
      }
      android_notification["tag"] = group if group
      aps = {
        "sound": "default",
        "interruption-level": "time-sensitive"
      }
      aps["thread-id"] = group if group
      aps["badge"] = badge unless badge.nil?

      {
        'token': token,
        'data': data_payload,
        'notification': {
          title: message_hash[:title],
          body: message_hash[:message],
        },
        'android': {
          "priority": "high",
          "notification": android_notification
        },
        'apns': {
          headers: {
            "apns-priority": "10"
          },
          payload: {
            aps: aps
          }
        },
        'fcm_options': {
          "analytics_label": "Label"
        }
      }
    end

    def self.send_notification(user, message_hash, raise_on_transient: false)
      tokens = tokens_for(user)
      if tokens.empty?
        Rails.logger.info "Skipping FCM notification for #{user&.username || 'unknown'} because no device token is registered"
        return false
      end
      return false unless message_hash

      fcm = fcm_client
      badge = badge_count_for(user)
      delivered = false
      transient_failures = 0

      tokens.each do |token|
        next if !message_hash[:skip_throttle] && already_sent?(token, message_hash)

        response = fcm.send_v1(build_message(token, message_hash, badge: badge))
        if response[:response] == 'success'
          mark_sent(token, message_hash)
          delivered = true
          next
        end

        case classify_failure(response)
        when :invalid_token
          Rails.logger.warn "FCM token no longer valid for #{user.username}; removing it (code #{response[:status_code]})"
          DeviceToken.where(user_id: user.id, token: token).delete_all
        when :transient
          transient_failures += 1
          Rails.logger.warn "FCM temporary failure for #{user.username}, code #{response[:status_code]}"
        else
          Rails.logger.error "FCM push rejected for #{user.username}, code #{response[:status_code]}. Body: #{response[:body]}"
        end
      end

      if transient_failures > 0 && raise_on_transient
        raise TransientDeliveryError, "FCM temporary failure for user #{user.id} (#{transient_failures} device(s))"
      end

      delivered
    end
  end
end
