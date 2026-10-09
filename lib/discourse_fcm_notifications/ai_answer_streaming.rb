# frozen_string_literal: true

require "securerandom"

module ::DiscourseFcmNotifications
  module AiAnswerStreaming
    CHANNEL_PREFIX = "/sorumatik/ai-answer"
    MAX_BACKLOG_AGE = 10.minutes
    MAX_BACKLOG_SIZE = 2

    def reply_to(source_post, *args, **kwargs, &original_callback)
      if source_post && source_post.custom_fields["client_edge_solve"].to_s == "true" &&
          source_post.custom_fields["mobile_answer_protocol"].to_i >= 2
        return nil
      end
      if defined?(::SorumatikOcr::AnswerGeneration) && ::SorumatikOcr::AnswerGeneration.managed_source?(source_post)
        return ::SorumatikOcr::AnswerGeneration.start!(source_post).post
      end
      return super unless sorumatik_stream_eligible?(source_post)

      generation_id = SecureRandom.uuid
      raw = +""
      last_publish_at = 0.0
      throttle_seconds = SiteSetting.sorumatik_ai_stream_throttle_ms.to_f / 1000.0

      callback =
        proc do |partial, *callback_args|
          original_callback&.call(partial, *callback_args)
          value = partial.to_s
          raw << value
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if now - last_publish_at >= throttle_seconds
            sorumatik_publish_snapshot(
              source_post,
              generation_id: generation_id,
              raw: raw,
              done: false,
            )
            last_publish_at = now
          end
        end

      result = super(source_post, *args, **kwargs, &callback)
      final_post = sorumatik_extract_post(result)
      sorumatik_publish_snapshot(
        source_post,
        generation_id: generation_id,
        raw: final_post&.raw.presence || raw,
        cooked: final_post&.cooked,
        post_id: final_post&.id,
        post_number: final_post&.post_number,
        done: true,
      )
      result
    rescue StandardError
      if defined?(generation_id) && generation_id && source_post
        sorumatik_publish_snapshot(
          source_post,
          generation_id: generation_id,
          raw: defined?(raw) ? raw : "",
          done: true,
          error: {
            code: "generation_failed",
            message: I18n.t(
              "discourse_fcm_notifications.ai_answer_failed",
              default: "AI answer could not be generated.",
            ),
            retryable: true,
          },
        )
      end
      raise
    end

    private

    def sorumatik_stream_eligible?(post)
      return false unless SiteSetting.sorumatik_ai_live_streaming_enabled?
      return false unless post&.persisted? && post.user_id && post.topic
      return false unless Guardian.new(post.user).can_see?(post.topic)

      tag_name = SiteSetting.sorumatik_ai_live_stream_tag.to_s.downcase
      tagged = post.topic.tags.any? { |tag| tag.name.downcase == tag_name }
      return false unless tagged
      return true if post.post_number == 1

      bot_username = SiteSetting.sorumatik_ai_bot_username.to_s.downcase
      mentioned = post.raw.to_s.downcase.match?(/@#{Regexp.escape(bot_username)}\b/)
      replied_to_bot =
        post.reply_to_post&.user&.username_lower.to_s == bot_username
      mentioned || replied_to_bot
    end

    def sorumatik_extract_post(result)
      return result if defined?(::Post) && result.is_a?(::Post)
      return result.post if result.respond_to?(:post) && result.post.is_a?(::Post)

      nil
    end

    def sorumatik_publish_snapshot(source_post, **payload)
      MessageBus.publish(
        "#{CHANNEL_PREFIX}/#{source_post.id}",
        payload.merge(source_post_id: source_post.id),
        user_ids: [source_post.user_id],
        max_backlog_age: MAX_BACKLOG_AGE,
        max_backlog_size: MAX_BACKLOG_SIZE,
      )
    rescue StandardError => error
      Rails.logger.warn(
        "sorumatik ai snapshot publish failed source_post_id=#{source_post.id} " \
          "error=#{error.class}: #{error.message}",
      )
    end
  end
end
