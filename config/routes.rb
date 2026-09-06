DiscourseFcmNotifications::Engine.routes.draw do
  get '/automatic_subscribe' => 'push#automatic_subscribe'
  post '/subscribe' => 'push#subscribe'
  post '/unsubscribe' => 'push#unsubscribe'
end

Discourse::Application.routes.draw do
  mount ::DiscourseFcmNotifications::Engine, at: '/fcm_notifications'
  scope path: '/sorumatik', module: 'discourse_fcm_notifications' do
    post '/study-rooms' => 'study_rooms#create'
    post '/study-rooms/join' => 'study_rooms#join'
    get '/study-rooms/:id' => 'study_rooms#show'
    post '/study-rooms/:id/leave' => 'study_rooms#leave'
    post '/study-rooms/:id/pomodoro/start' => 'study_rooms#pomodoro_start'
    post '/study-rooms/:id/pomodoro/pause' => 'study_rooms#pomodoro_pause'
    post '/study-rooms/:id/pomodoro/skip' => 'study_rooms#pomodoro_skip'
    get '/study-rooms/:id/events' => 'study_rooms#events'
    post '/question-matches' => 'study_features#question_matches'
    post '/topics/:topic_id/image-hash' => 'study_features#attach_image_hash'
    post '/study-events/batch' => 'study_features#study_events'
    get '/blackboard-solutions/:topic_id' => 'blackboard_solutions#show'
    post '/blackboard-solutions/:topic_id/generate' => 'blackboard_solutions#generate'
    post '/blackboard-solutions/:topic_id' => 'blackboard_solutions#store'
  end
end
