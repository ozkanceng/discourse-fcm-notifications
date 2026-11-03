# frozen_string_literal: true

module DiscourseFcmNotifications
  # Daily Kara Tahta video limit for a request.
  #
  # Verified premium (a blackboard_premium_groups member, a purchase the
  # Sorumatik API verified) and staff get the premium limit. Store purchases are only known on the device, so new apps
  # send their tier in `X-Sorumatik-Tier` (free | premium): free gets
  # blackboard_free_daily_limit, premium blackboard_premium_daily_limit.
  # Requests without the header (app builds before the split) keep
  # blackboard_daily_limit, so their premium users are not cut to the free
  # limit. Rewarded extras are added on top by BlackboardGeneration.
  module BlackboardLimits
    TIERS = %w[free premium].freeze

    module_function

    def for_request(user, header)
      verified = verified_premium?(user)
      claimed = TIERS.include?(header.to_s.strip.downcase) ? header.to_s.strip.downcase : nil
      tier = verified ? 'premium' : claimed
      limit =
        case tier
        when 'premium' then SiteSetting.blackboard_premium_daily_limit
        when 'free' then SiteSetting.blackboard_free_daily_limit
        else SiteSetting.blackboard_daily_limit
        end
      { tier: user&.staff? ? 'staff' : (tier || 'legacy'), limit: limit.to_i, verified: verified }
    end

    def verified_premium?(user)
      return false unless user
      return true if user.staff?
      groups = SiteSetting.blackboard_premium_groups.to_s.split('|').reject(&:blank?)
      return true if groups.any? && user.groups.where(name: groups).exists?
      # A store purchase the Sorumatik API verified (cached 5 minutes).
      !!(defined?(SorumatikApi) && user.respond_to?(:id) && SorumatikApi.pro?(user.id))
    end
  end
end
