module DiscourseFcmNotifications
  class StudyRoomsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in
    skip_before_action :preload_json

    MAX_MEMBERS = 8

    def create
      room = StudyRoom.create!(owner_id: current_user.id, invite_code: SecureRandom.alphanumeric(8).upcase, title: params[:title].to_s.presence || 'Study room', phase_duration_seconds: params[:phase_duration_seconds].to_i.clamp(60, 7200), timezone: params[:timezone].to_s.presence || 'UTC')
      add_member(room, 'owner')
      render json: serialize(room)
    end

    def show
      room = StudyRoom.find(params[:id])
      authorize_member!(room)
      render json: serialize(room)
    end

    def join
      room = StudyRoom.find_by!(invite_code: params[:invite_code].to_s.upcase)
      raise Discourse::InvalidParameters.new(:room) if room.status != 'active'
      member = room.members.find_or_initialize_by(user_id: current_user.id)
      if !member.persisted? && room.members.count >= MAX_MEMBERS
        return render json: { error: 'room_full' }, status: :unprocessable_entity
      end
      member.role = 'member'; member.joined_at ||= Time.zone.now; member.last_seen_at = Time.zone.now; member.save!
      render json: serialize(room)
    end

    def leave
      room = StudyRoom.find(params[:id]); authorize_member!(room)
      room.members.where(user_id: current_user.id).delete_all
      room.update!(status: 'closed') if room.owner_id == current_user.id
      render json: serialize(room)
    end

    def pomodoro_start
      pomodoro_action('start')
    end

    def pomodoro_pause
      pomodoro_action('pause')
    end

    def pomodoro_skip
      pomodoro_action('skip')
    end

    def pomodoro_action(action)
      room = StudyRoom.find(params[:id]); authorize_member!(room)
      now = Time.zone.now
      case action
      when 'start' then room.update!(pomodoro_phase: 'focus', phase_started_at: now)
      when 'pause' then room.update!(pomodoro_phase: 'paused', phase_started_at: room.phase_started_at || now)
      when 'skip' then room.update!(pomodoro_phase: room.pomodoro_phase == 'focus' ? 'break' : 'focus', phase_started_at: now)
      end
      add_event(room, "pomodoro_#{action}", { phase: room.pomodoro_phase, phase_started_at: room.phase_started_at.iso8601 })
      render json: serialize(room)
    end

    def events
      room = StudyRoom.find(params[:id]); authorize_member!(room)
      scope = room.events.order(:id)
      scope = scope.where('id > ?', params[:after].to_i) if params[:after].present?
      render json: { events: scope.limit(100).map { |event| { id: event.id, event_id: event.event_id, type: event.type, payload: event.payload, created_at: event.created_at.iso8601 } } }
    end

    private

    def add_member(room, role)
      room.members.create!(user_id: current_user.id, role: role, joined_at: Time.zone.now, last_seen_at: Time.zone.now)
    end

    def add_event(room, type, payload)
      room.events.create!(event_id: SecureRandom.uuid, actor_id: current_user.id, type: type, payload: payload)
    end

    def authorize_member!(room)
      raise Discourse::NotFound unless room.members.exists?(user_id: current_user.id)
    end

    def serialize(room)
      { room: { id: room.id, invite_code: room.invite_code, title: room.title, status: room.status, pomodoro_phase: room.pomodoro_phase, phase_started_at: room.phase_started_at&.iso8601, phase_duration_seconds: room.phase_duration_seconds, member_count: room.members.count, members: room.members.map { |m| { user_id: m.user_id, username: User.find_by(id: m.user_id)&.username, role: m.role } } } }
    end
  end
end
