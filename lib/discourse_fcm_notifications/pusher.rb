# frozen_string_literal: true

require "net/https"
require "fileutils"

module ::DiscourseFcmNotifications
  class Pusher
    def self.push(user, payload)
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
      if body_text.blank?
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
        post_number: post_number
      }
      self.send_notification(user, message)
    end

    # Checks if the exact same notification was sent to the user very recently (5s),
    # preventing duplicate job retries without dropping distinct answers or replies.
    def self.already_sent?(user, message_hash = nil)
      token = user&.custom_fields&.[](DiscourseFcmNotifications::PLUGIN_NAME)
      return false if token.blank?

      identifier = if message_hash.is_a?(Hash)
                     "#{user.id}:#{message_hash[:url]}:#{message_hash[:title]}"
                   else
                     "#{user.id}:generic"
                   end
      fingerprint = Digest::MD5.hexdigest(identifier)
      key = "fcm_last_sent_#{fingerprint}"

      if defined?(::Discourse) && ::Discourse.respond_to?(:redis) && ::Discourse.redis
        begin
          last_sent = ::Discourse.redis.get(key)
          if last_sent.present?
            Rails.logger.info "FCM duplicate suppressed for #{user.username} (fingerprint: #{fingerprint})"
            return true
          end
          ::Discourse.redis.setex(key, 5, Time.now.to_i.to_s)
          return false
        rescue StandardError => e
          Rails.logger.warn "FCM redis duplicate check failed: #{e.message}"
        end
      end

      @msg_throttles ||= {}
      last_time = @msg_throttles[fingerprint]
      if last_time.is_a?(Time) && (last_time > 5.seconds.ago)
        Rails.logger.info "FCM duplicate suppressed in-memory for #{user.username}"
        true
      else
        @msg_throttles[fingerprint] = Time.now
        false
      end
    end

    def self.confirm_subscribe(user)
      # Suppress sending a push notification for subscription confirmation.
      # Push notification confirmation causes unwanted spam alerts on client devices whenever token refreshes.
      true
    end

    # Sends the compact weekly study summary. The payload type is consumed by
    # the Flutter client to open the progress screen directly.
    def self.push_smart_recap(user, summary, locale: nil)
      user_locale = if user.respond_to?(:effective_locale)
                      user.effective_locale
                    elsif user.respond_to?(:user_option)
                      user.user_option&.locale
                    end
      language = locale.to_s.presence || user_locale.to_s.presence || (SiteSetting.default_locale if defined?(SiteSetting)) || I18n.locale.to_s
      title = case language.to_s.downcase.split('-').first
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

    # subscription should be a string automatically generated by the iPhone / Android phone
    def self.subscribe(user, subscription)
      subscription = subscription.to_s.strip
      raise ArgumentError, "Invalid FCM token" if subscription.blank? || subscription.length > 4096
      user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = subscription
      user.save_custom_fields(true)
    end

    def self.unsubscribe(user)
      user.custom_fields.delete(DiscourseFcmNotifications::PLUGIN_NAME)
      user.save_custom_fields(true)
    end

    private

    def self.send_notification(user, message_hash) 
      token = user&.custom_fields&.[](DiscourseFcmNotifications::PLUGIN_NAME)
      if token.blank?
        Rails.logger.info "Skipping FCM notification for #{user&.username || 'unknown'} because token is blank"
        return false
      end

      if user && message_hash && (message_hash[:skip_throttle] || !self.already_sent?(user, message_hash))
        Rails.logger.info "Sending a notification to #{user.username} about #{message_hash[:title]}"
        filename = Rails.root.join("tmp", "discourse_fcm_notifications", "gcp_key.json").to_s
        FileUtils.mkdir_p(File.dirname(filename))
        if SiteSetting.fcm_notifications_google_json.present?
          current_content = begin
            File.read(filename) if File.exist?(filename)
          rescue StandardError
            nil
          end
          if current_content != SiteSetting.fcm_notifications_google_json
            File.write(filename, SiteSetting.fcm_notifications_google_json, mode: "w", perm: 0o600)
          end
        end
        raise "Error: Missing google json for push notifications" unless File.exist?(filename)
        
        fcm = FCM.new(SiteSetting.fcm_notifications_api_key, filename, SiteSetting.fcm_notifications_project_id)

        data_payload = {
          "linked_obj_type" => 'link',
          "linked_obj_data" => message_hash[:url].to_s,
          "type" => message_hash[:type].to_s.presence || 'notification_tab',
        }
        if message_hash[:topic_id].present?
          data_payload["topic_id"] = message_hash[:topic_id].to_s
        end
        if message_hash[:post_number].present?
          data_payload["post_number"] = message_hash[:post_number].to_s
        end

        message = {
          'token': token,
          'data': data_payload,
          'notification': {
            title: message_hash[:title],
            body: message_hash[:message],
          },
          'android': {
            "priority": "high",
            "notification": {
              "channel_id": "sorumatik_notifications_v4",
              "sound": "default",
              "default_sound": true,
              "default_vibrate_timings": true,
              "notification_priority": "PRIORITY_MAX"
            }
          },
          'apns': {
            headers: {
              "apns-priority": "10"
            },
            payload: {
              aps: {
                "sound": "default",
                "interruption-level": "time-sensitive"
              }
            }
          },
          'fcm_options': {
            "analytics_label": "Label"
          }
        }

        response = fcm.send_v1(message)
        if response[:response] == 'success'
          Rails.logger.info "Successfully sent push notification about #{message_hash[:title]} to token " + token.to_s
          return true
        else
          if response[:status_code] == 400
            txt = "ERROR: push notification was malformed. Tried to send notif about #{message_hash[:title]} to token " 
            txt += token.to_s + " and body response was: " + response[:body].to_s
            Rails.logger.error txt
          elsif response[:status_code] == 404
            Rails.logger.error "Possible error: push notification was sent to a token that is no longer valid. Unsubscribing user " + token.to_s
            self.unsubscribe user
          else 
            Rails.logger.error "ERROR: something was wrong with the push notification, code #{response[:status_code]}. Body: " + response[:body].to_s
          end
          return false
        end  
      end    
    end
  end

end
