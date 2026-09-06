# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

module DiscourseFcmNotifications
  class BlackboardTtsService
    API_HOST = 'generativelanguage.googleapis.com'
    API_PATH = '/v1beta/models/%s:generateContent'
    MODEL = 'gemini-2.5-flash-preview-tts'
    SAMPLE_RATE = 24_000
    CHANNELS = 1
    BYTES_PER_SAMPLE = 2
    MAX_INPUT_CHARS = 4096
    MAX_CONCURRENCY = 4

    def self.enrich!(payload, language:, fingerprint:)
      return payload unless enabled?
      steps = payload['steps']
      return payload unless steps.is_a?(Array)
      model = SiteSetting.blackboard_tts_model.presence || MODEL
      voice = SiteSetting.blackboard_tts_voice.presence || 'Kore'
      speed_version = SiteSetting.blackboard_tts_speed_version.presence || '1'
      source = fingerprint.presence || Digest::SHA256.hexdigest(JSON.generate(payload))
      jobs = steps.each_with_index.filter_map do |step, step_index|
        next unless step.is_a?(Hash)
        text = [step['speech_text'], step['speech'], step['cue_text']].compact.map(&:to_s).map(&:strip).reject(&:blank?).join('. ')
        next if text.blank?
        { index: step_index, text: text }
      end
      tracks = parallel_map(jobs) do |job|
        create_track(job[:text], job[:index], source: source, language: language, model: model, voice: voice, speed_version: speed_version)
      end.compact.sort_by { |track| track['step_index'] }
      payload['audio'] = {
        'status' => tracks.length == jobs.length && tracks.any? ? 'ready' : 'failed',
        'model' => model,
        'voice_name' => voice,
        'voice' => voice,
        'language' => bcp47(language),
        'source_fingerprint' => source,
        'speed_version' => speed_version,
        'tracks' => tracks,
      }
      payload
    rescue StandardError => e
      Rails.logger.warn("Blackboard Gemini TTS unavailable: #{e.class}: #{e.message}")
      payload['audio'] = { 'status' => 'failed' }
      payload
    end

    def self.enabled?
      SiteSetting.respond_to?(:blackboard_tts_enabled?) && SiteSetting.blackboard_tts_enabled? &&
        SiteSetting.respond_to?(:blackboard_gemini_api_key) && SiteSetting.blackboard_gemini_api_key.present?
    end
    private_class_method :enabled?

    def self.create_track(text, index, source:, language:, model:, voice:, speed_version:)
      fingerprint = Digest::SHA256.hexdigest(text)
      cache_id = Digest::SHA256.hexdigest([model, voice, bcp47(language), speed_version, index, fingerprint].join('|'))
      directory = Rails.root.join('public', 'uploads', 'blackboard_audio', source.to_s)
      FileUtils.mkdir_p(directory)
      filename = "#{cache_id}.wav"
      path = directory.join(filename)
      pcm = nil
      unless File.exist?(path)
        pcm = split_text(text).filter_map { |chunk| request_pcm(chunk, model: model, voice: voice, language: language) }.join
        raise 'Gemini returned no audio' if pcm.blank?
        File.binwrite(path, wav_bytes(pcm))
      end
      bytes = pcm || wav_data(path)
      {
        'step_index' => index,
        'url' => "#{Discourse.base_url}/uploads/blackboard_audio/#{source}/#{filename}",
        'model' => model,
        'voice_name' => voice,
        'voice' => voice,
        'language' => bcp47(language),
        'format' => 'wav',
        'sample_rate' => SAMPLE_RATE,
        'duration_ms' => ((bytes.bytesize * 1000.0) / (SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE)).round,
        'source_fingerprint' => source,
        'speed_version' => speed_version,
      }
    end
    private_class_method :create_track

    def self.parallel_map(items)
      return [] if items.empty?
      queue = Queue.new
      items.each_with_index { |item, index| queue << [index, item] }
      results = Array.new(items.length)
      workers = [MAX_CONCURRENCY, items.length].min.times.map do
        Thread.new do
          loop do
            pair = (queue.pop(true) rescue nil)
            break unless pair
            index, item = pair
            begin
              results[index] = yield(item)
            rescue StandardError => e
              Rails.logger.warn("Blackboard Gemini TTS step #{index} failed: #{e.class}: #{e.message}")
            end
          end
        end
      end
      workers.each(&:join)
      results
    end
    private_class_method :parallel_map

    def self.request_pcm(text, model:, voice:, language:)
      uri = URI("https://#{API_HOST}#{format(API_PATH, model)}")
      request = Net::HTTP::Post.new(uri)
      request['x-goog-api-key'] = SiteSetting.blackboard_gemini_api_key
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(
        contents: [{ parts: [{ text: "Read this educational explanation naturally and clearly: #{text}" }] }],
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: { languageCode: bcp47(language), voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
        },
      )
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |http| http.request(request) }
      raise "Gemini TTS #{response.code}: #{response.body.to_s[0, 300]}" unless response.is_a?(Net::HTTPSuccess)
      body = JSON.parse(response.body)
      encoded = body.dig('candidates', 0, 'content', 'parts')&.filter_map { |part| part.dig('inlineData', 'data') || part.dig('inline_data', 'data') }&.first
      raise 'Gemini audio payload missing' if encoded.blank?
      Base64.decode64(encoded)
    end
    private_class_method :request_pcm

    def self.wav_bytes(pcm)
      data_size = pcm.bytesize
      ["RIFF", 36 + data_size, "WAVE", "fmt ", 16, 1, CHANNELS, SAMPLE_RATE,
       SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE, CHANNELS * BYTES_PER_SAMPLE, BYTES_PER_SAMPLE * 8,
       "data", data_size].pack('A4VA4A4VvvVVvvA4V') + pcm
    end
    private_class_method :wav_bytes

    def self.wav_data(path)
      bytes = File.binread(path)
      bytes.byteslice(44..-1) || ''.b
    rescue StandardError
      ''.b
    end
    private_class_method :wav_data

    def self.split_text(text)
      return [text] if text.length <= MAX_INPUT_CHARS
      text.scan(/.{1,#{MAX_INPUT_CHARS}}(?:\s+|$)/m).presence || text.chars.each_slice(MAX_INPUT_CHARS).map(&:join)
    end
    private_class_method :split_text

    def self.bcp47(language)
      { 'tr' => 'tr-TR', 'en' => 'en-US', 'es' => 'es-ES', 'hi' => 'hi-IN', 'id' => 'id-ID' }.fetch(language.to_s.downcase, language.to_s)
    end
    private_class_method :bcp47
  end
end
