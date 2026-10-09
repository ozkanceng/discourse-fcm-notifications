# frozen_string_literal: true

require "minitest/autorun"

# The ownership guard executes before any Rails, provider, or MessageBus work.
class Numeric
  def minutes
    self * 60
  end
end

module DiscourseFcmNotifications
end

module SiteSetting
  def self.sorumatik_ai_live_streaming_enabled?
    false
  end
end

module SorumatikOcr
  class AnswerGeneration
    class << self
      attr_accessor :managed_checks

      def managed_source?(_source)
        self.managed_checks += 1
        false
      end

      def start!(_source)
        raise "Mobile ownership must prevent server generation"
      end
    end
  end
end

require_relative "../lib/discourse_fcm_notifications/ai_answer_streaming"

class MobileAnswerOwnershipTest < Minitest::Test
  Source = Struct.new(:custom_fields)

  class NativeRunner
    attr_reader :native_calls

    def initialize
      @native_calls = 0
    end

    def reply_to(_source, *args, **kwargs, &callback)
      @native_calls += 1
      callback&.call("Legacy answer")
      [args, kwargs]
    end
  end

  class Runner < NativeRunner
    prepend DiscourseFcmNotifications::AiAnswerStreaming
  end

  def setup
    SorumatikOcr::AnswerGeneration.managed_checks = 0
    @runner = Runner.new
  end

  def test_protocol_two_never_calls_server_adapter_or_native_provider
    source = Source.new("client_edge_solve" => "true", "mobile_answer_protocol" => "2")
    assert_nil @runner.reply_to(source) { flunk "Mobile source must not stream" }
    assert_equal 0, @runner.native_calls
    assert_equal 0, SorumatikOcr::AnswerGeneration.managed_checks
  end

  def test_future_mobile_protocol_keeps_mobile_ownership
    source = Source.new("client_edge_solve" => true, "mobile_answer_protocol" => 3)
    assert_nil @runner.reply_to(source)
    assert_equal 0, @runner.native_calls
  end

  def test_old_mobile_flag_preserves_legacy_provider_arguments_and_callback
    source = Source.new("client_edge_solve" => "true")
    deltas = []
    assert_equal [["context"], { feature: true }],
      @runner.reply_to(source, "context", feature: true) { |delta| deltas << delta }
    assert_equal ["Legacy answer"], deltas
    assert_equal 1, @runner.native_calls
  end

  def test_protocol_one_keeps_legacy_flow
    source = Source.new("client_edge_solve" => "true", "mobile_answer_protocol" => "1")
    @runner.reply_to(source)
    assert_equal 1, @runner.native_calls
  end

  def test_protocol_without_mobile_flag_keeps_web_flow
    source = Source.new("mobile_answer_protocol" => "2")
    @runner.reply_to(source)
    assert_equal 1, @runner.native_calls
  end

  def test_unmarked_web_source_keeps_native_flow
    @runner.reply_to(Source.new({}))
    assert_equal 1, @runner.native_calls
    assert_equal 1, SorumatikOcr::AnswerGeneration.managed_checks
  end
end
