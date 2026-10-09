# frozen_string_literal: true
require 'digest'

module DiscourseFcmNotifications
  class AiSolutionsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :preload_json

    def save_solution
      topic_id = params[:topic_id].to_i
      topic = Topic.find_by(id: topic_id)
      return render json: { error: 'not_found' }, status: :not_found unless topic
      return render json: { error: 'forbidden' }, status: :forbidden unless Guardian.new(current_user).can_see?(topic)

      raw_content = params[:content].to_s.strip
      return render json: { error: 'empty_content' }, status: :unprocessable_entity if raw_content.blank?

      source_post_id = params[:source_post_id].to_i
      source_post = source_post_id > 0 ? topic.posts.find_by(id: source_post_id) : topic.posts.order(:post_number).first

      # Find or fallback bot user
      bot_name = SiteSetting.respond_to?(:sorumatik_ai_bot_username) ? SiteSetting.sorumatik_ai_bot_username.presence : nil
      bot_name ||= SiteSetting.respond_to?(:gemini_ai_solve_bot_username) ? SiteSetting.gemini_ai_solve_bot_username.presence : nil
      bot_name ||= 'sorumatik_ai'
      bot_user = User.find_by_username_lower(bot_name.downcase) || Discourse.system_user

      # Prevent duplicate bot replies for the same source post
      existing_post = if source_post
        topic.posts.where(user_id: bot_user.id)
                   .where("post_number > ?", source_post.post_number)
                   .where(reply_to_post_number: source_post.post_number == 1 ? [nil, 1] : source_post.post_number)
                   .order(:post_number)
                   .first
      end

      post = existing_post
      duplicate = post.present?

      unless post
        post = PostCreator.create!(
          bot_user,
          topic_id: topic.id,
          reply_to_post_number: source_post&.post_number,
          raw: raw_content,
          skip_validations: true
        )
      end

      if post&.persisted?
        clean_raw = post.raw.to_s.gsub("\r\n", "\n").strip
        render json: {
          success: true,
          state: 'completed',
          topic_id: topic.id,
          source_post_id: source_post&.id || source_post_id,
          post_id: post.id,
          post_number: post.post_number,
          raw: clean_raw,
          content_sha256: Digest::SHA256.hexdigest(clean_raw),
          duplicate: duplicate
        }
      else
        render json: { error: 'save_failed' }, status: :unprocessable_entity
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :internal_server_error
    end
  end
end
