module DiscourseFcmNotifications
  class StudyRoomMember < ActiveRecord::Base
    self.table_name = 'study_room_members'
    belongs_to :room, class_name: 'DiscourseFcmNotifications::StudyRoom', foreign_key: :room_id
  end
end
