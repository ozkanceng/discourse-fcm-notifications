# frozen_string_literal: true
require 'rails_helper'

RSpec.describe DiscourseFcmNotifications::BlackboardJobsController do
  fab!(:user) { Fabricate(:user) }
  let(:path) { '/sorumatik/blackboard-jobs/finished' }
  let(:token) { 'service-token' }
  let(:headers) { { 'X-Sorumatik-Service-Token' => token } }
  let(:body) { { job_id: 'a' * 32, user_id: user.id, topic_id: 77, language: 'tr', status: 'ready' } }

  before do
    SiteSetting.fcm_notifications_enabled = true
    allow(DiscourseFcmNotifications::SorumatikApi).to receive(:configured?).and_return(true)
    allow(SiteSetting).to receive(:sorumatik_api_service_token).and_return(token)
    Discourse.redis.del("sorumatik:blackboard:job_push:#{'a' * 32}")
  end

  it 'refuses a wrong service token' do
    post path, params: body, headers: { 'X-Sorumatik-Service-Token' => 'wrong-token-x' }
    expect(response.status).to eq(403)
  end

  it 'queues the push for a finished job' do
    expect_enqueued_with(job: :blackboard_job_push, args: { job_id: 'a' * 32, status: 'ready' }) do
      post path, params: body, headers: headers
    end
    expect(response.status).to eq(202)
  end

  describe 'model text of a ready job' do
    fab!(:topic) { Fabricate(:topic) }
    let(:raw) { '{"version":3,"steps":[{"speech_text":"Bir adım."}]}' }
    let(:ready) do
      body.merge(topic_id: topic.id, raw: raw, source_fingerprint: 'c' * 64, solution_prompt_version: 6,
                 source_post_id: topic.first_post&.id)
    end
    let(:solutions) { DiscourseFcmNotifications::BlackboardSolution.where(topic_id: topic.id) }

    it 'is kept for the other students of the topic' do
      post path, params: ready, headers: headers
      expect(response.status).to eq(202)
      expect(solutions.count).to eq(1)
      kept = solutions.first
      expect(kept.status).to eq('raw')
      expect(kept.schema_version).to eq(3)
      expect(kept.source_fingerprint).to eq('c' * 64)
      expect(kept.generated_by_id).to eq(user.id)
      expect(kept.solution_json['raw']).to eq(raw)
    end

    it 'is kept once when the API repeats the report' do
      2.times { post path, params: ready, headers: headers }
      expect(response.status).to eq(202)
      expect(solutions.count).to eq(1)
    end

    it "frees the lease its student kept, not another student's" do
      lock = DiscourseFcmNotifications::BlackboardGeneration.lock_key_for(
        topic_id: topic.id, language: 'tr', version: 3, fingerprint: 'c' * 64,
      )
      Discourse.redis.set(lock, "#{user.id}:1:api:x", ex: 600)
      post path, params: ready.merge(status: 'failed').except(:raw), headers: headers
      expect(Discourse.redis.get(lock)).to be_nil

      Discourse.redis.set(lock, "#{user.id + 1}:1:x", ex: 600)
      post path, params: ready, headers: headers
      expect(Discourse.redis.get(lock)).to eq("#{user.id + 1}:1:x")
    end

    it 'is not kept without a source fingerprint or for a failed job' do
      post path, params: ready.except(:source_fingerprint), headers: headers
      post path, params: ready.merge(status: 'failed'), headers: headers
      expect(solutions).to be_empty
    end
  end

  it 'rejects an unknown status' do
    post path, params: body.merge(status: 'running'), headers: headers
    expect(response.status).to eq(422)
  end

  it 'pushes once per job, with the link that opens the video' do
    sent = []
    allow(DiscourseFcmNotifications::Pusher).to receive(:send_notification) { |_, message, **| sent << message; true }
    2.times { Jobs::BlackboardJobPush.new.execute(body) }
    expect(sent.size).to eq(1)
    expect(sent.first[:deep_link]).to eq('sorumatik://t/77?action=blackboard')
    expect(sent.first[:title]).to eq('Video çözümün hazır')
  end

  it 'lets Sidekiq retry a transient delivery failure' do
    allow(DiscourseFcmNotifications::Pusher).to receive(:send_notification)
      .and_raise(DiscourseFcmNotifications::Pusher::TransientDeliveryError)
    expect { Jobs::BlackboardJobPush.new.execute(body) }
      .to raise_error(DiscourseFcmNotifications::Pusher::TransientDeliveryError)
    expect(Discourse.redis.get("sorumatik:blackboard:job_push:#{'a' * 32}")).to be_nil
  end

  it 'keeps the blackboard push apart from the replies of the topic' do
    message = DiscourseFcmNotifications::Pusher.build_message(
      'token', { title: 't', message: 'm', url: 'u', topic_id: 77, group: 'blackboard_77', deep_link: 'sorumatik://t/77' }
    )
    expect(message[:android][:notification]['tag']).to eq('blackboard_77')
    expect(message[:data]['deep_link']).to eq('sorumatik://t/77')
  end
end
