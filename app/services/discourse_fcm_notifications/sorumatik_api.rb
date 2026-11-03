# frozen_string_literal: true

require 'net/http'
require 'json'
require 'openssl'
require 'base64'

module DiscourseFcmNotifications
  # Calls to the Sorumatik API (api.sorumatik.co) over the Docker bridge, with
  # the forum's service token. The address and token are the settings of the
  # discourse-sorumatik-ocr plugin (sorumatik_api_base_url / _service_token);
  # without them nothing here is used and the plugin behaves as before.
  module SorumatikApi
    CACHE_SECONDS = 300

    module_function

    def configured?(site_setting: SiteSetting)
      site_setting.respond_to?(:sorumatik_api_service_token) && site_setting.sorumatik_api_service_token.to_s.strip != ''
    end

    def base_url(site_setting: SiteSetting)
      url = site_setting.respond_to?(:sorumatik_api_base_url) ? site_setting.sorumatik_api_base_url.to_s.strip : ''
      url.empty? ? 'http://172.17.0.1:8000' : url.chomp('/')
    end

    def request(method, path, body: nil, timeout: 5, site_setting: SiteSetting)
      uri = URI("#{base_url(site_setting: site_setting)}#{path}")
      req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      req['X-Sorumatik-Service-Token'] = site_setting.sorumatik_api_service_token.to_s
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 3,
                                 read_timeout: timeout) { |http| http.request(req) }
      raise "Sorumatik API #{response.code}" unless response.code.to_i == 200
      JSON.parse(response.body)
    end

    # Verified PRO from the API (store purchase or trial), cached for 5 minutes.
    # nil when the API is not configured or not reachable.
    def entitlement(user_id, redis: Discourse.redis)
      return nil unless configured? && user_id
      key = "sorumatik:api:entitlement:#{user_id}"
      cached = redis.get(key)
      return JSON.parse(cached) if cached
      data = request(:get, "/internal/v1/sorumatik/entitlements/#{user_id.to_i}")
      redis.setex(key, CACHE_SECONDS, JSON.generate(data))
      data
    rescue StandardError => e
      Rails.logger.warn("sorumatik_api entitlement_failed user=#{user_id} error=#{e.class}")
      nil
    end

    def pro?(user_id)
      entitlement(user_id)&.fetch('is_pro', false) == true
    end

    # Server-side narration (Kara Tahta audio job): WAV bytes.
    def tts_wav(text, voice:, model: nil)
      data = request(:post, '/internal/v1/ai/tts', body: { text: text, voice: voice, model: model }.compact, timeout: 70)
      Base64.decode64(data.fetch('audio_base64'))
    end

    # A verified AdMob reward for Brain Energy; the API grants and counts it.
    def forward_rewarded_ad(user_id, transaction_id)
      request(:post, '/internal/v1/sorumatik/rewards/rewarded-ad',
              body: { discourse_user_id: user_id.to_i, transaction_id: transaction_id }).fetch('status', 'error')
    rescue StandardError => e
      Rails.logger.warn("sorumatik_api rewarded_forward_failed user=#{user_id} error=#{e.class}")
      'error'
    end

    # Charge receipt from the API's `done` event: HS256 JWT, audience sorumatik-forum.
    # Valid only for this user, the blackboard feature and a charge key of this topic.
    def receipt_valid?(token, user_id:, topic_id:, secret: nil, now: Time.now.to_i)
      secret ||= SiteSetting.respond_to?(:sorumatik_api_receipt_secret) ? SiteSetting.sorumatik_api_receipt_secret.to_s : ''
      return false if secret.empty? || token.to_s.count('.') != 2

      header, payload, signature = token.split('.')
      expected = Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', secret, "#{header}.#{payload}"), padding: false)
      return false unless secure_compare(expected, signature)
      head = JSON.parse(Base64.urlsafe_decode64(pad(header)))
      claims = JSON.parse(Base64.urlsafe_decode64(pad(payload)))
      head['alg'] == 'HS256' && claims['aud'] == 'sorumatik-forum' && claims['exp'].to_i > now &&
        claims['sub'].to_s == user_id.to_s && claims['feature'] == 'blackboard' &&
        claims['charge_key'].to_s.start_with?("bb:#{topic_id}:")
    rescue ArgumentError, JSON::ParserError
      false
    end

    def pad(part)
      part + '=' * ((4 - part.length % 4) % 4)
    end

    # Constant time, so the signature cannot be guessed byte by byte.
    def secure_compare(a, b)
      b = b.to_s
      return false unless a.bytesize == b.bytesize
      a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
    end
  end
end
