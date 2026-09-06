# frozen_string_literal: true

class AddBlackboardTeacherSchema < ActiveRecord::Migration[7.0]
  def change
    add_column :sorumatik_blackboard_solutions, :source_fingerprint, :string
    add_index :sorumatik_blackboard_solutions, :source_fingerprint
  end
end
