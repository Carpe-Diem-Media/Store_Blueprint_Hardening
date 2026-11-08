# JC-248 verification diagnostics

Use `subagent-driven-development` for R5. Root owns Mix, DevCore, formatting, Git and external writes. Preserve current verification authority, repair fencing and the two-row active-grant query. Diagnostics cannot authorize a grant mutation.

## Test first

Add a verification regression for a current non-effective APPLIED target with one lingering active grant. Compare current, expired and future validity in separate cases and require distinct stable classifications and explicit effective-at-observation evidence. Keep the effect insertion high-water separate from the observation time. Root observes the missing fields on the unchanged implementation before production edits.

Use a small pure classifier to test exact inclusive valid-from and exclusive valid-until boundaries at a fixed time. Cover wrong owner, kind, scope, validity and revocation metadata. Missing required target and missing currently required access must be different. An expired or future desired target does not require current access.

## Output contract

Capture `observed_at` once per verification page. For every repair candidate, retain Subscription and expected-effect IDs and add bounded diagnostic evidence. Return fixed enum classifications, desired target effectiveness at that time and at most two sampled grant observations. Each sample identifies the grant and its temporal state, effective status and relevant target-match flags.

State sample limit and completeness explicitly. Fewer than two rows means the sample is complete; two rows may omit more grants. A partial sample can prove a visible over-grant, but cannot prove the absence of an unseen matching grant. Use an explicit unproven classification instead of asserting missing required target or missing current access in that case. Expose whether an exact target appeared in the sample separately from these absence claims. Never describe a partial sample of expired/future rows as proof that the whole source is non-effective.

Use stable classes for effective over-grant, expired active cleanup, future active cleanup, wrong owner/kind/scope/validity, invalid revocation metadata, missing required target, missing current access and incomplete evidence where applicable. A currently effective row is an over-grant when its capability/owner is not currently required by the target. A validity mismatch with the same currently required capability still needs repair, but does not by itself prove effective over-grant at observation time.

Classify observed rows individually against the target. An exact valid target row is not stale cleanup merely because its interval is expired or future, including when another sampled row makes the whole source mismatch. Add a mixed-sample regression so diagnostics do not describe a legitimate target row as an obligation to retire it.

The facade uses the classifier only after existing immutable authority validation and exact source mismatch detection. Healthy rows remain healthy. The worker must take only `subscription_id` and `expected_access_effect_id` when creating repair jobs; diagnostic fields must never enter repair job arguments. Existing caller argument whitelists remain strict.

## Telemetry and validation

Aggregate a fixed set of classification counts in the page telemetry and include the observation time as metadata. Avoid unbounded payloads, dynamic atoms and high-cardinality grant/user data in telemetry. No operator dashboard or alert policy is included.

Add worker assertions that diagnostic candidates still enqueue exactly the accepted two-key repair identity. Keep invalid caller-supplied diagnostics rejected. Root runs focused red/green tests, existing verification tests, and the full issue checks. Obtain independent specification and quality reviews. The two-row sample remains a bounded diagnostic sample, not a global access proof or a new authority source.

## Observed validation

The facade regression failed against the unchanged implementation because `observed_at` was absent. After implementation, the diagnostics and effective-execution modules passed 80 tests including real-connection cases. Fresh specification and quality reviews found no actionable defect. A later lint refactor received separate specification and quality rechecks with no findings.

The final local `mix check` passed three properties and 1,683 tests with zero failures and 31 exclusions. Strict Credo, types and TEST migration alignment passed. The five-module required real-connection command passed 25 tests twice on the same private DevCore database. The three other connection modules passed six tests. No ignore list or required check was weakened. Exact-head CI and independent external re-verification remain pending publication.

Verification remains bounded to two active samples per source. Repair still loads and locks all grants for one source; arbitrary source history, memory, GC, lock duration and capacity remain UNMEASURED. Sender-local delivery evidence does not certify receiving-node cache eviction or remote PubSub receipt. JC-374 tracks the separate receiver-cache gap.
