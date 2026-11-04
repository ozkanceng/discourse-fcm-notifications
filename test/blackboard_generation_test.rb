# frozen_string_literal: true
# Standalone unit tests: ruby test/blackboard_generation_test.rb
require 'minitest/autorun'
require 'time'

class Object
  def present?; respond_to?(:empty?) ? !empty? : !!self; end
end

module SiteSetting
  class << self
    attr_accessor :blackboard_daily_limit, :blackboard_rewarded_daily_limit
  end
end

# Behaves like DiscourseRedis: named commands add the namespace, EVAL does not.
class FakeNamespacedRedis
  def initialize
    @strings = {}
    @sets = Hash.new { |hash, key| hash[key] = {} }
  end

  def namespace_key(key)
    "default:#{key}"
  end

  def get(key)
    @strings[namespace_key(key)]
  end

  def exists?(key)
    @strings.key?(namespace_key(key))
  end

  def zcard(key)
    @sets[namespace_key(key)].size
  end

  def zremrangebyscore(key, _min, max)
    @sets[namespace_key(key)].delete_if { |_, score| score <= max.to_i }
  end

  def expire_slots(key, score)
    @sets[namespace_key(key)].keys.each { |member| @sets[namespace_key(key)][member] = score }
  end

  def eval(script, keys:, argv:)
    generation = DiscourseFcmNotifications::BlackboardGeneration
    case script
    when generation::RESERVE then reserve(keys, argv)
    when generation::FINISH then finish(keys, argv)
    when generation::GRANT then grant(keys, argv)
    else raise "unknown script"
    end
  end

  private

  def reserve(keys, argv)
    lock, quota = keys
    now, limit, token, lease = argv
    @sets[quota].delete_if { |_, score| score <= now.to_i }
    return 'pending' if @strings.key?(lock)
    return 'quota_exceeded' if @sets[quota].size >= limit.to_i
    @strings[lock] = token
    @sets[quota][token] = now.to_i + lease.to_i
    'owner'
  end

  def finish(keys, argv)
    lock, quota = keys
    token, action, score = argv
    return 0 unless @strings[lock] == token
    action == 'commit' ? @sets[quota][token] = score.to_i : @sets[quota].delete(token)
    @strings.delete(lock)
    1
  end

  def grant(keys, argv)
    extra, transaction = keys
    return -1 if @strings.key?(transaction)
    @strings[transaction] = '1'
    granted = @strings[extra].to_i
    return -2 if granted >= argv[0].to_i
    @strings[extra] = (granted + 1).to_s
    granted + 1
  end
end

module Discourse
  class << self
    attr_accessor :redis
  end
end

require_relative '../app/services/discourse_fcm_notifications/blackboard_generation'

class BlackboardGenerationTest < Minitest::Test
  Generation = DiscourseFcmNotifications::BlackboardGeneration

  def setup
    Discourse.redis = FakeNamespacedRedis.new
    SiteSetting.blackboard_daily_limit = 2
    SiteSetting.blackboard_rewarded_daily_limit = 2
  end

  def lease(topic_id: 1, user_id: 7, **options)
    Generation.new(topic_id: topic_id, language: 'tr', version: 3, fingerprint: 'abc', user_id: user_id, **options)
  end

  def test_reservation_is_visible_to_the_store_ownership_check
    generation = lease
    result, token = generation.reserve
    assert_equal 'owner', result
    assert generation.owner?(token)
    assert_equal 1, generation.quota[:used]
  end

  def test_another_token_does_not_own_the_reservation
    generation = lease
    _, token = generation.reserve
    refute generation.owner?("#{token}x")
  end

  def test_same_source_waits_for_the_running_generation
    lease.reserve
    assert_equal 'pending', lease.reserve.first
  end

  def test_commit_keeps_the_slot_and_releases_the_source
    generation = lease
    _, token = generation.reserve
    assert generation.finish(token, commit: true)
    refute Discourse.redis.exists?(generation.lock_key)
    assert_equal 1, generation.quota[:used]
  end

  def test_cancel_refunds_the_slot_and_releases_the_source
    generation = lease
    _, token = generation.reserve
    assert generation.finish(token, commit: false)
    refute Discourse.redis.exists?(generation.lock_key)
    assert_equal 0, generation.quota[:used]
  end

  def test_committed_generations_use_up_the_daily_limit
    2.times do |index|
      generation = lease(topic_id: index + 1)
      _, token = generation.reserve
      assert generation.finish(token, commit: true)
    end
    assert_equal 'quota_exceeded', lease(topic_id: 3).reserve.first
  end

  def test_expired_reservation_is_refunded
    generation = lease
    generation.reserve
    Discourse.redis.expire_slots(generation.quota_key, Time.now.to_i - 1)
    assert_equal 0, generation.quota[:used]
  end

  def test_rewarded_grant_raises_the_limit_once_per_transaction
    assert_equal :granted, Generation.grant_reward!(user_id: 7, transaction_id: 'ad-1')
    assert_equal :duplicate, Generation.grant_reward!(user_id: 7, transaction_id: 'ad-1')
    assert_equal 1, lease.rewarded_granted
    assert_equal 3, lease.daily_limit
  end

  def test_api_charged_reservation_finishes_on_its_own_set
    generation = lease(api_quota: true)
    result, token = generation.reserve
    assert_equal 'owner', result
    assert Generation.api_token?(token)
    assert generation.finish(token, commit: false)
    refute Discourse.redis.exists?(generation.lock_key)
  end
end
