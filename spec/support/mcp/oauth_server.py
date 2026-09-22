"""Independent stdlib HTTP/OAuth fixture for MCP 2026-07-28 (fixture version 1).
Not a production OAuth server. Consent is automatically granted for test accounts.
"""
import base64
import hashlib
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

codes, tokens, refreshes = {}, {}, {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def reply(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path)
        if path.path == "/metadata":
            self.reply(200, {"resource": self.origin + "/mcp", "authorization_servers": [self.origin], "scopes_supported": ["read"]})
        elif path.path == "/.well-known/oauth-authorization-server":
            self.reply(200, {"issuer": self.origin, "authorization_endpoint": self.origin + "/authorize", "token_endpoint": self.origin + "/token", "registration_endpoint": self.origin + "/register", "code_challenge_methods_supported": ["S256"], "authorization_response_iss_parameter_supported": True, "token_endpoint_auth_methods_supported": ["none"]})
        elif path.path == "/authorize":
            query = {k: v[0] for k, v in parse_qs(path.query).items()}
            if query.get("code_challenge_method") != "S256" or query.get("resource") != self.origin + "/mcp":
                return self.reply(400, {"error": "invalid_request"})
            code = secrets.token_urlsafe(16)
            with lock:
                codes[code] = query
            location = query["redirect_uri"] + "?" + urlencode({"code": code, "state": query["state"], "iss": self.origin})
            self.reply(302, {}, {"Location": location})
        else:
            self.reply(404, {})

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/register":
            self.reply(201, {"client_id": "fixture-client", "token_endpoint_auth_method": "none"})
        elif self.path == "/token":
            form = {k: v[0] for k, v in parse_qs(data.decode()).items()}
            if form.get("resource") != self.origin + "/mcp":
                return self.reply(400, {"error": "invalid_target"})
            with lock:
                if form.get("grant_type") == "authorization_code":
                    authorization = codes.pop(form.get("code"), None)
                    challenge = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
                    if not authorization or authorization["code_challenge"] != challenge or authorization["redirect_uri"] != form.get("redirect_uri"):
                        return self.reply(400, {"error": "invalid_grant"})
                    scope = authorization.get("scope", "")
                else:
                    scope = refreshes.pop(form.get("refresh_token"), None)
                    if scope is None:
                        return self.reply(400, {"error": "invalid_grant"})
                access, refresh = secrets.token_urlsafe(16), secrets.token_urlsafe(16)
                tokens[access], refreshes[refresh] = scope, scope
            # Scope intentionally omitted: clients must retain their requested scope history.
            self.reply(200, {"access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_in": 3600})
        elif self.path == "/expire":
            with lock:
                tokens.clear()
            self.reply(200, {})
        elif self.path in ("/mcp", "/public", "/static"):
            request = json.loads(data)
            auth = self.headers.get("Authorization", "")
            with lock:
                scope = tokens.get(auth.removeprefix("Bearer "))
            if self.path == "/static" and auth != "Bearer fixture-static":
                return self.reply(401, {})
            if self.path == "/mcp" and scope is None:
                return self.reply(401, {}, {"WWW-Authenticate": f'Bearer resource_metadata="{self.origin}/metadata", scope="read"'})
            meta = request.get("params", {}).get("_meta", {})
            if meta.get("io.modelcontextprotocol/protocolVersion") != "2026-07-28" or self.headers.get("Mcp-Method") != request["method"]:
                return self.reply(400, {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32020, "message": "HeaderMismatch"}})
            if request["method"] == "tools/list":
                result = {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}], "ttlMs": 0, "cacheScope": "private"}
            elif request["method"] == "tools/call":
                if self.path == "/mcp" and "write" not in scope.split():
                    return self.reply(403, {}, {"WWW-Authenticate": f'Bearer error="insufficient_scope", resource_metadata="{self.origin}/metadata", scope="write"'})
                result = {"content": [{"type": "text", "text": "called"}]}
            else:
                return self.reply(404, {})
            self.reply(200, {"jsonrpc": "2.0", "id": request["id"], "result": {"resultType": "complete", **result}})
        else:
            self.reply(404, {})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
