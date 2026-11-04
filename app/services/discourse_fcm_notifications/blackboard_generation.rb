# frozen_string_literal: true
require 'securerandom'

module DiscourseFcmNotifications
  # One atomic Redis operation reserves both source ownership and an account
  # slot. Expired reservations are refunded; completed generations last until
  # the UTC day boundary. A replay never reserves a slot.
  class BlackboardGeneration
    LEASE_SECONDS = 600
    RESERVE = <<~LUA
      redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[1])
      if redis.call('EXISTS', KEYS[1]) == 1 then return 'pending' end
      if redis.call('ZCARD', KEYS[2]) >= tonumber(ARGV[2]) then return 'quota_exceeded' end
      redis.call('SET', KEYS[1], ARGV[3], 'EX', ARGV[4])
      redis.call('ZADD', KEYS[2], tonumber(ARGV[1]) + tonumber(ARGV[4]), ARGV[3])
      redis.call('EXPIREAT', KEYS[2], ARGV[5])
      return 'owner'
    LUA
    FINISH = <<~LUA
      if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
      if ARGV[2] == 'commit' then
        redis.call('ZADD', KEYS[2], ARGV[3], ARGV[1])
      else
        redis.call('ZREM', KEYS[2], ARGV[1])
      end
      redis.call('DEL', KEYS[1])
      return 1
    LUA
    # Grants one extra slot for a verified rewarded ad: once per AdMob
    # transaction, at most ARGV[1] per user and UTC day.
    GRANT = <<~LUA
      if redis.call('SET', KEYS[2], '1', 'NX', 'EX', 172800) == false then return -1 end
      local granted = tonumber(redis.call('GET', KEYS[1]) or '0')
      if granted >= tonumber(ARGV[1]) then return -2 end
      redis.call('INCR', KEYS[1])
      redis.call('EXPIREAT', KEYS[1], ARGV[2])
      return granted + 1
    LUA

    attr_reader :lock_key, :quota_key, :reset_at
    # [base_limit] comes from BlackboardLimits (tier of this request).
    # api_quota: the Sorumatik API charged this generation, so only the source
    # lock is taken here; its slots go to a separate set that is never counted.
    def initialize(topic_id:, language:, version:, fingerprint:, user_id:, base_limit: nil, api_quota: false)
      @base_limit = base_limit
      @lock_key = "sorumatik:blackboard:#{topic_id}:#{language}:#{version}:#{fingerprint}"
      @user_id = user_id
      now = Time.now.utc
      @reset_at = Time.utc(now.year, now.month, now.day) + 86_400
      @api_quota = api_quota
      @quota_key = "sorumatik:blackboard:#{api_quota ? 'apiquota' : 'quota'}:#{user_id}:#{now.strftime('%Y-%m-%d')}"
      @extra_key = self.class.extra_key(user_id, now)
    end

    # Redis EVAL receives keys as given, while get/zcard/exists? add the Discourse
    # namespace. Script keys must carry it too or both sides miss each other.
    def self.script_keys(*keys)
      keys.map { |key| Discourse.redis.namespace_key(key) }
    end

    def self.extra_key(user_id, now = Time.now.utc)
      "sorumatik:blackboard:extra:#{user_id}:#{now.utc.strftime('%Y-%m-%d')}"
    end

    def self.rewarded_limit
      SiteSetting.respond_to?(:blackboard_rewarded_daily_limit) ? SiteSetting.blackboard_rewarded_daily_limit.to_i : 2
    end

    # Adds one generation for today after a verified rewarded ad.
    # Returns :granted, :duplicate (same transaction) or :limit_reached.
    def self.grant_reward!(user_id:, transaction_id:, now: Time.now.utc)
      reset = Time.utc(now.year, now.month, now.day) + 86_400
      result = Discourse.redis.eval(GRANT,
        keys: script_keys(extra_key(user_id, now), "sorumatik:blackboard:ssv:#{transaction_id}"),
        argv: [rewarded_limit, reset.to_i + LEASE_SECONDS]).to_i
      case result
      when -1 then :duplicate
      when -2 then :limit_reached
      else :granted
      end
    end

    def rewarded_granted
      Discourse.redis.get(@extra_key).to_i
    end

    # Daily generations: the base limit plus today's rewarded extras.
    def base_limit
      (@base_limit || SiteSetting.blackboard_daily_limit).to_i
    end

    def api_quota?
      @api_quota
    end

    # API-charged generations are limited by the API, not here.
    def daily_limit
      @api_quota ? 1_000_000 : base_limit + rewarded_granted
    end

    # Tokens of API-charged reservations carry an "api" part, so storing one
    # always needs a charge receipt, whatever headers the store call sends.
    def self.api_token?(token)
      token.to_s.split(':')[2] == 'api'
    end

    def reserve
      token = "#{@user_id}:#{reset_at.to_i}:#{@api_quota ? 'api:' : ''}#{SecureRandom.hex(24)}"
      result = Discourse.redis.eval(RESERVE, keys: self.class.script_keys(lock_key, quota_key), argv: [Time.now.to_i, daily_limit, token, LEASE_SECONDS, reset_at.to_i + LEASE_SECONDS])
      [result, result == 'owner' ? token : nil]
    end

    def owner?(token)
      token.present? && token.start_with?("#{@user_id}:") && Discourse.redis.get(lock_key) == token
    end

    def finish(token, commit:)
      return false unless owner?(token)
      reserved_reset = Integer(token.split(':')[1], exception: false)
      return false unless reserved_reset
      reserved_date = Time.at(reserved_reset - 86_400).utc.strftime('%Y-%m-%d')
      namespace = self.class.api_token?(token) ? 'apiquota' : 'quota'
      reserved_key = "sorumatik:blackboard:#{namespace}:#{@user_id}:#{reserved_date}"
      Discourse.redis.eval(FINISH, keys: self.class.script_keys(lock_key, reserved_key), argv: [token, commit ? 'commit' : 'cancel', reserved_reset]).to_i == 1
    end

    def quota
      Discourse.redis.zremrangebyscore(quota_key, '-inf', Time.now.to_i)
      granted = rewarded_granted
      limit = base_limit + granted
      used = Discourse.redis.zcard(quota_key)
      {
        limit: limit,
        used: [used, limit].min,
        remaining: [limit - used, 0].max,
        reset_at: reset_at.iso8601,
        resets_at: reset_at.iso8601,
        rewarded_granted: granted,
        rewarded_available: [self.class.rewarded_limit - granted, 0].max,
      }
    end
  end
end
