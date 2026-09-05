module DiscourseFcmNotifications
  class StudyRoomEvent < ActiveRecord::Base
    self.table_name = 'study_room_events'
    belongs_to :room, class_name: 'DiscourseFcmNotifications::StudyRoom', foreign_key: :room_id
  end
end
