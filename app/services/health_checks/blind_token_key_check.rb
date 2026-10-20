# frozen_string_literal: true

module HealthChecks
  # Donation receipts are blind-signed with this key; without it the
  # signing and verification endpoints fail.
  class BlindTokenKeyCheck < Check
    def call
      BlindTokenVerifier.rsa_public_params
      Result.ok
    rescue StandardError
      Result.down("key_unavailable")
    end
  end
end
