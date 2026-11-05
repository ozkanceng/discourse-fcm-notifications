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
      Jobs.enqueue(:blackboard_job_push, job_id: job_id, user_id: user_id, topic_id: topic_id,
                   language: params[:language].to_s, status: status)
      render json: { status: 'accepted' }, status: :accepted
    end

    private

    def ensure_service_token
      token = request.headers['X-Sorumatik-Service-Token'].to_s
      return if SorumatikApi.configured? &&
                SorumatikApi.secure_compare(SiteSetting.sorumatik_api_service_token.to_s.strip, token)
      render json: { error: 'forbidden' }, status: :forbidden
    end
  end
end
