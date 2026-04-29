require "json"

class MoneroPaymentConfirmationJob < ApplicationJob
  queue_as :default

  # Refreshes one payment session status from Monero RPC and persists the result.
  def perform(payment_session_id)
    key = "blind:payment_session:#{payment_session_id}"
    raw = REDIS.get(key)
    return if raw.blank?

    payload = JSON.parse(raw)
    service = MoneroPaymentService.new

    monero_status = service.check_status(
      address_index: payload.fetch("address_index"),
      min_amount_piconero: payload.fetch("amount_piconero").to_i
    )

    payload["status"] = if monero_status.fetch(:paid) && monero_status.fetch(:max_confirmations) >= payload.fetch("required_confirmations").to_i
      "ready"
    elsif monero_status.fetch(:paid)
      "confirming"
    elsif monero_status.fetch(:pending_amount_piconero).to_i >= payload.fetch("amount_piconero").to_i
      "detected"
    else
      "waiting"
    end

    payload["confirmations"] = monero_status.fetch(:max_confirmations)
    payload["received_piconero"] = monero_status.fetch(:total_received_piconero)
    payload["pending_piconero"] = monero_status.fetch(:pending_amount_piconero)

    REDIS.setex(key, Nullroom::Config::DONATION_PAYMENT_SESSION_TTL_SECONDS, payload.to_json)
  rescue StandardError => e
    Rails.logger.error("MoneroPaymentConfirmationJob error: #{e.class}: #{e.message}")
  end
end
