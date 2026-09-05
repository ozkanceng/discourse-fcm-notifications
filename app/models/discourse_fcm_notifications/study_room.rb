module DiscourseFcmNotifications
  class StudyRoom < ActiveRecord::Base
    self.table_name = 'study_rooms'
    has_many :members, class_name: 'DiscourseFcmNotifications::StudyRoomMember', foreign_key: :room_id
    has_many :events, class_name: 'DiscourseFcmNotifications::StudyRoomEvent', foreign_key: :room_id
  end
end
