# frozen_string_literal: true

class CreateFcmDeviceTokens < ActiveRecord::Migration[7.0]
  def change
    create_table :fcm_device_tokens do |t|
      t.integer :user_id, null: false
      t.string :token, null: false, limit: 1024
      t.string :device_id, limit: 128
      t.string :platform, limit: 16
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    # A device token belongs to exactly one user at a time. Registering it for
    # a new user moves it, so a previous account can never receive pushes on a
    # device it no longer uses.
    add_index :fcm_device_tokens, :token, unique: true
    add_index :fcm_device_tokens, %i[user_id device_id]
    add_foreign_key :fcm_device_tokens, :users, column: :user_id, on_delete: :cascade
  end
end
