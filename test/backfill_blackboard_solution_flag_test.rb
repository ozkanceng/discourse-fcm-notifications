# frozen_string_literal: true
# Standalone unit tests: ruby test/backfill_blackboard_solution_flag_test.rb
require 'minitest/autorun'

module Jobs
  class Onceoff; end
end

module DiscourseFcmNotifications
  BLACKBOARD_SOLUTION_FIELD = 'has_blackboard_solution'

  class BlackboardSolution
    class << self
      attr_accessor :conditions
    end

    def self.where(conditions)
      self.conditions = conditions
      self
    end

    def self.distinct
      self
    end

    def self.pluck(_column)
      [1, 2]
    end
  end
end

class Topic
  attr_reader :id, :fields

  def initialize(id)
    @id = id
  end

  def upsert_custom_fields(fields)
    @fields = fields
  end

  class << self
    attr_accessor :found
  end

  def self.where(id:)
    self.found = id.map { |topic_id| new(topic_id) }
    self
  end

  def self.find_each(&block)
    found.each(&block)
  end
end

require_relative '../app/jobs/regular/backfill_blackboard_solution_flag'

class BackfillBlackboardSolutionFlagTest < Minitest::Test
  def test_flags_topics_with_a_ready_current_solution
    Jobs::BackfillBlackboardSolutionFlag.new.execute_onceoff({})

    assert_equal({ status: 'ready', schema_version: 3 }, DiscourseFcmNotifications::BlackboardSolution.conditions)
    assert_equal [1, 2], Topic.found.map(&:id)
    Topic.found.each { |topic| assert_equal({ 'has_blackboard_solution' => true }, topic.fields) }
  end
end
