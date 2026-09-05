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
        if DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user)
          #flash.now[:notice] = "You have successfully subscribed to push notifications."
          render json: { success: 'SUCCESS' }
        else
          #flash.now[:alert] = "There was an error subscribing to push notifications."
          render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
        end
      end
    end
    
    def subscribe
      return render json: { failed: 'FAILED', error: 'Invalid token' }, status: :unprocessable_entity if params[:subscription].to_s.blank? || params[:subscription].to_s.length > 4096
      if current_user.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] != params[:subscription]
        DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:subscription])
        if DiscourseFcmNotifications::Pusher.confirm_subscribe(current_user)
          render json: success_json
        else
          render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.subscribe_error") }
        end
      else
        render json: { failed: 'FAILED', error: I18n.t("discourse_fcm_notifications.the_same") }
      end
    end

    def unsubscribe
      DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
      render json: success_json
    end

  end
end
