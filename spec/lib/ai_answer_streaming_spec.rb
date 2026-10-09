# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseFcmNotifications::AiAnswerStreaming do
  fab!(:author) { Fabricate(:user) }
  fab!(:bot) { Fabricate(:user, username: "sorumatik_ai") }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:tag) { Fabricate(:tag, name: "soru-cozumu") }
  fab!(:source_post) { Fabricate(:post, topic: topic, user: author, post_number: 1) }
  fab!(:final_post) do
    Fabricate(
      :post,
      topic: topic,
      user: bot,
      post_number: 2,
      raw: "Tam cevap",
      cooked: "<p>Tam cevap</p>",
    )
  end

  let(:runner_class) do
    result = final_post
    Class
      .new do
        define_method(:reply_to) do |_post, &callback|
          callback.call("Tam ")
          callback.call("cevap")
          result
        end
      end
      .tap { |klass| klass.prepend(described_class) }
  end

  before do
    # Isolate the legacy snapshot adapter from the OCR plugin's generation
    # ownership when both plugins are loaded in the Discourse test suite.
    if defined?(::SorumatikOcr::AnswerGeneration)
      allow(::SorumatikOcr::AnswerGeneration).to receive(:managed_source?).and_return(false)
    end
    SiteSetting.tagging_enabled = true
    SiteSetting.sorumatik_ai_live_streaming_enabled = true
    SiteSetting.sorumatik_ai_live_stream_tag = "soru-cozumu"
    SiteSetting.sorumatik_ai_bot_username = "sorumatik_ai"
    SiteSetting.sorumatik_ai_stream_throttle_ms = 80
    topic.tags << tag
  end

  it "never generates or streams a versioned mobile-owned source" do
    source_post.custom_fields["client_edge_solve"] = "true"
    source_post.custom_fields["mobile_answer_protocol"] = "2"
    source_post.save_custom_fields
    expect(MessageBus).not_to receive(:publish)
    native = Class.new do
      def reply_to(_post)
        raise "native generation must not run"
      end
    end
    native.prepend(described_class)
    expect(native.new.reply_to(source_post)).to be_nil
  end

  it "publishes user-scoped snapshots and one canonical final result" do
    messages = []
    allow(MessageBus).to receive(:publish) { |channel, payload, options| messages << [channel, payload, options] }

    expect(runner_class.new.reply_to(source_post)).to eq(final_post)

    expect(messages.last[0]).to eq("/sorumatik/ai-answer/#{source_post.id}")
    expect(messages.last[1]).to include(
      source_post_id: source_post.id,
      raw: "Tam cevap",
      cooked: "<p>Tam cevap</p>",
      post_id: final_post.id,
      post_number: final_post.post_number,
      done: true,
    )
    expect(messages.last[2]).to include(user_ids: [author.id], max_backlog_size: 2)
    expect(messages.length).to eq(2) # one throttled progress snapshot + final
  end

  it "delegates to the existing AI generation exactly once" do
    generation_calls = 0
    result = final_post
    single_call_runner = Class.new do
      define_method(:reply_to) do |_post, &callback|
        generation_calls += 1
        callback.call("Tam cevap")
        result
      end
    end
    single_call_runner.prepend(described_class)
    allow(MessageBus).to receive(:publish)

    expect(single_call_runner.new.reply_to(source_post)).to eq(final_post)
    expect(generation_calls).to eq(1)
  end

  it "publishes a follow-up that explicitly targets the AI bot" do
    follow_up = Fabricate(
      :post,
      topic: topic,
      user: author,
      post_number: 3,
      raw: "@sorumatik_ai ikinci adımı açıklar mısın?",
    )
    expect(MessageBus).to receive(:publish).at_least(:once)
    runner_class.new.reply_to(follow_up)
  end

  it "does not publish for an untagged topic" do
    topic.tags.clear
    expect(MessageBus).not_to receive(:publish)
    expect(runner_class.new.reply_to(source_post)).to eq(final_post)
  end

  it "does not publish when the author cannot see the topic" do
    allow_any_instance_of(Guardian).to receive(:can_see?).and_return(false)
    expect(MessageBus).not_to receive(:publish)
    runner_class.new.reply_to(source_post)
  end

  it "publishes a structured terminal error and re-raises" do
    failing_class = Class.new do
      def reply_to(_post)
        raise "model unavailable"
      end
    end
    failing_class.prepend(described_class)
    messages = []
    allow(MessageBus).to receive(:publish) { |_channel, payload, _options| messages << payload }

    expect { failing_class.new.reply_to(source_post) }.to raise_error("model unavailable")
    expect(messages.last[:done]).to eq(true)
    expect(messages.last.dig(:error, :code)).to eq("generation_failed")
    expect(messages.last.dig(:error, :retryable)).to eq(true)
  end
end
