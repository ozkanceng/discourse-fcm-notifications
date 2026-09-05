# frozen_string_literal: true

class CreateSorumatikStudyFeatures < ActiveRecord::Migration[7.0]
  def change
    create_table :study_rooms do |t|
      t.integer :owner_id, null: false
      t.string :invite_code, null: false
      t.string :title, null: false
      t.string :status, null: false, default: 'active'
      t.string :pomodoro_phase, null: false, default: 'idle'
      t.datetime :phase_started_at
      t.integer :phase_duration_seconds, null: false, default: 1500
      t.string :timezone, null: false, default: 'UTC'
      t.timestamps
    end
    add_index :study_rooms, :invite_code, unique: true
    add_index :study_rooms, :owner_id

    create_table :study_room_members do |t|
      t.integer :room_id, null: false
      t.integer :user_id, null: false
      t.string :role, null: false, default: 'member'
      t.datetime :joined_at, null: false
      t.datetime :last_seen_at, null: false
    end
    add_index :study_room_members, [:room_id, :user_id], unique: true

    create_table :study_room_events do |t|
      t.integer :room_id, null: false
      t.string :event_id, null: false
      t.integer :actor_id, null: false
      t.string :type, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :study_room_events, [:room_id, :event_id], unique: true
    add_index :study_room_events, [:room_id, :id]

    create_table :sorumatik_study_events do |t|
      t.integer :user_id, null: false
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :sorumatik_study_events, [:user_id, :event_id], unique: true
  end
end
