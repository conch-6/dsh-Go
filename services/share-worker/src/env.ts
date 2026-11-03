import type { RateLimiter } from './limits';

export interface Env {
  /** HTTPS publication root; defaults to dsh-go-market GitHub Pages. */
  MARKET_SOURCE_URL?: string;
  /** Static files (public/): the site, and the viewer the Worker serves at /c/<id>. */
  ASSETS: { fetch(request: Request): Promise<Response> };
  /** Ciphertexts, under the tier prefixes of ids.ts. */
  BUCKET: R2Bucket;
  /** The public download bucket (dshgo-dl, at DL_BASE_URL): the cron writes
   *  the market's files there (src/market.ts). */
  DL: R2Bucket;
  /** Hourly upload counters; beta grants and blocks (`beta:` keys). */
  QUOTA?: KVNamespace;
  UPLOAD_BURST?: RateLimiter;
  READ_LIMIT?: RateLimiter;
  /** Secret: lets `DELETE` remove any link (reports). */
  ADMIN_KEY?: string;
  UPLOADS_PER_HOUR?: string;
  MAX_BYTES?: string;
  /** Wrong access keys per client (src/beta-guard.ts). */
  BETA_GUARD?: DurableObjectNamespace;
  /** Secret: keys the access-key hashes and signs beta download links
   *  (src/beta-auth.ts). Without it /beta is 404. */
  BETA_SECRET?: string;
  /** "public": /download serves the latest build to anyone and /beta
   *  redirects there. Anything else (default "key"): an access key on /beta. */
  DOWNLOAD_ACCESS?: string;
  /** Base URL of the Hong Kong bucket (the China route): files are at
   *  `<base><version>/<file>`. Empty or not https: the route isn't offered. */
  CN_BASE_URL?: string;
  /** Base URL of the public download bucket (dshgo-dl): files at
   *  `<base>download/<version>/<file>`, the Global route's once a release is
   *  there. Empty or not https: Global stays on /download/<version>/<file>. */
  DL_BASE_URL?: string;
  /** Workers Analytics Engine datasets (src/stats.ts, src/usage.ts). */
  DOWNLOADS?: AnalyticsEngineDataset;
  CHECKS?: AnalyticsEngineDataset;
  USAGE?: AnalyticsEngineDataset;
  /** Today's random salt for daily device codes (src/stats.ts). */
  STATS_SALT?: DurableObjectNamespace;
  /** Secret: keys the hash of the app's install id (src/usage.ts). Without
   *  it /api/usage/v1 is 404. */
  USAGE_SECRET?: string;
  /** Usage reports per client per minute. */
  USAGE_LIMIT?: RateLimiter;
  /** Optional secret: a GitHub token (no scopes) for the star count's API
   *  requests, which otherwise share GitHub's per-IP limit (src/github.ts). */
  GITHUB_TOKEN?: string;
}
