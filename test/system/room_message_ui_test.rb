require "application_system_test_case"

class RoomMessageUiTest < ApplicationSystemTestCase
  test "message timestamps render in 24 hour format" do
    room_id = SecureRandom.uuid
    REDIS.setex("room:#{room_id}", Nullroom::Config::ROOM_TTL_SECONDS, "active")
    REDIS.setex("room:#{room_id}:count", Nullroom::Config::ROOM_COUNT_TTL_SECONDS, "0")

    visit "/rooms/#{room_id}#invalid"

    assert_selector("[data-controller~='room']")
    assert_selector("[data-room-target='messagesContainer']")

    result = page.evaluate_script(<<~JS)
      (() => {
        const root = document.querySelector("[data-controller~='room']")
        const controller = window.Stimulus.getControllerForElementAndIdentifier(root, "room")

        controller.displayMessage("hello", false)
        controller.appendFileDownload({
          name: "proof.txt",
          url: URL.createObjectURL(new Blob(["x"], { type: "text/plain" })),
          size: 12,
          isSent: false
        })

        const bubbles = Array.from(document.querySelectorAll("[data-room-target='messagesContainer'] > div"))
        const timestamps = bubbles.map((bubble) => {
          const firstChild = bubble.firstElementChild
          return firstChild ? firstChild.textContent : null
        })

        return { timestamps }
      })()
    JS

    timestamps = result.fetch("timestamps")
    assert_equal 2, timestamps.length
    timestamps.each do |timestamp|
      assert_match(/\A\d{2}:\d{2}\z/, timestamp)
    end
  ensure
    REDIS.del("room:#{room_id}")
    REDIS.del("room:#{room_id}:count")
  end
end
