class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # Verifies a blind token from request headers when a gated endpoint is accessed.
  # Successful verification unlocks access for this session for a limited TTL
  # to avoid forcing token replay on each request.
  def require_blind_token!
    unlocked_until = session[:blind_token_unlocked_until].to_i
    return if unlocked_until > Time.now.to_i

    message_hex = request.headers["X-Blind-Token-Message"].to_s
    signature_hex = request.headers["X-Blind-Token-Signature"].to_s

    if message_hex.blank? || signature_hex.blank?
      render json: { error: "missing_blind_token" }, status: :unauthorized
      return
    end

    verifier = BlindTokenVerifier.new
    unless verifier.consume!(message_hex: message_hex, signature_hex: signature_hex)
      render json: { error: "invalid_blind_token" }, status: :unauthorized
      return
    end

    session[:blind_token_unlocked_until] = Time.now.to_i + Nullroom::Config::DONATION_SESSION_UNLOCK_TTL_SECONDS
  rescue StandardError => e
    Rails.logger.error("Blind token verification error: #{e.class}: #{e.message}")
    render json: { error: "token_verification_failed" }, status: :service_unavailable
  end
end
