# frozen_string_literal: true

require "openssl"
require "socket"

# Issues throwaway certificates and runs a local TLS server for tests that
# need a real handshake (certificate checks, TURN over TLS).
module TlsTestServer
  DAY = 86_400

  def generate_ca
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = build_cert(key.public_to_der, subject: "/CN=nullroom test CA", not_before: Time.now - DAY, not_after: Time.now + 365 * DAY)
    extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign, cRLSign", true))
    cert.sign(key, "SHA256")
    [ cert, key ]
  end

  # Issues a leaf for `hostname` signed by the CA (or self-signed without one).
  def issue_cert(hostname:, expires_in:, ca: nil)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    not_after = Time.now + expires_in
    cert = build_cert(key.public_to_der, subject: "/CN=#{hostname}", not_before: not_after - 90 * DAY, not_after: not_after)
    ca_cert, ca_key = ca || [ cert, key ]
    cert.issuer = ca_cert.subject
    extensions = OpenSSL::X509::ExtensionFactory.new(ca_cert, cert)
    cert.add_extension(extensions.create_extension("subjectAltName", "DNS:#{hostname}", false))
    cert.sign(ca_key, "SHA256")
    [ cert, key ]
  end

  def cert_store(*certs)
    OpenSSL::X509::Store.new.tap { |store| certs.each { |cert| store.add_cert(cert) } }
  end

  # Yields the port of a TLS server on 127.0.0.1. Each accepted connection is
  # passed to `handler` (default: close after the handshake).
  def with_tls_server(cert:, key:, handler: nil)
    tcp = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    server = OpenSSL::SSL::SSLServer.new(tcp, context)

    thread = Thread.new do
      loop do
        connection = server.accept
        handler&.call(connection)
      rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
        next
      ensure
        connection&.close
      end
    end

    yield tcp.addr[1]
  ensure
    thread&.kill
    tcp&.close
  end

  private

  def build_cert(public_key_der, subject:, not_before:, not_after:)
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(64)
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = cert.subject
      cert.public_key = OpenSSL::PKey.read(public_key_der)
      cert.not_before = not_before
      cert.not_after = not_after
    end
  end
end
