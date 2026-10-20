# frozen_string_literal: true

require "openssl"
require "timeout"

module HealthChecks
  # Base class for status page checks. Subclasses implement #call and return a
  # Result; #run bounds it with a timeout and maps failures to reason codes.
  class Check
    DEFAULT_TIMEOUT = 5

    def timeout
      DEFAULT_TIMEOUT
    end

    def run
      Timeout.timeout(timeout) { call }
    rescue Timeout::Error, IO::TimeoutError
      Result.down("timeout")
    rescue SocketError, SystemCallError
      Result.down("connect_failed")
    rescue OpenSSL::SSL::SSLError
      Result.down("tls_failed")
    rescue StandardError
      Result.down("check_failed")
    end
  end
end
