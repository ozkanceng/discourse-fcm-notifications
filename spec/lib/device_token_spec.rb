# frozen_string_literal: true

require "rails_helper"

describe DiscourseFcmNotifications::DeviceToken do
  fab!(:user_a) { Fabricate(:user) }
  fab!(:user_b) { Fabricate(:user) }

  before { SiteSetting.fcm_notifications_enabled = true }

  describe ".register!" do
    it "supports several devices for one user" do
      described_class.register!(user_a, "tok-phone", device_id: "phone", platform: "android")
      described_class.register!(user_a, "tok-tablet", device_id: "tablet", platform: "ios")

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to contain_exactly(
        "tok-phone",
        "tok-tablet",
      )
    end

    it "moves a token to the new user so the old account stops receiving pushes" do
      described_class.register!(user_a, "shared-device-token", device_id: "d1")
      described_class.register!(user_b, "shared-device-token", device_id: "d1")

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to be_empty
      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_b)).to eq(["shared-device-token"])
    end

    it "replaces the previous token of the same device when it rotates" do
      described_class.register!(user_a, "old", device_id: "d1")
      described_class.register!(user_a, "new", device_id: "d1")

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to eq(["new"])
    end
  end

  describe ".unregister!" do
    it "removes only the named device" do
      described_class.register!(user_a, "tok-phone", device_id: "phone")
      described_class.register!(user_a, "tok-tablet", device_id: "tablet")

      described_class.unregister!(user_a, device_id: "phone")

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to eq(["tok-tablet"])
    end

    it "only removes legacy (device-less) tokens when called without arguments" do
      described_class.register!(user_a, "legacy")
      described_class.register!(user_a, "modern", device_id: "d1")

      described_class.unregister!(user_a)

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to eq(["modern"])
    end
  end

  describe "legacy custom field migration" do
    it "moves the single stored token into the table" do
      user_a.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = "legacy-token"
      user_a.save_custom_fields(true)

      expect(DiscourseFcmNotifications::Pusher.has_tokens?(user_a)).to eq(true)
      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to eq(["legacy-token"])
      expect(user_a.reload.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME]).to be_blank
    end

    it "does not steal a token that a newer registration already moved" do
      described_class.register!(user_b, "legacy-token", device_id: "d1")
      user_a.custom_fields[DiscourseFcmNotifications::PLUGIN_NAME] = "legacy-token"
      user_a.save_custom_fields(true)

      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_a)).to be_empty
      expect(DiscourseFcmNotifications::Pusher.tokens_for(user_b)).to eq(["legacy-token"])
    end
  end

  describe DiscourseFcmNotifications::Pusher do
    describe ".classify_failure" do
      it "treats unregistered and 404 as invalid tokens" do
        body = { error: { details: [{ errorCode: "UNREGISTERED" }] } }.to_json
        expect(described_class.classify_failure(status_code: 404, body: body)).to eq(:invalid_token)
      end

      it "treats 429 and 5xx as transient" do
        expect(described_class.classify_failure(status_code: 429, body: "")).to eq(:transient)
        expect(described_class.classify_failure(status_code: 503, body: "")).to eq(:transient)
      end

      it "does not delete tokens for malformed message errors" do
        expect(described_class.classify_failure(status_code: 400, body: "bad field")).to eq(:other)
      end
    end

    describe ".build_message" do
      it "groups by topic and sets the iOS badge" do
        message =
          described_class.build_message(
            "tok",
            { title: "t", message: "m", url: "u", topic_id: 5, post_number: 3 },
            badge: 4,
          )

        expect(message[:android][:notification]["tag"]).to eq("topic_5")
        expect(message[:apns][:payload][:aps]["thread-id"]).to eq("topic_5")
        expect(message[:apns][:payload][:aps]["badge"]).to eq(4)
        expect(message[:data]["post_number"]).to eq("3")
      end

      it "omits grouping and badge when unknown" do
        message = described_class.build_message("tok", { title: "t", message: "m", url: "u" })

        expect(message[:android][:notification]).not_to have_key("tag")
        expect(message[:apns][:payload][:aps]).not_to have_key("badge")
      end
    end

    describe ".push" do
      let(:payload) do
        {
          notification_type: Notification.types[:private_message],
          username: "sender",
          topic_title: "Secret",
          excerpt: "private text",
          post_url: "/t/secret/1/2",
        }
      end

      it "hides private message text and drops it from the sent body" do
        DiscourseFcmNotifications::DeviceToken.register!(user_a, "tok", device_id: "d1")
        sent = []
        fcm = Object.new
        fcm.define_singleton_method(:send_v1) do |message|
          sent << message
          { response: "success" }
        end
        described_class.stubs(:fcm_client).returns(fcm)

        described_class.push(user_a, payload)

        expect(sent.length).to eq(1)
        expect(sent.first[:notification][:body]).not_to include("private text")
      end
    end
  end
end
