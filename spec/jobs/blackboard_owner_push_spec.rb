# frozen_string_literal: true
require 'rails_helper'

RSpec.describe Jobs::BlackboardOwnerPush do
  fab!(:owner) { Fabricate(:user) }
  fab!(:requester) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic, user: owner) }
  let(:sent) { [] }

  def solution(language: 'tr', generated_by: requester, for_topic: topic)
    DiscourseFcmNotifications::BlackboardSolution.create!(
      topic_id: for_topic.id,
      language: language,
      schema_version: 3,
      status: 'ready',
      generated_by_id: generated_by.id,
      solution_json: { version: 3, steps: [{ duration_ms: 2000, speech_text: 'Adım' }] },
    )
  end

  def run(record)
    described_class.new.execute(solution_id: record.id)
  end

  before do
    SiteSetting.fcm_notifications_enabled = true
    allow(DiscourseFcmNotifications::Pusher).to receive(:send_notification) { |_, message, **| sent << message; true }
  end

  it 'tells the asker, with the link that opens the video' do
    run(solution)
    expect(sent.size).to eq(1)
    expect(sent.first[:type]).to eq('blackboard_owner_ready')
    expect(sent.first[:deep_link]).to eq("sorumatik://t/#{topic.id}?action=blackboard")
  end

  it 'stays quiet when the asker made the video' do
    run(solution(generated_by: owner))
    expect(sent).to be_empty
  end

  it 'pushes only for the first solution of a topic' do
    solution
    run(solution(language: 'en'))
    expect(sent).to be_empty
  end

  it 'skips an old question' do
    topic.update!(created_at: 31.days.ago)
    run(solution)
    expect(sent).to be_empty
  end

  it 'respects a user who turned pushes off' do
    allow(DiscourseFcmNotifications::Pusher).to receive(:push_disabled_by_user?).with(owner).and_return(true)
    run(solution)
    expect(sent).to be_empty
  end

  it 'skips a private message' do
    message = Fabricate(:private_message_topic, user: owner)
    run(solution(for_topic: message))
    expect(sent).to be_empty
  end

  it 'lets Sidekiq retry a transient delivery failure' do
    allow(DiscourseFcmNotifications::Pusher).to receive(:send_notification)
      .and_raise(DiscourseFcmNotifications::Pusher::TransientDeliveryError)
    record = solution
    expect { run(record) }.to raise_error(DiscourseFcmNotifications::Pusher::TransientDeliveryError)
  end
end

RSpec.describe DiscourseFcmNotifications::Pusher do
  fab!(:user) { Fabricate(:user) }

  it 'falls back to English for a language without text' do
    allow(described_class).to receive(:language_for).and_return('pt_BR')
    message = nil
    allow(described_class).to receive(:send_notification) { |_, hash, **| message = hash }
    described_class.push_blackboard_owner(user, topic_id: 5)
    expect(message[:title]).to eq('Your question has a video solution 🎬')
  end

  it 'reads the language of the asker' do
    allow(described_class).to receive(:language_for).and_return('tr')
    message = nil
    allow(described_class).to receive(:send_notification) { |_, hash, **| message = hash }
    described_class.push_blackboard_owner(user, topic_id: 5)
    expect(message[:title]).to eq('Sorunun video çözümü hazır 🎬')
  end
end
