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

    attr_reader :lock_key, :quota_key, :reset_at
    def initialize(topic_id:, language:, version:, fingerprint:, user_id:)
      @lock_key = "sorumatik:blackboard:#{topic_id}:#{language}:#{version}:#{fingerprint}"
      @user_id = user_id
      now = Time.now.utc
      @reset_at = Time.utc(now.year, now.month, now.day) + 86_400
      @quota_key = "sorumatik:blackboard:quota:#{user_id}:#{now.strftime('%Y-%m-%d')}"
    end

    def reserve
      token = "#{@user_id}:#{reset_at.to_i}:#{SecureRandom.hex(24)}"
      result = Discourse.redis.eval(RESERVE, keys: [lock_key, quota_key], argv: [Time.now.to_i, SiteSetting.blackboard_daily_limit, token, LEASE_SECONDS, reset_at.to_i + LEASE_SECONDS])
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
      reserved_key = "sorumatik:blackboard:quota:#{@user_id}:#{reserved_date}"
      Discourse.redis.eval(FINISH, keys: [lock_key, reserved_key], argv: [token, commit ? 'commit' : 'cancel', reserved_reset]).to_i == 1
    end

    def quota
      Discourse.redis.zremrangebyscore(quota_key, '-inf', Time.now.to_i)
      limit = SiteSetting.blackboard_daily_limit
      { limit: limit, remaining: [limit - Discourse.redis.zcard(quota_key), 0].max, reset_at: reset_at.iso8601 }
    end
  end
end
