Rails.application.routes.draw do
  mount Connectors::Engine => "/connectors"
end
