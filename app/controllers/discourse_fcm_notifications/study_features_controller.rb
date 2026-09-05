module DiscourseFcmNotifications
  class StudyFeaturesController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :preload_json

    def question_matches
      normalized = normalize_text(params[:normalized_text])
      hash = params[:image_hash].to_s.strip
      category_id = params[:category_id].to_i
      return render json: { matches: [] } if category_id <= 0

      matches = Topic.visible
        .where(category_id: category_id)
        .where('user_id != ?', current_user.id)
        .order(created_at: :desc)
        .limit(50)
      matches = matches.filter_map do |topic|
        raw = topic.try(:first_post).try(:raw).to_s
        normalized_raw = normalize_text(raw)
        hash_match = hash.present? && topic.custom_fields.to_h['sorumatik_image_hash'] == hash
        text_match = normalized.present? && normalized_raw.include?(normalized)
        next unless hash_match || text_match

        {
          topic_id: topic.id,
          title: topic.title,
          thumbnail_url: nil,
          confidence: hash_match ? 1.0 : 0.8,
          has_solution: topic.posts_count.to_i > 1
        }
      end.first(3)
      render json: { matches: matches }
    end

    def study_events
      incoming = params[:events].is_a?(Array) ? params[:events] : []
      accepted = 0
      incoming.first(200).each do |raw_event|
        event = if raw_event.respond_to?(:to_unsafe_h)
                  raw_event.to_unsafe_h
                else
                  raw_event
                end
        next unless event.respond_to?(:[])

        event_id = event['id'].to_s
        next if event_id.blank? || SorumatikStudyEvent.exists?(user_id: current_user.id, event_id: event_id)
        occurred_at = begin
          Time.zone.parse(event['occurred_at'].to_s)
        rescue ArgumentError, TypeError
          Time.zone.now
        end
        SorumatikStudyEvent.create!(user_id: current_user.id, event_id: event_id, event_type: event['type'].to_s, payload: event, occurred_at: occurred_at)
        accepted += 1
      end
      render json: { accepted: accepted }
    end

    def attach_image_hash
      topic = Topic.find(params[:topic_id])
      raise Discourse::NotFound unless topic.user_id == current_user.id
      image_hash = params[:image_hash].to_s.strip
      return render json: { error: 'invalid_hash' }, status: :unprocessable_entity if image_hash.blank? || image_hash.length > 128

      topic.custom_fields['sorumatik_image_hash'] = image_hash
      topic.save_custom_fields
      render json: { saved: true }
    end

    private

    def normalize_text(value)
      value.to_s.downcase.gsub(/[^\p{L}\p{N}]+/, ' ').squeeze(' ').strip
    end
  end
end
