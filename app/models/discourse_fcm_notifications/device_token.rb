# frozen_string_literal: true

module DiscourseFcmNotifications
  class DeviceToken < ActiveRecord::Base
    self.table_name = "fcm_device_tokens"

    MAX_TOKEN_LENGTH = 1024
    PLATFORMS = %w[android ios].freeze

    belongs_to :user

    validates :token, presence: true, length: { maximum: MAX_TOKEN_LENGTH }

    # Binds +token+ to +user+. The token is first detached from every other
    # user (shared device / account switch), and a device that rotated its
    # token replaces its previous row instead of accumulating stale ones.
    #
    # Registrations without a +device_id+ come from older app versions; they
    # are keyed by token only.
    def self.register!(user, token, device_id: nil, platform: nil)
      token = token.to_s.strip
      device_id = device_id.to_s.strip.presence
      platform = platform.to_s.strip.downcase
      platform = nil unless PLATFORMS.include?(platform)
      attempts = 0

      begin
        transaction do
          where(token: token).where.not(user_id: user.id).delete_all
          if device_id
            where(user_id: user.id, device_id: device_id).where.not(token: token).delete_all
          end

          record = find_or_initialize_by(token: token)
          record.user_id = user.id
          record.device_id = device_id if device_id
          record.platform = platform if platform
          record.last_seen_at = Time.zone.now
          record.save!
          record
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 2
        raise
      end
    end

    # Removes a single device. Without +token+/+device_id+ only rows created by
    # older app versions (no device_id) are removed, so other devices of the
    # same user keep receiving notifications.
    def self.unregister!(user, token: nil, device_id: nil)
      scope = where(user_id: user.id)
      token = token.to_s.strip.presence
      device_id = device_id.to_s.strip.presence

      scope =
        if token || device_id
          conditions = []
          conditions << scope.where(token: token) if token
          conditions << scope.where(device_id: device_id) if device_id
          conditions.reduce { |memo, relation| memo.or(relation) }
        else
          scope.where(device_id: nil)
        end

      scope.delete_all
    end
  end
end
