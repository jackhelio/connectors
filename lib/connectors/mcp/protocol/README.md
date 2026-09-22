# MCP protocol schema

Unmodified generated JSON Schema for MCP 2026-07-28 from:
https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3f6e5e17e2a83b47dfb37b20d159e0e27efa316c/schema/2026-07-28/schema.json

The upstream license is included in LICENSE. This file is vendored to make response validation deterministic and avoid runtime network schema resolution. Update it only alongside protocol contract tests and a protocol-version change. Client compatibility normalization (absent resultType) lives in ProtocolSchema, not in this source artifact.

Application correction (2026-09-22): `ProtocolSchema` corrects only the in-memory `ElicitResult.content` numeric union from `integer` to `number`. The normative TypeScript definition at the same commit, [schema.ts line 3148](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3f6e5e17e2a83b47dfb37b20d159e0e27efa316c/schema/2026-07-28/schema.ts#L3148), permits `string | number | boolean | string[]`. The generated JSON incorrectly narrows that member. The vendored JSON remains unmodified; `interaction_spec.rb` covers accepting a decimal form response.
