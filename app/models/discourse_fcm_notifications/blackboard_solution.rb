# frozen_string_literal: true

module DiscourseFcmNotifications
  class BlackboardSolution < ActiveRecord::Base
    self.table_name = 'sorumatik_blackboard_solutions'
    belongs_to :source_post, class_name: '::Post', optional: true

    validates :language, presence: true, inclusion: { in: %w[tr en es hi id] }
    validates :schema_version, inclusion: { in: [1, 2, 3] }
    validates :status, inclusion: { in: %w[pending ready failed] }
    validate :solution_schema

    private

    def solution_schema
      return if solution_json.blank? && status != 'ready'

      unless solution_json.is_a?(Hash) && [1, 2, 3].include?(solution_json['version'].to_i) &&
             solution_json['version'].to_i == schema_version.to_i &&
             solution_json['steps'].is_a?(Array) && solution_json['steps'].any?
        errors.add(:solution_json, 'must contain a valid blackboard solution')
      end
    end
  end
end
