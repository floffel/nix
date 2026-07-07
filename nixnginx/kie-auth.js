// Token-gate validator for kie.minnecker.com (OpenAI-compatible LLM proxy).
//
// Clients must send `Authorization: Bearer <token>`. The token is compared
// against the value in /var/lib/kie-proxy/token (auto-provisioned by the
// kie-proxy-token systemd oneshot). On success the auth_request subrequest
// returns 200 and nginx proceeds to proxy_pass; the client's Authorization
// header is overwritten with the upstream's fixed key ("Bearer x") in the
// vhost config, so the proxy token is NEVER forwarded to the LLM backend.
var fs = require('fs');

var TOKEN_FILE = '/var/lib/kie-proxy/token';

function readToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, 'utf8').trim();
  } catch (e) {
    return null;
  }
}

function auth(r) {
  var expected = readToken();
  if (!expected) {
    r.status = 503;
    r.headersOut['Content-Type'] = 'text/plain';
    r.sendHeader();
    r.send('proxy token not configured');
    r.finish();
    return;
  }

  var hdr = r.headersIn['Authorization'] || '';
  var provided = '';
  if (hdr.startsWith('Bearer ')) {
    provided = hdr.substring(7).trim();
  }

  if (provided && provided === expected) {
    r.status = 200;
    r.sendHeader();
    r.finish();
    return;
  }

  r.status = 401;
  r.headersOut['WWW-Authenticate'] = 'Bearer realm="kie.minnecker.com"';
  r.headersOut['Content-Type'] = 'text/plain';
  r.sendHeader();
  r.send('Unauthorized');
  r.finish();
}

export default { auth };
