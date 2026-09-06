# frozen_string_literal: true

class CreateSorumatikBlackboardSolutions < ActiveRecord::Migration[7.0]
  def change
    create_table :sorumatik_blackboard_solutions do |t|
      t.integer :topic_id, null: false
      t.string :language, null: false, default: 'tr'
      t.integer :schema_version, null: false, default: 1
      t.jsonb :solution_json, null: false, default: {}
      t.integer :source_post_id
      t.string :status, null: false, default: 'ready'
      t.timestamps
    end

    add_index :sorumatik_blackboard_solutions,
              [:topic_id, :language, :schema_version],
              unique: true,
              name: 'idx_sorumatik_blackboard_solution_key'
    add_index :sorumatik_blackboard_solutions, :source_post_id
    add_foreign_key :sorumatik_blackboard_solutions, :topics,
                    column: :topic_id, on_delete: :cascade
    add_foreign_key :sorumatik_blackboard_solutions, :posts,
                    column: :source_post_id, on_delete: :nullify
  end
end
