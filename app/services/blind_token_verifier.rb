require "digest"
require "openssl"

class BlindTokenVerifier
  class << self
    def rsa_public_params
      @rsa_public_params ||= begin
        private_pem = Rails.application.credentials.dig(:pro_token, :rsa_private_key)
        raise "Blind token RSA key not configured" if private_pem.blank?

        rsa = OpenSSL::PKey::RSA.new(private_pem)
        {
          n: rsa.params.fetch("n").to_i,
          e: rsa.params.fetch("e").to_i
        }
      end
    end
  end

  def initialize
    params = self.class.rsa_public_params
    @n = params.fetch(:n)
    @e = params.fetch(:e)
  end

  def valid?(message_hex:, signature_hex:)
    message = hex_to_integer(message_hex)
    signature = hex_to_integer(signature_hex)

    return false if message <= 0 || message >= @n
    return false if signature <= 0 || signature >= @n

    signature.pow(@e, @n) == message
  rescue StandardError
    false
  end

  # Consumes a token by atomically recording its message digest in Redis.
  # Returns false when token is invalid or already spent.
  def consume!(message_hex:, signature_hex:)
    return false unless valid?(message_hex: message_hex, signature_hex: signature_hex)

    hex_digest = Digest::SHA256.hexdigest(message_hex.downcase)
    spent_key = "blind:spent:#{hex_digest}"

    result = REDIS.set(
      spent_key,
      "1",
      nx: true,
      ex: Nullroom::Config::DONATION_SPENT_TOKEN_TTL_SECONDS
    )

    result == true || result == "OK"
  end

  private

  def hex_to_integer(value)
    hex = value.to_s.delete_prefix("0x")
    raise "Invalid hex" unless hex.match?(/\A\h+\z/)

    hex.to_i(16)
  end
end
