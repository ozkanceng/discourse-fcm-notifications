# frozen_string_literal: true
# Standalone unit tests: ruby test/blackboard_speech_test.rb
require 'minitest/autorun'
require_relative '../app/services/discourse_fcm_notifications/blackboard_tts_service'
# The production host supplies ActiveSupport; the pure cleaner only needs blank?.
class String
  def blank?; strip.empty?; end
end
class BlackboardSpeechTest < Minitest::Test
  def clean(text, language)
    DiscourseFcmNotifications::BlackboardTtsService.send(:clean_speech_math, text, language: language)
  end
  def test_fractions_and_roots_in_all_supported_languages
    { 'tr' => ['bölü', 'karekök'], 'en' => ['divided by', 'square root of'],
      'es' => ['dividido por', 'raíz cuadrada de'], 'hi' => ['भाग', 'वर्गमूल'],
      'id' => ['dibagi', 'akar kuadrat dari'] }.each do |language, expected|
      output = clean('\\frac{1}{2} \\sqrt{9}', language)
      expected.each { |word| assert_includes output, word }
      refute_includes output, '\\'
    end
  end
  def test_nested_fractions_terminate_without_dropping_values
    assert_equal '1 bölü 2 bölü 3', clean('\\frac{1}{\\frac{2}{3}}', 'tr')
  end
  def test_formatting_preserves_words
    assert_equal 'Sonuç 24', clean('\\textbf{Sonuç} 24', 'tr')
  end
  def test_tts_fallback_is_a_speech_model
    assert_match(/tts/, DiscourseFcmNotifications::BlackboardTtsService::MODEL)
  end
end
