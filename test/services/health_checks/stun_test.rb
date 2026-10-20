# frozen_string_literal: true

require "test_helper"

class HealthChecks::StunTest < ActiveSupport::TestCase
  Stun = HealthChecks::Stun

  test "encode and decode round-trip with padded attributes" do
    transaction_id = Stun.transaction_id
    data = Stun.encode(Stun::ALLOCATE_REQUEST, transaction_id, [ [ Stun::ATTR_USERNAME, "abcde" ], [ Stun::ATTR_REALM, "nullroom.io" ] ])

    assert_equal 0, data.bytesize % 4
    message = Stun.decode(data)

    assert_equal Stun::ALLOCATE_REQUEST, message.type
    assert_equal transaction_id, message.transaction_id
    assert_equal "abcde", message[Stun::ATTR_USERNAME]
    assert_equal "nullroom.io", message[Stun::ATTR_REALM]
  end

  test "message integrity covers the header with the integrity attribute's length" do
    key = Stun.long_term_key("user", "realm", "pass")
    data = Stun.encode(Stun::ALLOCATE_REQUEST, Stun.transaction_id, [ [ Stun::ATTR_USERNAME, "user" ] ], integrity_key: key)

    signed = data.byteslice(0, data.bytesize - 24)
    assert_equal Stun.body_length(data), data.bytesize - Stun::HEADER_SIZE
    assert_equal OpenSSL::HMAC.digest("SHA1", key, signed), data.byteslice(-20, 20)
  end

  test "error_code combines class and number" do
    data = Stun.encode(0x0113, Stun.transaction_id, [ [ Stun::ATTR_ERROR_CODE, [ 0, 0, 4, 86 ].pack("C4") + "Quota" ] ])

    assert_equal 486, Stun.decode(data).error_code
  end

  test "decode rejects data without the magic cookie" do
    assert_raises(ArgumentError) { Stun.decode("\x00".b * 20) }
    assert_raises(ArgumentError) { Stun.decode("short") }
  end
end
