require "application_system_test_case"

class RoomPolyglotRenderingTest < ApplicationSystemTestCase
  POLYGLOT_PAYLOAD = "javascript:/*--></title></style></textarea></script></xmp><svg/onload=alert('xss')>"

  test "polyglot payload is rendered as inert text in message bubble" do
    room_id = SecureRandom.uuid
    REDIS.setex("room:#{room_id}", Nullroom::Config::ROOM_TTL_SECONDS, "active")
    REDIS.setex("room:#{room_id}:count", Nullroom::Config::ROOM_COUNT_TTL_SECONDS, "0")

    visit "/rooms/#{room_id}#invalid"

    assert_selector("[data-controller~='room']")
    assert_selector("[data-room-target='messagesContainer']")

    result = page.evaluate_script(<<~JS)
      (() => {
        const payload = #{POLYGLOT_PAYLOAD.to_json}
        const root = document.querySelector("[data-controller~='room']")
        const controller = window.Stimulus.getControllerForElementAndIdentifier(root, "room")
        controller.displayMessage(payload, false)

        const bubbles = Array.from(document.querySelectorAll("[data-room-target='messagesContainer'] > div"))
        const lastBubble = bubbles[bubbles.length - 1]
        const body = lastBubble.querySelector(".mt-1.break-words")

        return {
          bodyText: body ? body.textContent : null,
          hasSvgInBody: Boolean(body && body.querySelector("svg")),
          hasScriptInBubble: Boolean(lastBubble && lastBubble.querySelector("script")),
          bodyInnerHtml: body ? body.innerHTML : null
        }
      })()
    JS

    assert_equal POLYGLOT_PAYLOAD, result.fetch("bodyText")
    assert_equal false, result.fetch("hasSvgInBody")
    assert_equal false, result.fetch("hasScriptInBubble")
    assert_includes result.fetch("bodyInnerHtml"), "&lt;svg"
  ensure
    REDIS.del("room:#{room_id}")
    REDIS.del("room:#{room_id}:count")
  end

  test "polyglot filename metadata is rendered inert in download bubble" do
    room_id = SecureRandom.uuid
    REDIS.setex("room:#{room_id}", Nullroom::Config::ROOM_TTL_SECONDS, "active")
    REDIS.setex("room:#{room_id}:count", Nullroom::Config::ROOM_COUNT_TTL_SECONDS, "0")

    visit "/rooms/#{room_id}#invalid"

    assert_selector("[data-controller~='room']")
    assert_selector("[data-room-target='messagesContainer']")

    result = page.evaluate_script(<<~JS)
      (() => {
        const payload = #{POLYGLOT_PAYLOAD.to_json}
        const root = document.querySelector("[data-controller~='room']")
        const controller = window.Stimulus.getControllerForElementAndIdentifier(root, "room")
        const blobUrl = URL.createObjectURL(new Blob(["x"], { type: "text/plain" }))

        controller.appendFileDownload({
          name: payload,
          url: blobUrl,
          size: 12,
          isSent: false
        })

        const bubbles = Array.from(document.querySelectorAll("[data-room-target='messagesContainer'] > div"))
        const lastBubble = bubbles[bubbles.length - 1]
        const link = lastBubble.querySelector("a")
        const spans = link ? Array.from(link.querySelectorAll("span")) : []
        const fileNameText = spans[0] ? spans[0].textContent : null
        const linkText = link ? link.textContent : null

        return {
          fileNameText,
          linkText,
          href: link ? link.getAttribute("href") : null,
          scriptCount: lastBubble ? lastBubble.querySelectorAll("script").length : 0,
          svgCountInLink: link ? link.querySelectorAll("svg").length : 0
        }
      })()
    JS

    refute_nil result.fetch("fileNameText")
    refute_nil result.fetch("linkText")
    assert_match(/\Ablob:/, result.fetch("href"))
    assert_equal 0, result.fetch("scriptCount")
    assert_equal 1, result.fetch("svgCountInLink")
  ensure
    REDIS.del("room:#{room_id}")
    REDIS.del("room:#{room_id}:count")
  end
end
