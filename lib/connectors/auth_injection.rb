module Connectors
  # Resolves credential templates in declarative authentication properties.
  # Only `$credentials.field` and bracket lookups are supported.
  #
  # Strings beginning with `=` interpolate their `{{ ... }}` segments.
  # Other strings remain literal; general expressions are unsupported.
  module AuthInjection
    module_function

    # Walk a properties Hash (`{ headers: {...}, qs: {...}, body: {...},
    # auth: { username:, password: } }`), resolving every leaf string against
    # `credentials`. Non-string leaves pass through.
    def resolve(properties, credentials)
      walk(properties, credentials || {})
    end

    def walk(value, credentials)
      case value
      when Hash
        # Resolve both keys and values so header and query names can come
        # from credential fields.
        value.each_with_object({}) do |(k, v), out|
          resolved_key = k.is_a?(String) ? resolve_string(k, credentials) : k
          out[resolved_key] = walk(v, credentials)
        end
      when Array  then value.map { |v| walk(v, credentials) }
      when String then resolve_string(value, credentials)
      else value
      end
    end

    EXPR = /\{\{\s*(.+?)\s*\}\}/.freeze

    def resolve_string(str, credentials)
      return str unless str.start_with?("=")
      str[1..].gsub(EXPR) { lookup(Regexp.last_match(1), credentials) }
    end

    # Supports dot and quoted bracket lookups. Missing fields resolve to "".
    def lookup(expr, credentials)
      expr = expr.to_s.strip
      if (m = expr.match(/\A\$credentials\.([A-Za-z_][A-Za-z0-9_]*)\z/))
        credentials[m[1]].to_s
      elsif (m = expr.match(/\A\$credentials\[(["'])(.+?)\1\]\z/))
        credentials[m[2]].to_s
      else
        # Unknown expression syntax — pass through verbatim wrapped, so a
        # user typo is visible in the outgoing request rather than silently
        # erasing the header.
        "{{#{expr}}}"
      end
    end
  end
end
