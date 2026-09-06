# frozen_string_literal: true

module DiscourseFcmNotifications
  class BlackboardSolutionsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :preload_json

    def show
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      solution = ready_solution(topic)
      return render json: { available: false } unless solution

      render json: {
        available: true,
        solution: solution.solution_json,
        updated_at: solution.updated_at,
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
        }
      end

      lock_key = "sorumatik:blackboard:#{topic.id}:#{language}:#{requested_schema_version}"
      acquired = Discourse.redis.set(lock_key, '1', nx: true, ex: 120)
      return render json: { available: false, status: 'pending', owner: false }, status: :accepted unless acquired

      # AI generation is performed through the authenticated app flow. Keep
      # the lock until #store persists the validated result (or Redis expires
      # it after the timeout), so other clients cannot start a duplicate run.
      render json: { available: false, status: 'pending', owner: true }, status: :accepted
    end

    def store
      topic = accessible_topic
      return render json: { error: 'not_found' }, status: :not_found unless topic

      payload = params[:solution]
      return render json: { error: 'invalid_solution' }, status: :unprocessable_entity unless payload.respond_to?(:to_h)
      payload = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h

      payload_version = payload['version'].to_i
      return render json: { error: 'invalid_solution' }, status: :unprocessable_entity unless [1, 2, 3].include?(payload_version)
      record = BlackboardSolution.find_or_initialize_by(
        topic_id: topic.id,
        language: language,
        schema_version: payload_version,
      )
      source_post_id = Integer(params[:source_post_id], exception: false)
      source_post = source_post_id && topic.posts.find_by(id: source_post_id)
      record.source_post_id = source_post&.id || topic.posts.order(:post_number).last&.id
      fingerprint = params[:source_fingerprint].to_s
      record.source_fingerprint = fingerprint.match?(/\A[a-f0-9]{8,128}\z/i) ? fingerprint : nil
      # Synthesis is best-effort and server-only. If Gemini is not configured
      # or temporarily unavailable the original text payload is still stored.
      DiscourseFcmNotifications::BlackboardTtsService.enrich!(
        payload,
        language: language,
        fingerprint: record.source_fingerprint,
      )
      record.solution_json = payload
      record.status = 'ready'
      record.save!
      Discourse.redis.del("sorumatik:blackboard:#{topic.id}:#{language}:#{payload_version}")
      render json: { available: true }, status: :created
    end

    private

    def ready_solution(topic)
      if requested_schema_version == 3
        requested_fingerprint = params[:source_fingerprint].to_s
        return nil if requested_fingerprint.blank?
        return BlackboardSolution.find_by(
          topic_id: topic.id,
          language: language,
          schema_version: 3,
          status: 'ready',
          source_fingerprint: requested_fingerprint,
        )
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

    def requested_schema_version
      params[:prompt_version].to_i == 3 ? 3 : 2
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
