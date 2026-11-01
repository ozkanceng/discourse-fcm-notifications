module ::DiscourseFcmNotifications
  class PushController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    layout false
    before_action :ensure_logged_in
    skip_before_action :preload_json

    # Legacy endpoint used by app versions that register with a GET request.
    # Kept so installed apps keep working.
    def automatic_subscribe
      if params[:token] == "REMOVE"
        DiscourseFcmNotifications::Pusher.unsubscribe(current_user)
        render json: { success: 'SUCCESS' }
      else
        return render_invalid_token unless valid_token?(params[:token])
        DiscourseFcmNotifications::Pusher.subscribe(current_user, params[:token])
        render json: { success: 'SUCCESS' }
      end
    end

    def subscribe
      return render_invalid_token unless valid_token?(params[:subscription])
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

    # POST /fcm_notifications/devices
    # Registers (or moves to the current user) one device. The token travels in
    # the request body, not in the URL.
    def register_device
      return render_invalid_token unless valid_token?(params[:token])

      DiscourseFcmNotifications::Pusher.subscribe(
        current_user,
        params[:token],
        device_id: params[:device_id],
        platform: params[:platform],
      )
      render json: { success: 'SUCCESS' }
    end

    # DELETE /fcm_notifications/devices
    # Removes only the device identified by token and/or device_id.
    def unregister_device
      token = params[:token].to_s.strip
      device_id = params[:device_id].to_s.strip
      if token.blank? && device_id.blank?
        return render json: { failed: 'FAILED', error: 'token or device_id required' },
                      status: :unprocessable_entity
      end

      DiscourseFcmNotifications::Pusher.unsubscribe(
        current_user,
        token: token.presence,
        device_id: device_id.presence,
      )
      render json: { success: 'SUCCESS' }
    end

    private

    def valid_token?(value)
      value = value.to_s
      value.present? && value.length <= DiscourseFcmNotifications::DeviceToken::MAX_TOKEN_LENGTH
    end

    def render_invalid_token
      render json: { failed: 'FAILED', error: 'Invalid token' }, status: :unprocessable_entity
    end
  end
end
