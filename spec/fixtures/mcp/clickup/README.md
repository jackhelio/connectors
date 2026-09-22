# ClickUp public metadata fixtures

Captured on 2026-09-22 from the official public endpoints:

- `resource.json`: https://mcp.clickup.com/.well-known/oauth-protected-resource/mcp
- `authorization_server.json`: https://mcp.clickup.com/.well-known/oauth-authorization-server

The resource metadata URL was advertised by the unauthenticated `POST https://mcp.clickup.com/mcp` response's `WWW-Authenticate` header. These files contain no account credentials or user data.

The request specs exercise the client against these discovery documents. Registration responses, authorization codes, tokens and tools are synthetic test data, not captured ClickUp account traffic. Updating these fixtures requires checking the live official metadata and reviewing any behavior changes.
