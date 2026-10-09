# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
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
    DEFAULT_FORMAT = 'mp3'
    ENCODER_VERSION = 'ffmpeg-lame-v1'

    def self.enrich!(payload, language:, fingerprint:)
      return payload unless enabled?
      steps = payload['steps']
      return payload unless steps.is_a?(Array)
      model = SiteSetting.blackboard_tts_model.presence || MODEL
      voice = SiteSetting.blackboard_tts_voice.presence || 'Kore'
      speed_version = SiteSetting.blackboard_tts_speed_version.presence || '1'
      format = SiteSetting.blackboard_tts_format.presence || DEFAULT_FORMAT
      format = DEFAULT_FORMAT unless %w[mp3 wav].include?(format)
      source = fingerprint.presence || Digest::SHA256.hexdigest(JSON.generate(payload))
      jobs = steps.each_with_index.filter_map do |step, step_index|
        next unless step.is_a?(Hash)
        speech = (step['speech_text'].presence || step['speech']).to_s.strip
        cue = step['cue_text'].to_s.strip
        raw_text = cue.blank? || speech.downcase.include?(cue.downcase) ? speech : [speech, cue].reject(&:blank?).join('. ')
        next if raw_text.blank?
        cleaned = clean_speech_math(raw_text, language: language)
        next if cleaned.blank?
        { index: step_index, text: cleaned }
      end
      tracks = parallel_map(jobs) do |job|
        create_track(job[:text], job[:index], source: source, language: language, model: model, voice: voice, speed_version: speed_version, format: format)
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

    def self.create_track(text, index, source:, language:, model:, voice:, speed_version:, format:)
      fingerprint = Digest::SHA256.hexdigest(text)
      cache_id = Digest::SHA256.hexdigest([model, voice, bcp47(language), speed_version, format, ENCODER_VERSION, index, fingerprint].join('|'))
      directory = Rails.root.join('public', 'uploads', 'blackboard_audio', source.to_s)
      FileUtils.mkdir_p(directory)
      pcm_path = directory.join("#{cache_id}.pcm")
      requested_path = directory.join("#{cache_id}.#{format}")
      pcm = nil
      unless File.exist?(requested_path)
        pcm = split_text(text).filter_map { |chunk| request_pcm(chunk, model: model, voice: voice, language: language) }.join
        raise 'Gemini returned no audio' if pcm.blank?
        File.binwrite(pcm_path, pcm)
        if format == 'mp3'
          begin
            File.binwrite(requested_path, encode_mp3(pcm))
          rescue StandardError => e
            Rails.logger.warn("Blackboard MP3 encoding unavailable, using WAV: #{e.message}")
            format = 'wav'
            requested_path = directory.join("#{cache_id}.wav")
            File.binwrite(requested_path, wav_bytes(pcm))
          end
        else
          File.binwrite(requested_path, wav_bytes(pcm))
        end
      end
      bytes = pcm || File.binread(pcm_path)
      {
        'step_index' => index,
        'url' => "#{Discourse.base_url}/uploads/blackboard_audio/#{source}/#{requested_path.basename}",
        'model' => model,
        'voice_name' => voice,
        'voice' => voice,
        'language' => bcp47(language),
        'format' => format,
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
      api_key = SiteSetting.blackboard_gemini_api_key
      raise 'Gemini API key missing' if api_key.blank?

      models_to_try = [model, MODEL].compact.uniq
      last_error = nil

      models_to_try.each do |target_model|
        begin
          return attempt_request_pcm(text, model: target_model, voice: voice, language: language, api_key: api_key)
        rescue StandardError => e
          last_error = e
          Rails.logger.warn("Blackboard Gemini TTS model '#{target_model}' failed: #{e.class}: #{e.message}")
        end
      end

      raise last_error || 'All Gemini TTS attempts failed'
    end
    private_class_method :request_pcm

    def self.attempt_request_pcm(text, model:, voice:, language:, api_key:)
      uri = URI("https://#{API_HOST}#{format(API_PATH, model)}")
      request = Net::HTTP::Post.new(uri)
      request['x-goog-api-key'] = api_key
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(
        contents: [{ parts: [{ text: "Read only the following explanation in #{bcp47(language)}, naturally, as a patient teacher. Pause at sentence boundaries and pronounce mathematical terms clearly: #{text}" }] }],
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName: voice.presence || 'Kore'
              }
            }
          },
        },
      )
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 45) { |http| http.request(request) }
      raise "Gemini TTS #{response.code}: #{response.body.to_s[0, 300]}" unless response.is_a?(Net::HTTPSuccess)
      body = JSON.parse(response.body)
      encoded = body.dig('candidates', 0, 'content', 'parts')&.filter_map { |part| part.dig('inlineData', 'data') || part.dig('inline_data', 'data') }&.first
      raise 'Gemini audio payload missing' if encoded.blank?
      Base64.decode64(encoded)
    end
    private_class_method :attempt_request_pcm

    def self.encode_mp3(pcm)
      ffmpeg = ENV['BLACKBOARD_FFMPEG_PATH'].presence || 'ffmpeg'
      stdout, stderr, status = Open3.capture3(
        ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 's16le', '-ar', SAMPLE_RATE.to_s,
        '-ac', CHANNELS.to_s, '-i', 'pipe:0', '-codec:a', 'libmp3lame', '-b:a', '128k', '-f', 'mp3', 'pipe:1',
        stdin_data: pcm,
      )
      raise "ffmpeg failed: #{stderr.to_s[0, 300]}" unless status.success? && stdout.present?
      stdout
    rescue Errno::ENOENT
      raise 'ffmpeg executable not found'
    end
    private_class_method :encode_mp3

    def self.wav_bytes(pcm)
      data_size = pcm.bytesize
      ["RIFF", 36 + data_size, "WAVE", "fmt ", 16, 1, CHANNELS, SAMPLE_RATE,
       SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE, CHANNELS * BYTES_PER_SAMPLE, BYTES_PER_SAMPLE * 8,
       "data", data_size].pack('A4VA4A4VvvVVvvA4V') + pcm
    end
    private_class_method :wav_bytes

    def self.split_text(text)
      return [text] if text.length <= MAX_INPUT_CHARS
      text.scan(/.{1,#{MAX_INPUT_CHARS}}(?:\s+|$)/m).presence || text.chars.each_slice(MAX_INPUT_CHARS).map(&:join)
    end
    private_class_method :split_text

    def self.bcp47(language)
      { 'tr' => 'tr-TR', 'en' => 'en-US', 'es' => 'es-ES', 'hi' => 'hi-IN', 'id' => 'id-ID' }.fetch(language.to_s.downcase, language.to_s)
    end
    private_class_method :bcp47

    def self.clean_speech_math(raw, language:)
      return '' if raw.blank?
      text = raw.to_s.dup
      text.gsub!(/[$]+|\\\(|\\\)|\\\[|\\\]/, ' ')
      text.gsub!(/\\(?:textbf|textit|mathrm|mathbf|text)\s*\{([^}]*)\}/, '\1')
      text.gsub!(/\\(?:left|right|big|Big|bigg|Bigg)[.()\[\]|\/]?/, ' ')

      is_tr = language.to_s.downcase.start_with?('tr')
      if is_tr
        text.gsub!(/\\alpha/, 'alfa')
        text.gsub!(/\\beta/, 'beta')
        text.gsub!(/\\gamma/, 'gama')
        text.gsub!(/\\delta|\\Delta/, 'delta')
        text.gsub!(/\\theta/, 'teta')
        text.gsub!(/\\pi/, 'pi')
        text.gsub!(/\\sigma/, 'sigma')
        text.gsub!(/\\lambda/, 'lamda')
        text.gsub!(/\\omega/, 'omega')
      end

      # Fractions
      while text.match?(/\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/)
        text.gsub!(/\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/) do
          is_tr ? "#{$1.strip} bölü #{$2.strip}" : "#{$1.strip} divided by #{$2.strip}"
        end
      end

      # Roots
      text.gsub!(/\\sqrt\[([^\]]+)\]\{([^{}]+)\}/) { is_tr ? "#{$1.strip} inci kök #{$2.strip}" : "#{$1.strip} root of #{$2.strip}" }
      text.gsub!(/\\sqrt\{([^{}]+)\}/) { is_tr ? "karekök #{$1.strip}" : "square root of #{$1.strip}" }
      text.gsub!(/\^\{?\\circ\}?/, is_tr ? ' derece' : ' degrees')

      # Powers & Subscripts
      text.gsub!(/([A-Za-z0-9_]+)\^2\b/, is_tr ? '\1 kare' : '\1 squared')
      text.gsub!(/([A-Za-z0-9_]+)\^3\b/, is_tr ? '\1 küp' : '\1 cubed')
      text.gsub!(/\^\{?([0-9A-Za-z+-]+)\}?/, is_tr ? ' üzeri \1' : ' to the power of \1')
      text.gsub!(/([A-Za-z])_\{?([0-9]+)\}?/, '\1 \2')
      text.gsub!(/([A-Za-z])_\{?([A-Za-z])\}?/, '\1 \2')

      if is_tr
        text.gsub!(/\\cdot|\\times/, ' çarpı ')
        text.gsub!(/\\div/, ' bölü ')
        text.gsub!(/\\pm|\\mp/, ' artı eksi ')
        text.gsub!(/\\leq|\\le/, ' küçük eşittir ')
        text.gsub!(/\\geq|\\ge/, ' büyük eşittir ')
        text.gsub!(/\\neq|\\ne/, ' eşit değildir ')
        text.gsub!(/\\approx/, ' yaklaşık olarak ')
        text.gsub!(/\\to|\\rightarrow/, ' giderken ')
        text.gsub!(/\\infty/, ' sonsuz ')
        text.gsub!(/\\sum/, ' toplam ')
        text.gsub!(/\\int/, ' integral ')
      end

      unless is_tr
        text.gsub!(/\\cdot|\\times/, ' times ')
        text.gsub!(/\\div/, ' divided by ')
        text.gsub!(/\\pm|\\mp/, ' plus or minus ')
        text.gsub!(/\\leq|\\le/, ' less than or equal to ')
        text.gsub!(/\\geq|\\ge/, ' greater than or equal to ')
        text.gsub!(/\\neq|\\ne/, ' not equal to ')
        text.gsub!(/\\approx/, ' approximately ')
        text.gsub!(/\\to|\\rightarrow/, ' approaches ')
        text.gsub!(/\\infty/, ' infinity ')
      end
      phrases = ['divided by', 'square root of', 'to the power of', 'squared', 'cubed', 'degrees', 'times', 'plus or minus', 'less than or equal to', 'greater than or equal to', 'not equal to', 'approximately', 'approaches', 'infinity']
      dictionaries = {
        'es' => ['dividido por', 'raíz cuadrada de', 'elevado a', 'al cuadrado', 'al cubo', 'grados', 'por', 'más o menos', 'menor o igual que', 'mayor o igual que', 'distinto de', 'aproximadamente', 'tiende a', 'infinito'],
        'hi' => ['भाग', 'वर्गमूल', 'की घात', 'का वर्ग', 'का घन', 'डिग्री', 'गुणा', 'जोड़ या घटाव', 'से कम या बराबर', 'से अधिक या बराबर', 'के बराबर नहीं', 'लगभग', 'की ओर', 'अनंत'],
        'id' => ['dibagi', 'akar kuadrat dari', 'pangkat', 'kuadrat', 'kubik', 'derajat', 'kali', 'plus atau minus', 'kurang dari atau sama dengan', 'lebih dari atau sama dengan', 'tidak sama dengan', 'kira-kira', 'mendekati', 'tak hingga'],
      }
      words = dictionaries[language.to_s.downcase.split(/[-_]/).first]
      phrases.each_with_index { |phrase, index| text.gsub!(/\b#{Regexp.escape(phrase)}\b/, words[index]) } if words

      text.gsub!(/\\[a-zA-Z]+/, ' ')
      text.gsub!(/[\\]/, ' ')
      text.gsub!(/[{}]/, ' ')
      text.squeeze(' ').strip
    end
    private_class_method :clean_speech_math
  end
end
