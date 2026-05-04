require "application_system_test_case"

class RoomConnectionUiTest < ApplicationSystemTestCase
  test "invite section is hidden when the peer connects" do
    room_id = SecureRandom.uuid
    REDIS.setex("room:#{room_id}", Nullroom::Config::ROOM_TTL_SECONDS, "active")
    REDIS.setex("room:#{room_id}:count", Nullroom::Config::ROOM_COUNT_TTL_SECONDS, "0")

    visit "/rooms/#{room_id}#invalid"

    assert_selector("[data-controller~='room']")
    assert_selector("[data-room-target='inviteSection']", visible: true)

    result = page.evaluate_script(<<~JS)
      (() => {
        const roomRoot = document.querySelector("[data-controller~='room']")
        const roomController = window.Stimulus.getControllerForElementAndIdentifier(roomRoot, "room")
        const handshakeRoot = document.querySelector("[data-controller='handshake']")
        const handshakeController = window.Stimulus.getControllerForElementAndIdentifier(handshakeRoot, "handshake")

        roomController.qrModalTarget.classList.remove("hidden")
        handshakeController.phraseDisplayTarget.classList.remove("hidden")

        roomController.updateStatus(true, "connected")

        return {
          inviteHidden: roomController.inviteSectionTarget.classList.contains("hidden"),
          qrHidden: roomController.qrModalTarget.classList.contains("hidden"),
          phraseHidden: handshakeController.phraseDisplayTarget.classList.contains("hidden"),
          shareDisabled: handshakeController.shareButtonTarget.disabled
        }
      })()
    JS

    assert_equal true, result.fetch("inviteHidden")
    assert_equal true, result.fetch("qrHidden")
    assert_equal true, result.fetch("phraseHidden")
    assert_equal true, result.fetch("shareDisabled")
  ensure
    REDIS.del("room:#{room_id}")
    REDIS.del("room:#{room_id}:count")
  end
end
