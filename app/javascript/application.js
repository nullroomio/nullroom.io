// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import * as ActionCable from "@rails/actioncable"

// Create ActionCable consumer and make it globally available
window.cable = ActionCable.createConsumer()
