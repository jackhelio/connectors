module Connectors
  # One cursor/configuration per consumer of a connection. instance_key is an
  # opaque identifier supplied by the host (for example its trigger ID).
  class PollState < ApplicationRecord
    belongs_to :grant, class_name: "Connectors::Grant"
    validates :instance_key, presence: true

    def update_cursor!
      with_lock do
        cursor = data.deep_dup
        result = yield(cursor)
        update!(data: cursor)
        result
      end
    end
  end
end
