# frozen_string_literal: true
class ScopeBlackboardSolutionToSource < ActiveRecord::Migration[7.0]
  def change
    add_column :sorumatik_blackboard_solutions, :generation_digest, :string
    add_column :sorumatik_blackboard_solutions, :generated_by_id, :integer
    remove_index :sorumatik_blackboard_solutions, name: 'idx_sorumatik_blackboard_solution_key'
    add_index :sorumatik_blackboard_solutions, [:topic_id, :language, :schema_version, :source_fingerprint],
      unique: true, name: 'idx_blackboard_source_key'
  end
end
