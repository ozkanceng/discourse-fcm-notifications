# frozen_string_literal: true
require 'rails_helper'

RSpec.describe DiscourseFcmNotifications::BlackboardGeneration do
  fab!(:user) { Fabricate(:user) }
  let(:identity) { { topic_id: 918_273, language: 'tr', version: 3, fingerprint: SecureRandom.hex(32), user_id: user.id } }
  let(:lease) { described_class.new(**identity) }
  before { SiteSetting.blackboard_daily_limit = 1 }
  after do
    Discourse.redis.del(lease.lock_key, lease.quota_key)
  end

  it 'reserves the final slot atomically and refunds cancellation' do
    status, token = lease.reserve
    expect(status).to eq('owner')
    other = described_class.new(**identity.merge(fingerprint: SecureRandom.hex(32)))
    expect(other.reserve.first).to eq('quota_exceeded')
    expect(lease.finish(token, commit: false)).to eq(true)
    expect(lease.quota[:remaining]).to eq(1)
  end

  it 'does not let another user finish a lease, even with its token' do
    _, token = lease.reserve
    other = described_class.new(**identity.merge(user_id: user.id + 1))
    expect(other.finish(token, commit: false)).to eq(false)
    expect(lease.owner?(token)).to eq(true)
  end

  it 'does not let an expired owner delete a replacement lease' do
    _, token = lease.reserve
    Discourse.redis.del(lease.lock_key)
    Discourse.redis.zrem(lease.quota_key, token)
    _, replacement = lease.reserve
    expect(lease.finish(token, commit: true)).to eq(false)
    expect(lease.owner?(replacement)).to eq(true)
  end

  it 'charges once on completion and rejects repeated completion' do
    _, token = lease.reserve
    expect(lease.finish(token, commit: true)).to eq(true)
    expect(lease.finish(token, commit: true)).to eq(false)
    expect(lease.quota[:remaining]).to eq(0)
  end

  it 'removes expired reservations before checking the limit' do
    Discourse.redis.zadd(lease.quota_key, Time.now.to_i - 1, 'expired')
    expect(lease.reserve.first).to eq('owner')
  end
end
