# frozen_string_literal: true

require 'securerandom'

module DiscourseFcmNotifications
  # Opaque share tokens for exported Kara Tahta videos. The QR code and the
  # share link carry only the token, never the student's username; the
  # server keeps who shared which topic and counts opens.
  class BlackboardShare
    STORE = 'discourse-fcm-notifications'
    TOKEN_PATTERN = /\A[A-Za-z0-9_-]{12,32}\z/

    def self.create!(user:, topic:)
      reverse_key = "bb_share_by:#{user.id}:#{topic.id}"
      existing = PluginStore.get(STORE, reverse_key)
      return existing if existing.is_a?(String) && PluginStore.get(STORE, "bb_share:#{existing}")

      token = SecureRandom.urlsafe_base64(12)
      PluginStore.set(STORE, "bb_share:#{token}", {
        'topic_id' => topic.id,
        'user_id' => user.id,
        'created_at' => Time.now.utc.iso8601,
        'opens' => 0,
      })
      PluginStore.set(STORE, reverse_key, token)
      token
    end

    # Topic id for [token], or nil. Counts the open unless the sharer opens it.
    def self.resolve(token, viewer: nil)
      return nil unless token.to_s.match?(TOKEN_PATTERN)
      key = "bb_share:#{token}"
      record = PluginStore.get(STORE, key)
      return nil unless record.is_a?(Hash)
      if viewer.nil? || viewer.id != record['user_id']
        record['opens'] = record['opens'].to_i + 1
        PluginStore.set(STORE, key, record)
      end
      record['topic_id']
    end

    def self.url(topic_id, token)
      "#{Discourse.base_url}/t/#{topic_id}?action=blackboard&s=#{token}"
    end
  end
end
