# frozen_string_literal: true
# Standalone unit tests: ruby test/sorumatik_api_test.rb
require 'minitest/autorun'
require 'base64'
require 'json'
require 'openssl'

class Object
  def blank?; respond_to?(:empty?) ? empty? : !self; end
  def present?; !blank?; end
end
module SiteSetting
  class << self
    attr_accessor :sorumatik_api_service_token, :sorumatik_api_base_url, :sorumatik_api_receipt_secret,
                  :blackboard_daily_limit, :blackboard_free_daily_limit, :blackboard_premium_daily_limit,
                  :blackboard_premium_groups
  end
end
class FakeRedis
  def initialize; @data = {}; end
  def get(key); @data[key]; end
  def setex(key, _ttl, value); @data[key] = value; end
end
module Discourse
  def self.redis; @redis ||= FakeRedis.new; end
end
class Rails
  def self.logger; @logger ||= Object.new.tap { |l| def l.warn(*); end }; end
end
require_relative '../app/services/discourse_fcm_notifications/sorumatik_api'
require_relative '../app/services/discourse_fcm_notifications/blackboard_limits'
require_relative '../app/services/discourse_fcm_notifications/blackboard_generation'

class SorumatikApiTest < Minitest::Test
  Api = DiscourseFcmNotifications::SorumatikApi
  SECRET = 'receipt-secret'

  def jwt(claims, secret: SECRET, alg: 'HS256')
    enc = ->(h) { Base64.urlsafe_encode64(JSON.generate(h), padding: false) }
    head = enc.call({ alg: alg, typ: 'JWT' })
    body = enc.call(claims)
    sig = Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', secret, "#{head}.#{body}"), padding: false)
    "#{head}.#{body}.#{sig}"
  end

  def claims(**extra)
    { iss: 'api.sorumatik.co', aud: 'sorumatik-forum', sub: '42', feature: 'blackboard',
      charge_key: 'bb:100:abcdef', exp: Time.now.to_i + 600 }.merge(extra)
  end

  def setup
    SiteSetting.sorumatik_api_service_token = 'tok'
    SiteSetting.sorumatik_api_base_url = ''
    SiteSetting.sorumatik_api_receipt_secret = SECRET
  end

  def test_receipt_for_this_user_and_topic
    assert Api.receipt_valid?(jwt(claims), user_id: 42, topic_id: 100)
  end

  def test_receipt_rejections
    refute Api.receipt_valid?(jwt(claims), user_id: 43, topic_id: 100)
    refute Api.receipt_valid?(jwt(claims), user_id: 42, topic_id: 101)
    refute Api.receipt_valid?(jwt(claims(exp: Time.now.to_i - 1)), user_id: 42, topic_id: 100)
    refute Api.receipt_valid?(jwt(claims(feature: 'ai_module')), user_id: 42, topic_id: 100)
    refute Api.receipt_valid?(jwt(claims(aud: 'other')), user_id: 42, topic_id: 100)
    refute Api.receipt_valid?(jwt(claims, secret: 'wrong'), user_id: 42, topic_id: 100)
    refute Api.receipt_valid?('not.a.jwt', user_id: 42, topic_id: 100)
    refute Api.receipt_valid?('', user_id: 42, topic_id: 100)
    SiteSetting.sorumatik_api_receipt_secret = ''
    refute Api.receipt_valid?(jwt(claims), user_id: 42, topic_id: 100)
  end

  def test_receipt_from_the_python_api
    token = ENV['PY_RECEIPT']
    skip 'set PY_RECEIPT to a token from app.sorumatik.receipts.issue' unless token
    assert Api.receipt_valid?(token, user_id: 42, topic_id: 100)
  end

  def test_configuration
    assert Api.configured?
    assert_equal 'http://172.17.0.1:8000', Api.base_url
    SiteSetting.sorumatik_api_service_token = ' '
    refute Api.configured?
  end

  def test_api_tokens_are_marked
    gen = DiscourseFcmNotifications::BlackboardGeneration
    assert gen.api_token?('42:1700000000:api:abcdef')
    refute gen.api_token?('42:1700000000:abcdef')
    refute gen.api_token?(nil)
  end

  def test_verified_pro_from_the_api_counts_as_premium
    SiteSetting.blackboard_premium_groups = ''
    SiteSetting.blackboard_premium_daily_limit = 10
    SiteSetting.blackboard_free_daily_limit = 1
    SiteSetting.blackboard_daily_limit = 5
    user = Struct.new(:id) { def staff?; false; end }.new(42)
    Api.stub(:pro?, ->(id) { id == 42 }) do
      assert_equal({ tier: 'premium', limit: 10, verified: true },
                   DiscourseFcmNotifications::BlackboardLimits.for_request(user, 'free'))
    end
    Api.stub(:pro?, ->(_) { false }) do
      assert_equal 1, DiscourseFcmNotifications::BlackboardLimits.for_request(user, 'free')[:limit]
    end
  end
end
