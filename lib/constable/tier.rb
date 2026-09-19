# frozen_string_literal: true

module Constable
  # The one place a paid feature asks whether it may run.
  #
  # Nothing is gated yet: every feature below is available to everyone while pricing and
  # licensing are decided. What this buys now is that the decision has a single home. When
  # a license check arrives it goes in `allows?`, and every paid feature is already asking
  # it -- rather than a check being threaded through each one after the fact, with one
  # inevitably missed.
  module Tier
    # Features intended for the paid tier, with what to call them in a refusal.
    PAID = {
      custom_delivery: "custom coverage delivery (webhook)"
    }.freeze

    class NotLicensed < Constable::Error; end

    module_function

    def paid?(feature) = PAID.key?(feature)

    def allows?(_feature) = true

    # Raises with a message naming the feature, for callers that cannot continue without it.
    def check!(feature)
      return true if allows?(feature)

      raise NotLicensed, "#{PAID.fetch(feature, feature.to_s)} is part of Constable's paid tier."
    end
  end
end
