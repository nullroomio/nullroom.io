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

  # Static pages
  get "privacy" => "pages#privacy", as: :privacy_page

  # ActionCable mount point for WebSocket connections
  mount ActionCable.server => "/cable"
end
