// Xcode's cloud signing mints a fresh "Apple Development" certificate on
// every run of a throwaway runner, and Apple caps how many an account may
// hold; the eleventh run failed with "Choose a certificate to revoke". Run
// before the archive, this revokes the development certificates earlier runs
// created ("Created via API" — nothing a person made), so this run's is the
// only one. Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 in the environment,
// the same secrets the signed build uses. TestFlight builds are signed for
// distribution and are not affected by any of this.
import { createPrivateKey, sign } from 'node:crypto';

const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss, ASC_KEY_P8: rawKey } = process.env;
if (!kid || !iss || !rawKey) { console.log('prune-dev-certs: no App Store Connect key in the environment; nothing to do'); process.exit(0); }
const pem = rawKey.includes('BEGIN PRIVATE KEY') ? rawKey : Buffer.from(rawKey, 'base64').toString('utf8');
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: 'ES256', kid, typ: 'JWT' }), claims = b64({ iss, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
const jwt = `${head}.${claims}.${sign('sha256', Buffer.from(`${head}.${claims}`), { key: createPrivateKey(pem), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
const api = async (path, init = {}) => {
  const r = await fetch(`https://api.appstoreconnect.apple.com/v1${path}`, { ...init, headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' } });
  return [r.status, r.status === 204 ? null : await r.json().catch(() => null)];
};

const [status, list] = await api('/certificates?limit=200&fields[certificates]=certificateType,displayName');
if (status !== 200) { console.log(`prune-dev-certs: could not list certificates (${status}); carrying on`); process.exit(0); }
const stale = (list.data || []).filter((c) => c.attributes.certificateType === 'DEVELOPMENT' && c.attributes.displayName === 'Created via API');
let gone = 0;
for (const cert of stale) {
  const [code] = await api(`/certificates/${cert.id}`, { method: 'DELETE' });
  if (code === 204) gone += 1; else console.log(`prune-dev-certs: ${cert.id} answered ${code}`);
}
console.log(`prune-dev-certs: revoked ${gone} of ${stale.length} development certificate(s) earlier runs created`);
