import { Controller } from "@hotwired/stimulus"

// Reloads the enclosing status checks frame after an interval. Lives inside
// the frame's content, so each render sets its own pace (fast while checks
// are pending, once a minute after). The current content stays visible until
// the new one arrives, so there is no loading flash.
export default class extends Controller {
  static values = { interval: { type: Number, default: 60000 } }

  connect() {
    this.timer = setTimeout(() => this.element.closest("turbo-frame")?.reload(), this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
