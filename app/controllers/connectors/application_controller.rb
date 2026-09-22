module Connectors
  class ApplicationController < ActionController::API
    include GrantAccess
  end
end
