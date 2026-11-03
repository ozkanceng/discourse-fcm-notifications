# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module DiscourseFcmNotifications
  # Verifies AdMob rewarded-ad server-side verification (SSV) callbacks.
  #
  # AdMob signs everything in the query string before `&signature=` with
  # ECDSA/SHA-256 (DER, web-safe base64) and names the public key in the
  # last parameter, `key_id`. Keys come from Google's key server and are
  # cached; an unknown key id refreshes the cache once.
  # https://developers.google.com/admob/android/ssv
  class AdmobSsvVerifier
    KEYS_URL = 'https://www.gstatic.com/admob/reward/verifier-keys.json'
    CACHE_SECONDS = 24 * 3600

    class Invalid < StandardError; end

    def initialize(key_fetcher: nil, clock: -> { Time.now })
      @key_fetcher = key_fetcher || method(:fetch_keys)
      @clock = clock
      @keys = nil
      @keys_at = nil
    end

    # [raw_query] is the undecoded query string. Returns the decoded params.
    def verify!(raw_query)
      raw_query = raw_query.to_s
      index = raw_query.index('&signature=')
      raise Invalid, 'missing signature' unless index

      content = raw_query[0...index]
      tail = raw_query[(index + 1)..]
      params = URI.decode_www_form(tail).to_h
      signature = params['signature'].to_s
      key_id = params['key_id'].to_s
      raise Invalid, 'missing key id' if key_id.empty? || signature.empty?

      der = Base64.urlsafe_decode64(signature + '=' * ((4 - signature.length % 4) % 4))
      key = public_key(key_id)
      raise Invalid, 'unknown key id' unless key
      valid = key.verify(OpenSSL::Digest.new('SHA256'), der, content)
      raise Invalid, 'bad signature' unless valid

      URI.decode_www_form(content).to_h
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      raise Invalid, 'malformed signature'
    end

    private

    def public_key(key_id)
      keys = cached_keys
      key = keys[key_id]
      unless key
        keys = cached_keys(force: true)
        key = keys[key_id]
      end
      key
    end

    def cached_keys(force: false)
      now = @clock.call
      if force || @keys.nil? || @keys_at.nil? || now - @keys_at > CACHE_SECONDS
        @keys = parse_keys(@key_fetcher.call)
        @keys_at = now
      end
      @keys
    end

    def parse_keys(body)
      json = body.is_a?(String) ? JSON.parse(body) : body
      Array(json['keys']).each_with_object({}) do |entry, keys|
        pem = entry['pem'].to_s
        next if pem.empty?
        keys[entry['keyId'].to_s] = OpenSSL::PKey.read(pem)
      end
    end

    def fetch_keys
      uri = URI(KEYS_URL)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
        http.get(uri.request_uri)
      end
      raise Invalid, "key server #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      response.body
    end
  end
end
