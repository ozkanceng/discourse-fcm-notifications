# frozen_string_literal: true
require 'rails_helper'

RSpec.describe DiscourseFcmNotifications::BlackboardSolutionsController do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:group) { Fabricate(:group) }
  let(:path) { "/sorumatik/blackboard-solutions/#{topic.id}" }
  let(:identity) { { language: 'tr', prompt_version: 3, source_fingerprint: 'a' * 64 } }
  let(:payload) { { version: 3, language: 'tr', steps: [{ duration_ms: 2000, speech_text: 'Bir adım.', operations: [] }] } }
  before do
    SiteSetting.fcm_notifications_enabled = true
    SiteSetting.blackboard_premium_groups = group.name
    SiteSetting.blackboard_daily_limit = 5
    sign_in(user)
  end

  it 'denies generation to a signed-in user without paid membership' do
    post "#{path}/generate", params: identity
    expect(response.status).to eq(403)
  end

  it 'rejects writes without a generation owner token' do
    group.add(user)
    post path, params: identity.merge(solution: payload)
    expect(response.status).to eq(409)
    expect(DiscourseFcmNotifications::BlackboardSolution.where(topic_id: topic.id)).to be_empty
  end

  it 'stores validated text immediately, queues audio and replays without a charge' do
    group.add(user)
    post "#{path}/generate", params: identity
    expect(response.status).to eq(202)
    token = response.parsed_body['generation_token']
    expect(Jobs).to receive(:enqueue).with(:blackboard_audio, solution_id: kind_of(Integer))
    post path, params: identity.merge(generation_token: token, solution: payload)
    expect(response.status).to eq(201)
    expect(response.parsed_body.dig('solution', 'audio', 'status')).to eq('pending')
    post path, params: identity.merge(generation_token: token, solution: payload)
    expect(response.status).to eq(200)
    expect(DiscourseFcmNotifications::BlackboardSolution.where(topic_id: topic.id).count).to eq(1)
    post "#{path}/generate", params: identity
    expect(response.status).to eq(200)
    expect(response.parsed_body['available']).to eq(true)
    expect(response.parsed_body.dig('quota', 'remaining')).to eq(4)
  end

  it 'rejects oversized text before queuing billable audio' do
    group.add(user)
    post "#{path}/generate", params: identity
    token = response.parsed_body['generation_token']
    expect(Jobs).not_to receive(:enqueue).with(:blackboard_audio, anything)
    payload[:steps][0][:speech_text] = 'x' * 4097
    post path, params: identity.merge(generation_token: token, solution: payload)
    expect(response.status).to eq(422)
  end
end
