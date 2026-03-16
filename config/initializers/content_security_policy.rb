require "securerandom"

# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri    :none
    policy.form_action :self
    policy.frame_ancestors :none
    policy.object_src  :none

    # Keep scripts/styles strict: no unsafe-inline and no unsafe-eval.
    policy.script_src  :self
    policy.style_src   :self

    policy.img_src     :self, :data
    policy.font_src    :self, :data

    # Required for ActionCable and fetch/XHR. Includes ws/wss for dev and prod sockets.
    policy.connect_src :self, :https, :wss, :ws

    # Planned compatibility for future worker-based file processing.
    policy.worker_src  :self, :blob
  end

  # Generate per-request nonces for importmap and any inline script/style tags.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w(script-src style-src)
  config.content_security_policy_nonce_auto = true
end
