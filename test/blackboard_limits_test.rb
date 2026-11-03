# frozen_string_literal: true
# Standalone unit tests: ruby test/blackboard_limits_test.rb
require 'minitest/autorun'

class Object
  def blank?; respond_to?(:empty?) ? empty? : !self; end
end
module SiteSetting
  class << self
    attr_accessor :blackboard_daily_limit, :blackboard_free_daily_limit,
                  :blackboard_premium_daily_limit, :blackboard_premium_groups
  end
end
require_relative '../app/services/discourse_fcm_notifications/blackboard_limits'

class BlackboardLimitsTest < Minitest::Test
  Limits = DiscourseFcmNotifications::BlackboardLimits
  Groups = Struct.new(:names) do
    def where(name:); Groups.new(names & name); end
    def exists?; !names.empty?; end
  end
  User = Struct.new(:staff, :group_names) do
    def staff?; staff; end
    def groups; Groups.new(group_names); end
  end

  def setup
    SiteSetting.blackboard_daily_limit = 5
    SiteSetting.blackboard_free_daily_limit = 1
    SiteSetting.blackboard_premium_daily_limit = 10
    SiteSetting.blackboard_premium_groups = ''
  end

  def student
    User.new(false, [])
  end

  def test_free_header_gets_one_a_day
    assert_equal({ tier: 'free', limit: 1, verified: false }, Limits.for_request(student, 'free'))
  end

  def test_premium_header_gets_ten
    assert_equal 10, Limits.for_request(student, 'Premium')[:limit]
  end

  def test_older_apps_without_header_keep_the_old_limit
    assert_equal({ tier: 'legacy', limit: 5, verified: false }, Limits.for_request(student, nil))
    assert_equal 5, Limits.for_request(student, 'gold')[:limit]
  end

  def test_group_members_and_staff_are_premium_whatever_they_send
    SiteSetting.blackboard_premium_groups = 'premium|vip'
    member = User.new(false, ['vip'])
    assert_equal({ tier: 'premium', limit: 10, verified: true }, Limits.for_request(member, 'free'))
    staff = Limits.for_request(User.new(true, []), nil)
    assert_equal 'staff', staff[:tier]
    assert_equal 10, staff[:limit]
  end
end
