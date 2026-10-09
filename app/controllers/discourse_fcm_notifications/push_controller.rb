module ::DiscourseFcmNotifications
  class PushController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    layout false
    before_action :ensure_logged_in
    skip_before_action :preload_json

    def automatic_subscribe
      if params[:token] == "REMOVE"
        DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
        render json: { success: 'SUCCESS' }
      else
        return render json: { failed: 'FAILED', error: 'Invalid token' }, status: :unprocessable_entity if params[:token].to_s.blank? || params[:token].to_s.length > 4096
        DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:token])
        render json: { success: 'SUCCESS' }
      end
    end
    
    def subscribe
      return render json: { failed: 'FAILED', error: 'Invalid token' }, status: :unprocessable_entity if params[:subscription].to_s.blank? || params[:subscription].to_s.length > 4096
      DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:subscription])
      confirm_ok = begin
        DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user)
      rescue StandardError => e
        Rails.logger.warn "FCM confirm_subscribe error: #{e.message}"
        false
      end
      render json: { success: 'SUCCESS', confirmed: confirm_ok }
    end

    def unsubscribe
      DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
      render json: success_json
    end

  end
end
