module Connectors
  # Resolves n8n-style `={{$credentials.x}}` templates inside an
  # `IAuthenticateGeneric` properties block (n8n source:
  # packages/workflow/src/interfaces.ts:269-288, 197-208).
  #
  # Scope on purpose: this is NOT a general-purpose expression engine. It
  # only understands `$credentials.<field>` lookups (with optional bracket
  # access). Anything richer belongs in the automations expression engine,
  # which the connectors engine must remain independent of.
  #
  # A string that starts with `=` is a template — its `{{ ... }}` segments
  # are evaluated. Strings without a leading `=` are passed through as
  # literals (matches n8n's `={{expression}}` convention).
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
        # Both keys AND values can be templates. n8n's HttpHeaderAuth uses
        # `{ '={{$credentials.name}}': '={{$credentials.value}}' }` — the
        # header *name* is user-supplied (see
        # packages/nodes-base/credentials/HttpHeaderAuth.credentials.ts:38-45).
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

    # Supports `$credentials.field`, `$credentials["field"]`, `$credentials['field']`.
    # Missing keys resolve to "" (n8n behavior — keeps templates from raising
    # mid-request when the field is optional).
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
