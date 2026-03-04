// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import * as ActionCable from "@rails/actioncable"

const root = document.documentElement
const isProduction = root && root.dataset && root.dataset.env === "production"

if (isProduction && window.console && !window.__NULLROOM_CONSOLE_GATED__) {
	window.__NULLROOM_CONSOLE_GATED__ = true
	const noop = () => {}
	if (typeof window.console.log === "function") window.console.log = noop
	if (typeof window.console.debug === "function") window.console.debug = noop
	if (typeof window.console.info === "function") window.console.info = noop
}

// Create ActionCable consumer and make it globally available
window.cable = ActionCable.createConsumer()
