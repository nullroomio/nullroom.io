Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Health status on /up that includes a Redis write check.
  get "up" => "health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "rooms#index"

  # Room routes for nullroom P2P messaging
  resources :rooms, only: [ :index, :create, :show ]

  # Zero-knowledge handshake (ephemeral code-based room sharing)
  post "handshakes/:id", to: "handshakes#create"
  get  "handshakes/:id", to: "handshakes#show"

  # Anonymous blind token donation receipt flows (Monero + blind signatures)
  post "blind_tokens/session" => "blind_tokens#create_payment_session"
  get "blind_tokens/status" => "blind_tokens#status"
  post "blind_tokens/sign" => "blind_tokens#sign"
  post "blind_tokens/verify" => "blind_tokens#verify"
  get "blind_tokens/public_key" => "blind_tokens#public_key"
  get "blind_tokens/qr" => "blind_tokens#qr"

  # Static pages
  get "privacy" => "pages#privacy", as: :privacy_page
  get "faq" => "pages#faq", as: :faq_page
  get "about" => "pages#about", as: :about_page
  get "use-cases" => "pages#use_cases", as: :use_cases_page

  # ActionCable mount point for WebSocket connections
  mount ActionCable.server => "/cable"
end
