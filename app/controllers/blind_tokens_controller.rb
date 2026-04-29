require "json"
require "openssl"
require "digest"
require "rqrcode"

class BlindTokensController < ApplicationController
  class << self
    def rsa_private_key
      @rsa_private_key ||= begin
        pem = Rails.application.credentials.dig(:pro_token, :rsa_private_key)
        raise "Blind token RSA key missing" if pem.blank?

        OpenSSL::PKey::RSA.new(pem)
      end
    end
  end

  def public_key
    key = rsa_private_key
    render json: {
      modulus_hex: key.params.fetch("n").to_i.to_s(16),
      exponent_hex: key.params.fetch("e").to_i.to_s(16),
      amount_piconero: Nullroom::Config::DONATION_AMOUNT_PICONERO,
      required_confirmations: Nullroom::Config::DONATION_CONFIRMATIONS_REQUIRED,
      session_ttl_seconds: Nullroom::Config::DONATION_PAYMENT_SESSION_TTL_SECONDS,
      receipt_purpose: "donation",
      metadata: {}
    }
  rescue StandardError => e
    Rails.logger.error("BlindTokensController public_key error: #{e.class}: #{e.message}")
    render json: { error: "blind_key_unavailable" }, status: :service_unavailable
  end

  def create_payment_session
    payment = monero_service.create_subaddress

    payment_session_id = SecureRandom.hex(16)
    payload = {
      payment_session_id: payment_session_id,
      subaddress: payment.fetch(:subaddress),
      address_index: payment.fetch(:address_index),
      amount_piconero: Nullroom::Config::DONATION_AMOUNT_PICONERO,
      required_confirmations: Nullroom::Config::DONATION_CONFIRMATIONS_REQUIRED,
      status: "waiting",
      created_at: Time.now.to_i,
      receipt_purpose: "donation",
      metadata: {}
    }

    REDIS.setex(payment_session_key(payment_session_id), Nullroom::Config::DONATION_PAYMENT_SESSION_TTL_SECONDS, payload.to_json)
    session[:blind_payment_session_id] = payment_session_id

    render json: payload.slice(:payment_session_id, :subaddress, :amount_piconero, :required_confirmations, :status, :receipt_purpose, :metadata)
  rescue StandardError => e
    Rails.logger.error("BlindTokensController create_payment_session error: #{e.class}: #{e.message}")
    render json: { error: "blind_payment_session_failed" }, status: :service_unavailable
  end

  def status
    payload = refresh_payment_session!(load_payment_session!)
    persist_payment_session(payload)

    render json: payload.slice("payment_session_id", "subaddress", "amount_piconero", "required_confirmations", "status", "confirmations", "received_piconero", "pending_piconero", "receipt_purpose", "metadata")
  rescue KeyError
    render json: { error: "payment_session_not_found" }, status: :not_found
  rescue StandardError => e
    Rails.logger.error("BlindTokensController status error: #{e.class}: #{e.message}")
    render json: { error: "blind_status_unavailable" }, status: :service_unavailable
  end

  def sign
    payload = refresh_payment_session!(load_payment_session!)
    persist_payment_session(payload)
    blinded_message_hex = params[:blinded_message].to_s

    if blinded_message_hex.blank?
      render json: { error: "missing_blinded_message" }, status: :unprocessable_entity
      return
    end

    unless payload.fetch("status") == "ready"
      render json: { error: "payment_not_ready", status: payload.fetch("status") }, status: :unprocessable_entity
      return
    end

    subaddress = payload.fetch("subaddress")
    signed_key = signed_subaddress_key(subaddress)
    existing_signature = load_existing_signature(signed_key)
    if existing_signature
      if existing_signature.fetch("blinded_message") == blinded_message_hex
        render json: {
          signed_message: existing_signature.fetch("signed_message"),
          receipt_purpose: payload.fetch("receipt_purpose", "donation"),
          token_traits: {},
          metadata: payload.fetch("metadata", {})
        }
      else
        render json: { error: "payment_already_claimed" }, status: :conflict
      end
      return
    end

    signed = sign_blinded_message_hex(blinded_message_hex)

    claim_payload = {
      blinded_message: blinded_message_hex,
      signed_message: signed,
      signed_at: Time.now.to_i
    }

    claimed = REDIS.set(
      signed_key,
      claim_payload.to_json,
      nx: true,
      ex: Nullroom::Config::DONATION_SPENT_TOKEN_TTL_SECONDS
    )

    unless claimed == true || claimed == "OK"
      existing_signature = load_existing_signature(signed_key)
      if existing_signature && existing_signature.fetch("blinded_message") == blinded_message_hex
        signed = existing_signature.fetch("signed_message")
      else
        render json: { error: "payment_already_claimed" }, status: :conflict
        return
      end
    end

    render json: {
      signed_message: signed,
      receipt_purpose: payload.fetch("receipt_purpose", "donation"),
      token_traits: {},
      metadata: payload.fetch("metadata", {})
    }
  rescue KeyError
    render json: { error: "payment_session_not_found" }, status: :not_found
  rescue StandardError => e
    Rails.logger.error("BlindTokensController sign error: #{e.class}: #{e.message}")
    render json: { error: "blind_signing_failed" }, status: :unprocessable_entity
  end

  def verify
    message_hex = params[:message].to_s
    signature_hex = params[:signature].to_s

    if message_hex.blank? || signature_hex.blank?
      render json: { valid: false, error: "missing_token_parts" }, status: :unprocessable_entity
      return
    end

    verifier = BlindTokenVerifier.new
    valid = verifier.valid?(message_hex: message_hex, signature_hex: signature_hex)
    render json: {
      valid: valid,
      receipt_purpose: "donation",
      token_traits: {},
      metadata: {}
    }
  rescue StandardError => e
    Rails.logger.error("BlindTokensController verify error: #{e.class}: #{e.message}")
    render json: { valid: false, error: "verification_failed" }, status: :unprocessable_entity
  end

  def qr
    payload = params[:payload].to_s
    if payload.blank? || payload.bytesize > 1024
      render plain: "Invalid payload", status: :unprocessable_entity
      return
    end

    qrcode = RQRCode::QRCode.new(payload, level: :m)
    svg = qrcode.as_svg(
      offset: 8,
      color: "000000",
      background_color: "ffffff",
      shape_rendering: "crispEdges",
      module_size: 4,
      standalone: true,
      use_path: true
    )

    render plain: svg, content_type: "image/svg+xml"
  rescue StandardError => e
    Rails.logger.error("BlindTokensController qr error: #{e.class}: #{e.message}")
    render plain: "QR generation failed", status: :unprocessable_entity
  end

  private

  def monero_service
    @monero_service ||= MoneroPaymentService.new
  end

  def payment_session_id
    params[:payment_session_id].presence || session[:blind_payment_session_id].presence
  end

  def payment_session_key(id)
    "blind:payment_session:#{id}"
  end

  def load_payment_session!
    id = payment_session_id
    raise KeyError if id.blank?

    raw = REDIS.get(payment_session_key(id))
    raise KeyError if raw.blank?

    JSON.parse(raw)
  end

  def persist_payment_session(payload)
    REDIS.setex(
      payment_session_key(payload.fetch("payment_session_id")),
      Nullroom::Config::DONATION_PAYMENT_SESSION_TTL_SECONDS,
      payload.to_json
    )
  end

  def refresh_payment_session!(payload)
    monero_status = monero_service.check_status(
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
    payload["receipt_purpose"] ||= "donation"
    payload["metadata"] ||= {}
    payload
  end

  def rsa_private_key
    self.class.rsa_private_key
  end

  def sign_blinded_message_hex(blinded_message_hex)
    blinded = hex_to_integer(blinded_message_hex)
    key = rsa_private_key
    n = key.params.fetch("n").to_i
    d = key.params.fetch("d").to_i

    raise "Blinded message out of range" if blinded <= 0 || blinded >= n

    blinded.pow(d, n).to_s(16)
  end

  def hex_to_integer(value)
    hex = value.to_s.delete_prefix("0x")
    raise "Invalid hex" unless hex.match?(/\A\h+\z/)

    hex.to_i(16)
  end

  def signed_subaddress_key(subaddress)
    digest = Digest::SHA256.hexdigest(subaddress.to_s)
    "blind:subaddress:spent:#{digest}"
  end

  def load_existing_signature(signed_key)
    raw = REDIS.get(signed_key)
    return nil if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end
end
