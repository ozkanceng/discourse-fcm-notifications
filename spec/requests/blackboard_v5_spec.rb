# frozen_string_literal: true
require 'rails_helper'

RSpec.describe 'Kara Tahta v5 server endpoints' do
  fab!(:user) { Fabricate(:user) }
  fab!(:other) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:group) { Fabricate(:group) }
  let(:path) { "/sorumatik/blackboard-solutions/#{topic.id}" }
  let(:identity) { { language: 'tr', prompt_version: 7, source_fingerprint: 'b' * 64 } }
  let(:v5) do
    {
      schema_version: 5, language: 'tr', layout_profile: 'algebra',
      steps: [{ id: 'st_1', intent: 'setup', segments: [{ id: 'seg_1_1', text: 'Denklemi yazalım.' }],
                operations: [{ id: 'op_1_1', type: 'latex', tex: 'x+1=2' }], pedagogy: { why: 'Başlangıç' } }],
      final_answer: { tex: 'x=1', speech: 'x bir' },
    }
  end

  before do
    SiteSetting.fcm_notifications_enabled = true
    SiteSetting.blackboard_premium_groups = ''
    SiteSetting.blackboard_daily_limit = 2
    SiteSetting.blackboard_free_daily_limit = 1
    SiteSetting.blackboard_premium_daily_limit = 10
    SiteSetting.blackboard_rewarded_daily_limit = 2
    SiteSetting.blackboard_free_help_daily_limit = 2
    sign_in(user)
  end

  describe 'v5 solution store' do
    it 'keeps v5 rows apart from older clients and skips the server audio job' do
      post "#{path}/generate", params: identity
      expect(response.status).to eq(202)
      token = response.parsed_body['generation_token']
      expect(Jobs).not_to receive(:enqueue).with(:blackboard_audio, anything)
      post path, params: identity.merge(generation_token: token, solution: v5)
      expect(response.status).to eq(201)
      expect(response.parsed_body.dig('solution', 'audio', 'status')).to eq('client')

      get path, params: identity
      expect(response.parsed_body['available']).to eq(true)
      # A v3 client asking for the same topic never receives the v5 row.
      get path, params: { language: 'tr', prompt_version: 3, source_fingerprint: 'b' * 64 }
      expect(response.parsed_body['available']).to eq(false)
    end

    it 'serves v5 only for the exact source fingerprint' do
      post "#{path}/generate", params: identity
      token = response.parsed_body['generation_token']
      post path, params: identity.merge(generation_token: token, solution: v5)
      get path, params: identity.merge(source_fingerprint: 'c' * 64)
      expect(response.parsed_body['available']).to eq(false)
    end

    it 'rejects a v3 payload sent as v5' do
      post "#{path}/generate", params: identity
      token = response.parsed_body['generation_token']
      post path, params: identity.merge(generation_token: token,
        solution: { version: 3, steps: [{ speech_text: 'x', operations: [] }] })
      expect(response.status).to eq(422)
    end
  end

  describe 'quota' do
    it 'reports used, remaining, rewarded and tier' do
      get '/sorumatik/blackboard-quota', headers: { 'X-Sorumatik-Tier' => 'free' }
      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body).to include('limit' => 1, 'used' => 0, 'remaining' => 1, 'rewarded_available' => 2, 'tier' => 'free')
      expect(body['resets_at']).to be_present
    end

    it 'gives free users one video a day and premium apps ten' do
      post "#{path}/generate", params: identity, headers: { 'X-Sorumatik-Tier' => 'free' }
      expect(response.status).to eq(202)
      post "/sorumatik/blackboard-solutions/#{Fabricate(:topic).id}/generate", params: identity,
        headers: { 'X-Sorumatik-Tier' => 'free' }
      expect(response.status).to eq(429)
      get '/sorumatik/blackboard-quota', headers: { 'X-Sorumatik-Tier' => 'premium' }
      expect(response.parsed_body).to include('limit' => 10, 'remaining' => 9, 'tier' => 'premium')
    end

    it 'keeps the old limit for apps that do not send their tier' do
      get '/sorumatik/blackboard-quota'
      expect(response.parsed_body).to include('limit' => 2, 'tier' => 'legacy')
    end

    it 'counts a verified rewarded ad once per transaction and caps it per day' do
      grant = ->(tx) { DiscourseFcmNotifications::BlackboardGeneration.grant_reward!(user_id: user.id, transaction_id: tx) }
      expect(grant.call('tx1')).to eq(:granted)
      expect(grant.call('tx1')).to eq(:duplicate)
      expect(grant.call('tx2')).to eq(:granted)
      expect(grant.call('tx3')).to eq(:limit_reached)
      get '/sorumatik/blackboard-quota', headers: { 'X-Sorumatik-Tier' => 'free' }
      expect(response.parsed_body).to include('limit' => 3, 'rewarded_available' => 0)
    end

    it 'requires a login' do
      sign_out
      get '/sorumatik/blackboard-quota'
      expect(response.status).to eq(403)
    end
  end

  describe 'rewarded SSV callback' do
    it 'is off until the admin enables it' do
      SiteSetting.blackboard_admob_ssv_enabled = false
      sign_out
      get '/sorumatik/blackboard-rewarded/ssv', params: { signature: 'x', key_id: '1' }
      expect(response.parsed_body['status']).to eq('disabled')
    end

    it 'rejects an unsigned callback' do
      SiteSetting.blackboard_admob_ssv_enabled = true
      sign_out
      get "/sorumatik/blackboard-rewarded/ssv?custom_data=blackboard&user_id=#{user.username}&transaction_id=abcdef1234"
      expect(response.status).to eq(403)
    end
  end

  describe 'help allowance' do
    it 'allows two free questions a day, then refuses' do
      2.times do
        post '/sorumatik/blackboard-help'
        expect(response.status).to eq(200)
      end
      post '/sorumatik/blackboard-help'
      expect(response.status).to eq(429)
      expect(response.parsed_body['allowed']).to eq(false)
    end

    it 'is unlimited for premium members' do
      SiteSetting.blackboard_premium_groups = group.name
      group.add(user)
      3.times { post '/sorumatik/blackboard-help' }
      expect(response.status).to eq(200)
      expect(response.parsed_body['unlimited']).to eq(true)
    end
  end

  describe 'share tokens' do
    it 'hands out an opaque token that resolves to the topic' do
      post '/sorumatik/blackboard-share', params: { topic_id: topic.id }
      expect(response.status).to eq(200)
      token = response.parsed_body['token']
      expect(response.parsed_body['url']).to include("s=#{token}")
      expect(response.parsed_body['url']).not_to include(user.username)

      post '/sorumatik/blackboard-share', params: { topic_id: topic.id }
      expect(response.parsed_body['token']).to eq(token)

      sign_in(other)
      get "/sorumatik/blackboard-share/#{token}"
      expect(response.parsed_body['topic_id']).to eq(topic.id)
      expect(response.parsed_body.to_s).not_to include(user.username)
    end

    it 'does not resolve unknown tokens' do
      get '/sorumatik/blackboard-share/AAAAAAAAAAAAAAAA'
      expect(response.status).to eq(404)
    end
  end

  describe 'legacy audio upload' do
    let(:v3_identity) { { language: 'tr', prompt_version: 3, source_fingerprint: 'a' * 64 } }
    let(:wav) do
      file = Tempfile.new(['step', '.wav'])
      file.binmode
      file.write('RIFF' + [100].pack('V') + 'WAVEfmt ' + "\0" * 92)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, 'audio/wav')
    end

    before do
      post "#{path}/generate", params: v3_identity
      token = response.parsed_body['generation_token']
      allow(Jobs).to receive(:enqueue)
      post path, params: v3_identity.merge(generation_token: token,
        solution: { version: 3, steps: [{ speech_text: 'Bir.', operations: [] }] })
    end

    it 'accepts narration only from the student who generated the solution' do
      sign_in(other)
      post "#{path}/audio", params: v3_identity.merge(step_index: 0, format: 'wav', file: wav)
      expect(response.status).to eq(403)
      sign_in(user)
      post "#{path}/audio", params: v3_identity.merge(step_index: 0, format: 'wav', file: wav)
      expect(response.status).to eq(200)
    end

    it 'refuses files that are not audio and steps that do not exist' do
      fake = Tempfile.new(['x', '.mp3'])
      fake.write('<html>' + ' ' * 100)
      fake.rewind
      post "#{path}/audio", params: v3_identity.merge(step_index: 0, format: 'mp3',
        file: Rack::Test::UploadedFile.new(fake.path, 'audio/mpeg'))
      expect(response.status).to eq(422)
      post "#{path}/audio", params: v3_identity.merge(step_index: 5, format: 'wav', file: wav)
      expect(response.status).to eq(422)
    end
  end
end
