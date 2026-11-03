# frozen_string_literal: true

module DiscourseFcmNotifications
  # Kara Tahta v5 server endpoints next to the solution store:
  #   GET  /sorumatik/blackboard-quota          server-authoritative daily quota
  #   GET  /sorumatik/blackboard-rewarded/ssv   AdMob rewarded-ad callback
  #   POST /sorumatik/blackboard-help           "burayı anlamadım" free allowance
  #   POST /sorumatik/blackboard-share          opaque share token for a topic
  #   GET  /sorumatik/blackboard-share/:token   token -> topic
  class BlackboardExtrasController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr, only: [:ssv]
    skip_before_action :redirect_to_login_if_required, only: [:ssv]
    before_action :ensure_logged_in, except: [:ssv]

    REWARD_CUSTOM_DATA = 'blackboard'
    # Brain Energy rewards (BrainEnergyService) are granted by the Sorumatik API.
    ENERGY_CUSTOM_DATA = 'energy'

    def quota
      RateLimiter.new(current_user, 'sorumatik_bb_quota', 60, 1.minute).performed!
      limits = BlackboardLimits.for_request(current_user, request.headers['X-Sorumatik-Tier'])
      lease = BlackboardGeneration.new(topic_id: 0, language: 'tr', version: 5, fingerprint: 'quota',
        user_id: current_user.id, base_limit: limits[:limit])
      render json: lease.quota.merge(tier: limits[:tier], help: help_status)
    end

    # AdMob calls this URL (configured on the rewarded ad unit) after a user
    # earned a reward. The app sets custom_data "blackboard" and user_id to
    # the Discourse username. Answers 200 for anything AdMob should not
    # retry (verified or ignored) and 4xx for a bad signature.
    def ssv
      return render json: { status: 'disabled' } unless SiteSetting.blackboard_admob_ssv_enabled
      params_hash = self.class.verifier.verify!(request.query_string)
      custom = params_hash['custom_data']
      return render json: { status: 'ignored' } unless [REWARD_CUSTOM_DATA, ENERGY_CUSTOM_DATA].include?(custom)

      user = User.find_by_username(params_hash['user_id'].to_s)
      transaction_id = params_hash['transaction_id'].to_s
      unless user && transaction_id.match?(/\A[A-Za-z0-9]{8,128}\z/)
        return render json: { status: 'ignored' }
      end
      if custom == ENERGY_CUSTOM_DATA
        return render json: { status: 'ignored' } unless SorumatikApi.configured?
        result = SorumatikApi.forward_rewarded_ad(user.id, transaction_id)
        Rails.logger.info("energy rewarded_grant user=#{user.id} result=#{result}")
        return render json: { status: result.to_s }
      end
      result = BlackboardGeneration.grant_reward!(user_id: user.id, transaction_id: transaction_id)
      Rails.logger.info("blackboard rewarded_grant user=#{user.id} result=#{result}")
      render json: { status: result.to_s }
    rescue AdmobSsvVerifier::Invalid => e
      Rails.logger.warn("blackboard rewarded_ssv_rejected reason=#{e.message}")
      render json: { status: 'invalid' }, status: :forbidden
    end

    def help
      RateLimiter.new(current_user, 'sorumatik_bb_help', 20, 1.minute).performed!
      return render json: { allowed: true, unlimited: true } if unlimited_help?

      key = help_key
      limit = SiteSetting.blackboard_free_help_daily_limit
      used = Discourse.redis.incr(key)
      Discourse.redis.expireat(key, reset_at.to_i + 600) if used == 1
      if used > limit
        Discourse.redis.decr(key)
        return render json: { allowed: false, remaining: 0, limit: limit, resets_at: reset_at.iso8601 }, status: :too_many_requests
      end
      render json: { allowed: true, remaining: [limit - used, 0].max, limit: limit, resets_at: reset_at.iso8601 }
    end

    def share
      RateLimiter.new(current_user, 'sorumatik_bb_share_day', SiteSetting.blackboard_share_daily_limit, 1.day).performed!
      topic = accessible_topic(params[:topic_id])
      return render json: { error: 'not_found' }, status: :not_found unless topic
      token = BlackboardShare.create!(user: current_user, topic: topic)
      render json: { token: token, url: BlackboardShare.url(topic.id, token) }
    end

    def share_show
      RateLimiter.new(current_user, 'sorumatik_bb_share_open', 60, 1.minute).performed!
      topic_id = BlackboardShare.resolve(params[:token], viewer: current_user)
      topic = topic_id && accessible_topic(topic_id)
      return render json: { error: 'not_found' }, status: :not_found unless topic
      render json: { topic_id: topic.id, title: topic.title }
    end

    def self.verifier
      @verifier ||= AdmobSsvVerifier.new
    end

    private

    # Help stays unlimited only for verified premium: a claimed tier
    # header must not unlock more than the free allowance.
    def unlimited_help?
      BlackboardLimits.verified_premium?(current_user)
    end

    def help_status
      return { unlimited: true } if unlimited_help?
      limit = SiteSetting.blackboard_free_help_daily_limit
      { limit: limit, remaining: [limit - Discourse.redis.get(help_key).to_i, 0].max }
    end

    def help_key
      "sorumatik:blackboard:help:#{current_user.id}:#{Time.now.utc.strftime('%Y-%m-%d')}"
    end

    def reset_at
      now = Time.now.utc
      Time.utc(now.year, now.month, now.day) + 86_400
    end

    def accessible_topic(id)
      topic = Topic.find_by(id: id)
      return nil unless topic&.visible?
      return nil if topic.archetype.to_s == 'private_message' || topic.private_message?
      return nil unless Guardian.new(current_user).can_see?(topic)
      topic
    end
  end
end
