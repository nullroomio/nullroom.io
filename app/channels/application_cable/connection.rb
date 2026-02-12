module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :token_id

    def connect
      # Use a volatile identifier and avoid session/cookie access.
      self.token_id = SecureRandom.uuid
    end
  end
end
