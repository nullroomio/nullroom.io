# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"

module HealthChecks
  # Minimal STUN/TURN message codec (RFC 8489 / RFC 8656) — just enough for
  # health checks to send a Binding request and a TURN Allocate/Refresh.
  module Stun
    MAGIC_COOKIE = 0x2112A442
    HEADER_SIZE = 20

    BINDING_REQUEST = 0x0001
    BINDING_SUCCESS = 0x0101
    ALLOCATE_REQUEST = 0x0003
    ALLOCATE_SUCCESS = 0x0103
    REFRESH_REQUEST = 0x0004

    ATTR_USERNAME = 0x0006
    ATTR_MESSAGE_INTEGRITY = 0x0008
    ATTR_ERROR_CODE = 0x0009
    ATTR_LIFETIME = 0x000D
    ATTR_REALM = 0x0014
    ATTR_NONCE = 0x0015
    ATTR_XOR_RELAYED_ADDRESS = 0x0016
    ATTR_REQUESTED_TRANSPORT = 0x0019
    ATTR_XOR_MAPPED_ADDRESS = 0x0020

    Message = Data.define(:type, :transaction_id, :attributes) do
      def [](attribute) = attributes[attribute]

      # ERROR-CODE value: 2 reserved bytes, class (hundreds), number.
      def error_code
        value = attributes[ATTR_ERROR_CODE] or return nil
        (value.getbyte(2) & 0x07) * 100 + value.getbyte(3)
      end
    end

    module_function

    def transaction_id
      SecureRandom.random_bytes(12)
    end

    # Builds a STUN message from [type, value] attribute pairs. When
    # `integrity_key` is given, appends MESSAGE-INTEGRITY: an HMAC-SHA1 over the
    # message whose header length already counts the 24-byte integrity attribute.
    def encode(type, transaction_id, attributes = [], integrity_key: nil)
      body = attributes.map { |attribute, value| encode_attribute(attribute, value) }.join.b

      if integrity_key
        signed = header(type, body.bytesize + 24, transaction_id) + body
        body += encode_attribute(ATTR_MESSAGE_INTEGRITY, OpenSSL::HMAC.digest("SHA1", integrity_key, signed))
      end

      header(type, body.bytesize, transaction_id) + body
    end

    # Parses a full message (header + body). Only the first occurrence of each
    # attribute is kept, as RFC 8489 requires.
    def decode(data)
      data = data.to_s.b
      raise ArgumentError, "short STUN message" if data.bytesize < HEADER_SIZE

      type, length, cookie = data.unpack("nnN")
      raise ArgumentError, "not a STUN message" unless cookie == MAGIC_COOKIE && data.bytesize >= HEADER_SIZE + length

      attributes = {}
      offset = HEADER_SIZE
      while offset + 4 <= HEADER_SIZE + length
        attribute, attribute_length = data.byteslice(offset, 4).unpack("nn")
        attributes[attribute] ||= data.byteslice(offset + 4, attribute_length)
        offset += 4 + padded(attribute_length)
      end

      Message.new(type: type, transaction_id: data.byteslice(8, 12), attributes: attributes)
    end

    # Body length of a message from its 20-byte header (for stream transports).
    def body_length(header)
      header.unpack1("@2n")
    end

    # Long-term credential key: MD5(username ":" realm ":" password).
    def long_term_key(username, realm, password)
      Digest::MD5.digest("#{username}:#{realm}:#{password}")
    end

    def header(type, length, transaction_id)
      [ type, length, MAGIC_COOKIE ].pack("nnN") + transaction_id.b
    end

    def encode_attribute(attribute, value)
      value = value.to_s.b
      [ attribute, value.bytesize ].pack("nn") + value + ("\0".b * (padded(value.bytesize) - value.bytesize))
    end

    def padded(length)
      (length + 3) & ~3
    end
  end
end
