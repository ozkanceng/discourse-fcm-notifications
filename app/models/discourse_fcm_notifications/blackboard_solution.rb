# frozen_string_literal: true

module DiscourseFcmNotifications
  class BlackboardSolution < ActiveRecord::Base
    self.table_name = 'sorumatik_blackboard_solutions'
    belongs_to :source_post, class_name: '::Post', optional: true

    LANGUAGES = %w[tr en es hi id].freeze
    # A finished server job's model text, kept until an app turns it into a
    # solution. Only apps that can parse it are served one (raw_ok=1).
    RAW = 'raw'
    MAX_RAW_BYTES = 400_000

    validates :language, presence: true, inclusion: { in: LANGUAGES }
    validates :schema_version, inclusion: { in: [1, 2, 3, 5] }
    validates :status, inclusion: { in: ['pending', 'ready', 'failed', RAW] }
    validate :solution_schema
    validate :payload_limits

    # Prompt 7+ is the v5 engine (kSolutionPromptVersion in the app). Older
    # apps send 2 or 3 and never see v5 rows, which they would reject.
    def self.schema_for_prompt(prompt_version)
      prompt = prompt_version.to_i
      return 5 if prompt >= 7
      prompt >= 3 ? 3 : 2
    end

    def raw?
      status == RAW
    end

    private

    def payload_limits
      return unless solution_json.is_a?(Hash)
      return if raw?
      return v5_payload_limits if schema_version.to_i == 5
      steps = solution_json['steps']
      valid = solution_json.to_json.bytesize <= 512_000 && steps.is_a?(Array) && steps.size.between?(1, 40)
      valid &&= steps.all? do |step|
        step.is_a?(Hash) &&
          [step['speech_text'], step['speech'], step['cue_text']].compact.all? { |text| text.is_a?(String) && text.size <= 4096 } &&
          (step['operations'].nil? || (step['operations'].is_a?(Array) && step['operations'].size <= 20 && step['operations'].all? { |op| op.is_a?(Hash) }))
      end
      errors.add(:solution_json, 'exceeds blackboard payload limits') unless valid
    end

    # v5: 3-12 steps of 1-8 spoken segments (plain text) and up to 12 board
    # operations; the app validates the full schema before storing.
    def v5_payload_limits
      steps = solution_json['steps']
      valid = solution_json.to_json.bytesize <= 512_000 && steps.is_a?(Array) && steps.size.between?(1, 12)
      valid &&= steps.all? do |step|
        segments = step.is_a?(Hash) ? step['segments'] : nil
        ops = step.is_a?(Hash) ? (step['operations'] || []) : nil
        segments.is_a?(Array) && segments.size.between?(1, 8) &&
          segments.all? { |seg| seg.is_a?(Hash) && seg['text'].is_a?(String) && seg['text'].size.between?(1, 400) } &&
          ops.is_a?(Array) && ops.size <= 12 && ops.all? { |op| op.is_a?(Hash) }
      end
      errors.add(:solution_json, 'exceeds blackboard payload limits') unless valid
    end

    def solution_schema
      return raw_schema if raw?
      return if solution_json.blank? && status != 'ready'

      if schema_version.to_i == 5
        unless solution_json.is_a?(Hash) && solution_json['schema_version'].to_i == 5 &&
               solution_json['steps'].is_a?(Array) && solution_json['steps'].any?
          errors.add(:solution_json, 'must contain a valid blackboard solution')
        end
        return
      end

      unless solution_json.is_a?(Hash) && [1, 2, 3].include?(solution_json['version'].to_i) &&
             solution_json['version'].to_i == schema_version.to_i &&
             solution_json['steps'].is_a?(Array) && solution_json['steps'].any?
        errors.add(:solution_json, 'must contain a valid blackboard solution')
      end
    end

    def raw_schema
      raw = solution_json.is_a?(Hash) ? solution_json['raw'] : nil
      return if raw.is_a?(String) && raw.strip.present? && raw.bytesize <= MAX_RAW_BYTES
      errors.add(:solution_json, 'must contain the model text')
    end
  end
end
