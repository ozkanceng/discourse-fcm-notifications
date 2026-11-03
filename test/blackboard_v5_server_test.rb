# frozen_string_literal: true
# Standalone unit tests: ruby test/blackboard_v5_server_test.rb
require 'minitest/autorun'
require 'openssl'
require 'base64'
require 'json'
require 'uri'

class ApplicationController
  def self.requires_plugin(*); end
  def self.skip_before_action(*); end
  def self.before_action(*); end
end unless defined?(ApplicationController)
module DiscourseFcmNotifications
  PLUGIN_NAME = 'discourse-fcm-notifications' unless const_defined?(:PLUGIN_NAME)
end

require_relative '../app/services/discourse_fcm_notifications/admob_ssv_verifier'
require_relative '../app/controllers/discourse_fcm_notifications/blackboard_solutions_controller'

class BlackboardV5ServerTest < Minitest::Test
  Verifier = DiscourseFcmNotifications::AdmobSsvVerifier

  def setup
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    public_only = OpenSSL::PKey::EC.new(@key.group)
    public_only.public_key = @key.public_key
    @keys_json = JSON.generate('keys' => [{ 'keyId' => 3_335_741_209, 'pem' => public_only.to_pem }])
    @fetches = 0
    @verifier = Verifier.new(key_fetcher: -> { @fetches += 1; @keys_json })
  end

  def signed_query(content, key: @key, key_id: 3_335_741_209)
    signature = Base64.urlsafe_encode64(key.sign(OpenSSL::Digest.new('SHA256'), content)).delete('=')
    "#{content}&signature=#{signature}&key_id=#{key_id}"
  end

  CONTENT = 'ad_network=5450213213286189855&ad_unit=1234567890&custom_data=blackboard' \
            '&reward_amount=1&reward_item=video&timestamp=1762160000000' \
            '&transaction_id=18fa792de1bca816048293fc71035638&user_id=ay%C5%9Fe_42'

  def test_accepts_a_genuine_callback_and_decodes_params
    params = @verifier.verify!(signed_query(CONTENT))
    assert_equal 'blackboard', params['custom_data']
    assert_equal 'ayşe_42', params['user_id']
    assert_equal '18fa792de1bca816048293fc71035638', params['transaction_id']
  end

  def test_rejects_tampered_content
    query = signed_query(CONTENT).sub('reward_amount=1', 'reward_amount=9')
    assert_raises(Verifier::Invalid) { @verifier.verify!(query) }
  end

  def test_rejects_another_signer
    other = OpenSSL::PKey::EC.generate('prime256v1')
    assert_raises(Verifier::Invalid) { @verifier.verify!(signed_query(CONTENT, key: other)) }
  end

  def test_rejects_missing_signature_or_key
    assert_raises(Verifier::Invalid) { @verifier.verify!(CONTENT) }
    assert_raises(Verifier::Invalid) { @verifier.verify!("#{CONTENT}&signature=abc") }
    assert_raises(Verifier::Invalid) { @verifier.verify!("#{CONTENT}&signature=%%%&key_id=3335741209") }
  end

  def test_unknown_key_id_refreshes_once_then_fails
    @verifier.verify!(signed_query(CONTENT))
    assert_equal 1, @fetches
    assert_raises(Verifier::Invalid) { @verifier.verify!(signed_query(CONTENT, key_id: 42)) }
    assert_equal 2, @fetches
  end

  def test_keys_are_cached_between_callbacks
    3.times { @verifier.verify!(signed_query(CONTENT)) }
    assert_equal 1, @fetches
  end

  def test_audio_signature_check
    check = DiscourseFcmNotifications::BlackboardSolutionsController.method(:audio_signature_ok?)
    wav = 'RIFF' + [36].pack('V') + 'WAVEfmt ' + "\0" * 60
    assert check.call(wav, 'wav')
    refute check.call('<html>' + "\0" * 60, 'wav')
    assert check.call('ID3' + "\0" * 61, 'mp3')
    assert check.call("\xFF\xFB".b + "\0".b * 62, 'mp3')
    refute check.call('#!/bin/sh rm -rf' + ' ' * 50, 'mp3')
  end
end
