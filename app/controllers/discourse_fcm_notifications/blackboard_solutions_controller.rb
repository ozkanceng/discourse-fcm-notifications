# frozen_string_literal: true
require 'digest'

module DiscourseFcmNotifications
  class BlackboardSolutionsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :preload_json
    before_action :ensure_blackboard_access

    def show
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      solution = ready_solution(topic)
      return render json: { available: false, status: Discourse.redis.exists?(generation(topic).lock_key) ? 'pending' : 'missing', quota: generation(topic).quota } unless solution

      render json: {
        available: true,
        solution: solution.solution_json,
        updated_at: solution.updated_at,
        quota: generation(topic).quota,
      }
    end

    # Generation is intentionally asynchronous. The mobile client performs the
    # server-side AI request through the existing Discourse AI flow and stores
    # the validated result with #store. This endpoint lets clients initiate the
    # flow without creating duplicate records while another request is running.
    def generate
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      solution = ready_solution(topic)
      if solution
        return render json: {
          available: true,
          solution: solution.solution_json,
          updated_at: solution.updated_at,
        quota: generation(topic).quota,
        }
      end

      return render json: { error: 'invalid_fingerprint' }, status: :unprocessable_entity unless valid_fingerprint?
      status, token = generation(topic).reserve
      if status == 'quota_exceeded'
        return render json: { error: status, quota: generation(topic).quota }, status: :too_many_requests
      end
      render json: { available: false, status: 'pending', owner: status == 'owner',
                     generation_token: token, quota: generation(topic).quota }, status: :accepted
    end

    def cancel
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic
      generation(topic).finish(params[:generation_token].to_s, commit: false)
      render json: { status: 'cancelled' }
    end

    def store
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      previous = ready_solution(topic)
      digest = Digest::SHA256.hexdigest(params[:generation_token].to_s)
      if previous
        if previous.generated_by_id == current_user.id && previous.generation_digest == digest
          return render json: { available: true, solution: previous.solution_json }
        end
        return render json: { error: 'generation_ownership_required' }, status: :conflict
      end
      lease = generation(topic)
      unless valid_fingerprint? && lease.owner?(params[:generation_token].to_s)
        return render json: { error: 'generation_ownership_required' }, status: :conflict
      end
      # A slot reserved without counting (the API charged it) is stored only with the API's receipt.
      if BlackboardGeneration.api_token?(params[:generation_token]) &&
         !SorumatikApi.receipt_valid?(params[:charge_receipt].to_s, user_id: current_user.id, topic_id: topic.id)
        lease.finish(params[:generation_token].to_s, commit: false)
        return render json: { error: 'charge_receipt_required' }, status: :payment_required
      end
      payload = params[:solution]
      return render json: { error: 'invalid_solution' }, status: :unprocessable_entity unless payload.respond_to?(:to_h)
      payload = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h

      # v5 solutions carry `schema_version`; v1-v3 carry `version`.
      payload_version = (v5? ? payload['schema_version'] : payload['version']).to_i
      return render json: { error: 'invalid_solution' }, status: :unprocessable_entity unless payload_version == requested_schema_version
      record = BlackboardSolution.new(
        topic_id: topic.id,
        language: language,
        schema_version: payload_version,
        source_fingerprint: params[:source_fingerprint],
      )
      source_post_id = Integer(params[:source_post_id], exception: false)
      source_post = source_post_id && topic.posts.find_by(id: source_post_id)
      record.source_post_id = source_post&.id || topic.posts.order(:post_number).last&.id
      fingerprint = params[:source_fingerprint].to_s
      record.source_fingerprint = fingerprint.match?(/\A[a-f0-9]{8,128}\z/i) ? fingerprint : nil
      # Client-supplied audio URLs are never trusted or persisted.
      payload.delete('audio')
      payload.delete('audio_tracks')
      payload['language'] = language
      # v5 narration is synthesized per sentence by the app through the TTS
      # proxy, so no server audio job runs for it.
      payload['audio'] = v5? ? { 'status' => 'client', 'tracks' => [] } : { 'status' => 'pending', 'tracks' => [] }
      record.generation_digest = digest
      record.generated_by_id = current_user.id
      record.solution_json = payload
      record.status = 'ready'
      unless record.valid?
        lease.finish(params[:generation_token].to_s, commit: false)
        return render json: { error: 'invalid_solution' }, status: :unprocessable_entity
      end
      BlackboardSolution.transaction do
        record.save!
        unless lease.finish(params[:generation_token].to_s, commit: true)
          raise ActiveRecord::Rollback
        end
      end
      unless record.persisted?
        return render json: { error: 'generation_ownership_required' }, status: :conflict
      end
      Jobs.enqueue(:blackboard_audio, solution_id: record.id) unless v5?
      Rails.logger.info("blackboard generation_stored topic=#{topic.id} user=#{current_user.id}")
      render json: { available: true, solution: record.solution_json, quota: lease.quota }, status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { error: 'generation_ownership_required' }, status: :conflict
    end

    def upload_audio
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      solution = ready_solution(topic)
      solution ||= BlackboardSolution.where(
        topic_id: topic.id,
        status: 'ready',
      ).order(created_at: :desc).first
      return render json: { error: 'solution_not_found' }, status: :not_found unless solution
      # Files land in public uploads: only the student who generated this
      # solution (or staff) may add its narration.
      unless current_user.staff? || solution.generated_by_id == current_user.id
        return render json: { error: 'generation_ownership_required' }, status: :forbidden
      end
      RateLimiter.new(current_user, 'sorumatik_bb_audio_upload', 60, 1.minute).performed!

      step_index = Integer(params[:step_index], exception: false)
      total_steps = solution.solution_json['steps']&.size.to_i
      unless step_index && step_index >= 0 && step_index < [total_steps, 40].min
        return render json: { error: 'invalid_step_index' }, status: :unprocessable_entity
      end
      file = params[:file]
      duration_ms = params[:duration_ms].to_i
      format = params[:format].to_s.presence || (file.respond_to?(:original_filename) && file.original_filename.end_with?('.wav') ? 'wav' : 'mp3')
      format = 'mp3' unless %w[mp3 wav].include?(format)
      voice = params[:voice].to_s.presence || 'Kore'

      return render json: { error: 'invalid_audio_file' }, status: :unprocessable_entity unless file && file.respond_to?(:read)
      bytes = file.read(MAX_AUDIO_BYTES + 1).to_s
      unless bytes.bytesize.between?(64, MAX_AUDIO_BYTES) && self.class.audio_signature_ok?(bytes, format)
        return render json: { error: 'invalid_audio_file' }, status: :unprocessable_entity
      end

      source = solution.source_fingerprint.presence || topic.id.to_s
      directory = Rails.root.join('public', 'uploads', 'blackboard_audio', source)
      FileUtils.mkdir_p(directory)

      filename = "step_#{step_index}_#{Digest::SHA256.hexdigest(file.original_filename.to_s + step_index.to_s)[0, 12]}.#{format}"
      target_path = directory.join(filename)
      File.binwrite(target_path, bytes)

      url = "#{Discourse.base_url}/uploads/blackboard_audio/#{source}/#{filename}"

      solution.with_lock do
        payload = solution.solution_json.deep_dup
        payload['audio'] ||= { 'status' => 'pending', 'tracks' => [] }
        tracks = payload['audio']['tracks'] || []
        tracks.reject! { |t| t['step_index'] == step_index }
        tracks << {
          'step_index' => step_index,
          'url' => url,
          'duration_ms' => duration_ms > 0 ? duration_ms : nil,
          'format' => format,
          'voice' => voice,
          'voice_name' => voice,
        }
        tracks.sort_by! { |t| t['step_index'] }
        payload['audio']['tracks'] = tracks

        total_steps = payload['steps']&.size || 0
        if total_steps > 0 && tracks.size >= total_steps
          payload['audio']['status'] = 'ready'
        else
          payload['audio']['status'] = 'ready_partial'
        end

        solution.update!(solution_json: payload)
      end

      render json: {
        success: true,
        step_index: step_index,
        url: url,
        status: solution.solution_json.dig('audio', 'status'),
        tracks_count: solution.solution_json.dig('audio', 'tracks')&.size || 0,
      }
    end

    MAX_AUDIO_BYTES = 4 * 1024 * 1024

    # WAV starts with RIFF....WAVE; MP3 with an ID3 tag or an MPEG frame sync.
    def self.audio_signature_ok?(bytes, format)
      if format == 'wav'
        bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WAVE'
      else
        bytes.start_with?('ID3') || (bytes.getbyte(0) == 0xFF && (bytes.getbyte(1).to_i & 0xE0) == 0xE0)
      end
    end

    private

    def v5?
      requested_schema_version == 5
    end

    def ensure_blackboard_access
      return if current_user&.staff? || current_user&.admin? || current_user&.username == 'dersnotu'
      groups = SiteSetting.blackboard_premium_groups.to_s.split('|').reject(&:blank?)
      return if groups.empty?
      return if current_user && current_user.groups.where(name: groups).exists?
      render json: { error: 'premium_required' }, status: :forbidden
    end

    def valid_fingerprint?
      params[:source_fingerprint].to_s.match?(/\A[a-f0-9]{8,128}\z/)
    end

    def generation(topic)
      BlackboardGeneration.new(topic_id: topic.id, language: language,
        version: requested_schema_version, fingerprint: params[:source_fingerprint].to_s,
        user_id: current_user.id,
        base_limit: BlackboardLimits.for_request(current_user, request.headers['X-Sorumatik-Tier'])[:limit],
        api_quota: api_quota?)
    end

    # New apps whose Kara Tahta is charged by the Sorumatik API (X-Sorumatik-Quota: api).
    def api_quota?
      request.headers['X-Sorumatik-Quota'].to_s == 'api' && SorumatikApi.configured?
    end

    def ready_solution(topic)
      if v5?
        # Only an exact source match: a different fingerprint means the
        # question, language or prompt changed.
        fingerprint = params[:source_fingerprint].to_s
        return nil if fingerprint.blank?
        return BlackboardSolution.find_by(topic_id: topic.id, language: language, schema_version: 5,
          status: 'ready', source_fingerprint: fingerprint)
      end
      if requested_schema_version == 3
        requested_fingerprint = params[:source_fingerprint].to_s
        if requested_fingerprint.present?
          matched = BlackboardSolution.find_by(
            topic_id: topic.id,
            language: language,
            schema_version: 3,
            status: 'ready',
            source_fingerprint: requested_fingerprint,
          )
          return matched if matched
        end
        return BlackboardSolution.where(
          topic_id: topic.id,
          language: language,
          schema_version: 3,
          status: 'ready',
        ).order(created_at: :desc).first
      end
      solution = BlackboardSolution.find_by(
        topic_id: topic.id,
        language: language,
        schema_version: 2,
        status: 'ready',
      )
      solution ||= BlackboardSolution.find_by(
        topic_id: topic.id,
        language: language,
        schema_version: 1,
        status: 'ready',
      )
      return nil unless solution

      latest_post_id = topic.posts.order(post_number: :desc).limit(1).pick(:id)
      return nil if solution.schema_version == 1 && solution.source_post_id.present? &&
        latest_post_id.present? && solution.source_post_id != latest_post_id
      requested_fingerprint = params[:source_fingerprint].to_s
      return nil if solution.source_fingerprint.present? && requested_fingerprint.present? &&
        solution.source_fingerprint != requested_fingerprint

      solution
    end

    # Prompt 7+ is the v5 engine (kSolutionPromptVersion in the app). Older
    # apps send 2 or 3 and never see v5 rows, which they would reject.
    def requested_schema_version
      prompt = params[:prompt_version].to_i
      return 5 if prompt >= 7
      prompt == 3 ? 3 : 2
    end

    def language
      value = params[:language].to_s.downcase
      %w[tr en es hi id].include?(value) ? value : 'tr'
    end

    def accessible_topic
      topic = Topic.find_by(id: params[:topic_id])
      return nil unless topic&.visible?
      return nil if topic.archetype.to_s == 'private_message' || topic.private_message?
      return nil unless Guardian.new(current_user).can_see?(topic)
      topic
    end
  end
end
