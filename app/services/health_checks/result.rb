# frozen_string_literal: true

module HealthChecks
  # Outcome of a single check: status is "ok", "degraded" or "down".
  # `reason` is one of a fixed set of codes so the public status page never
  # echoes raw error messages; `details` holds only values safe to publish
  # (days left on a cert, latency) — never IPs or credentials.
  Result = Data.define(:status, :reason, :details) do
    def self.ok(**details) = new(status: "ok", reason: nil, details: details)
    def self.degraded(reason, **details) = new(status: "degraded", reason: reason, details: details)
    def self.down(reason, **details) = new(status: "down", reason: reason, details: details)
  end
end
