# frozen_string_literal: true

require "openssl"
require "socket"

module HealthChecks
  # Performs a real TLS handshake and inspects the certificate that is actually
  # served — not the one on disk. This is what would have caught the expired
  # turn.nullroom.io cert: the port accepted TCP, but the served cert was stale.
  #
  # Certbot renews 30 days before expiry, so anything under WARN_DAYS means
  # renewal (or the deploy hook that copies the cert) has failed.
  class TlsCertCheck < Check
    WARN_DAYS = 21
    CRITICAL_DAYS = 7

    # @param host [String] address to connect to (may be an IP)
    # @param server_name [String] SNI name the certificate must be valid for
    # @param cert_store [OpenSSL::X509::Store] trust anchors (system CAs by default)
    def initialize(host:, server_name:, port: 443, cert_store: nil)
      @host = host
      @port = port
      @server_name = server_name
      @cert_store = cert_store
    end

    def call
      cert, intermediates = fetch_certificate
      days_left = ((cert.not_after - Time.now) / 86_400).floor
      details = { days_left: days_left, expires_on: cert.not_after.utc.to_date.iso8601 }

      return Result.down("cert_expired", **details) if days_left.negative?
      return Result.down("cert_hostname_mismatch", **details) unless OpenSSL::SSL.verify_certificate_identity(cert, @server_name)
      return Result.down("cert_untrusted", **details) unless trusted?(cert, intermediates)
      return Result.down("cert_expiring", **details) if days_left < CRITICAL_DAYS
      return Result.degraded("cert_expiring", **details) if days_left < WARN_DAYS

      Result.ok(**details)
    end

    private

    # Handshakes without verification so an expired or untrusted cert can still
    # be inspected and reported with its expiry date; trust is checked after.
    def fetch_certificate
      Socket.tcp(@host, @port, connect_timeout: timeout) do |tcp|
        context = OpenSSL::SSL::SSLContext.new
        context.verify_mode = OpenSSL::SSL::VERIFY_NONE
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = @server_name
        ssl.connect

        [ ssl.peer_cert, Array(ssl.peer_cert_chain).drop(1) ]
      ensure
        ssl&.close
      end
    end

    def trusted?(cert, intermediates)
      store = @cert_store || OpenSSL::X509::Store.new.tap(&:set_default_paths)
      store.verify(cert, intermediates)
    end
  end
end
