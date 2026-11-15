# frozen_string_literal: true

module DiscourseFcmNotifications
  # The Sorumatik API reports a Kara Tahta job it finished for a student who
  # left the app. Only the API calls this, with the forum's service token.
  class BlackboardJobsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :preload_json
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_service_token

    STATUSES = %w[ready failed].freeze

    def finished
      job_id = params[:job_id].to_s
      user_id = Integer(params[:user_id], exception: false)
      topic_id = Integer(params[:topic_id], exception: false)
      status = params[:status].to_s
      unless job_id.match?(/\A[a-f0-9]{32}\z/) && user_id && topic_id && STATUSES.include?(status)
        return render json: { error: 'invalid_request' }, status: :unprocessable_entity
      end
      keep_raw_solution(user_id, topic_id) if status == 'ready'
      release_job_lease(user_id, topic_id)
      Jobs.enqueue(:blackboard_job_push, job_id: job_id, user_id: user_id, topic_id: topic_id,
                   language: params[:language].to_s, status: status)
      render json: { status: 'accepted' }, status: :accepted
    end

    private

    # The student's app kept the source lock when it handed the generation
    # over, so others waited for the job instead of asking the AI again.
    def release_job_lease(user_id, topic_id)
      fingerprint = params[:source_fingerprint].to_s
      return unless fingerprint.match?(/\A[a-f0-9]{8,128}\z/)
      BlackboardGeneration.release_job_lease(
        user_id: user_id, topic_id: topic_id, language: params[:language].to_s.downcase,
        version: job_schema_version, fingerprint: fingerprint,
      )
    rescue StandardError => e
      Rails.logger.warn("blackboard job lease not released topic=#{topic_id}: #{e.class}")
    end

    # Apps before the job reported its prompt version sent prompt 6.
    def job_schema_version
      BlackboardSolution.schema_for_prompt(params[:solution_prompt_version].presence || 6)
    end

    # Keeps the job's model text for the other students of the topic, so they
    # do not ask the AI again before its owner opens the app. That app later
    # replaces it with the parsed solution. Never fails the push.
    def keep_raw_solution(user_id, topic_id)
      raw = params[:raw]
      fingerprint = params[:source_fingerprint].to_s
      language = params[:language].to_s.downcase
      return unless raw.is_a?(String) && raw.strip.present? && raw.bytesize <= BlackboardSolution::MAX_RAW_BYTES
      return unless fingerprint.match?(/\A[a-f0-9]{8,128}\z/) && BlackboardSolution::LANGUAGES.include?(language)
      topic = Topic.find_by(id: topic_id)
      return if topic.nil? || topic.private_message?

      schema = job_schema_version
      source_post_id = Integer(params[:source_post_id], exception: false)
      BlackboardSolution.create!(
        topic_id: topic.id, language: language, schema_version: schema, source_fingerprint: fingerprint,
        status: BlackboardSolution::RAW, generated_by_id: user_id,
        source_post_id: source_post_id && topic.posts.where(id: source_post_id).pick(:id),
        solution_json: { 'raw' => raw, 'version' => schema },
      )
    rescue ActiveRecord::RecordNotUnique
      nil # This source already has a solution.
    rescue StandardError => e
      Rails.logger.warn("blackboard raw solution not kept topic=#{topic_id}: #{e.class}")
    end

    def ensure_service_token
      token = request.headers['X-Sorumatik-Service-Token'].to_s
      return if SorumatikApi.configured? &&
                SorumatikApi.secure_compare(SiteSetting.sorumatik_api_service_token.to_s.strip, token)
      render json: { error: 'forbidden' }, status: :forbidden
    end
  end
end
