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
      payload = params[:solution]
      return render json: { error: 'invalid_solution' }, status: :unprocessable_entity unless payload.respond_to?(:to_h)
      payload = payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h

      payload_version = payload['version'].to_i
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
      payload['audio'] = { 'status' => 'pending', 'tracks' => [] }
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
      Jobs.enqueue(:blackboard_audio, solution_id: record.id)
      Rails.logger.info("blackboard generation_stored topic=#{topic.id} user=#{current_user.id}")
      render json: { available: true, solution: record.solution_json, quota: lease.quota }, status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { error: 'generation_ownership_required' }, status: :conflict
    end

    private

    def ensure_blackboard_access
      groups = SiteSetting.blackboard_premium_groups.to_s.split('|').reject(&:blank?)
      # Membership must be managed by the verified purchase webhook/admin,
      # never by a client flag or editable user custom field.
      return if current_user && groups.any? && current_user.groups.where(name: groups).exists?
      render json: { error: 'premium_required' }, status: :forbidden
    end

    def valid_fingerprint?
      params[:source_fingerprint].to_s.match?(/\A[a-f0-9]{8,128}\z/)
    end

    def generation(topic)
      BlackboardGeneration.new(topic_id: topic.id, language: language,
        version: requested_schema_version, fingerprint: params[:source_fingerprint].to_s,
        user_id: current_user.id)
    end

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
