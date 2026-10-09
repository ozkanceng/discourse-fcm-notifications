# frozen_string_literal: true
module Jobs
  class BlackboardAudio < ::Jobs::Base
    def execute(args)
      record = DiscourseFcmNotifications::BlackboardSolution.find_by(id: args[:solution_id])
      return unless record
      # Serializes retries; the HTTP request never waits for this row lock.
      record.with_lock do
        return if %w[ready unavailable].include?(record.solution_json.dig('audio', 'status'))
        payload = record.solution_json.deep_dup
        DiscourseFcmNotifications::BlackboardTtsService.enrich!(payload,
          language: record.language, fingerprint: record.source_fingerprint)
        if payload.dig('audio', 'status') == 'pending'
          payload['audio'] = { 'status' => 'unavailable', 'tracks' => [] }
        end
        record.update!(solution_json: payload)
      end
      raise 'Blackboard TTS retry required' if record.solution_json.dig('audio', 'status') == 'failed'
    end
  end
end
