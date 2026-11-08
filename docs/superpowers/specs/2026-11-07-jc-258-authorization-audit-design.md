# JC-258 Subscription authorization audit

JC-258 requests a complete current action inventory, actor and ownership evidence, direct Ash invocation, sensitive support-read inspection, system-only permission checks, facade authorization classification and stable error behavior. It is an audit and forbids permission or shared-auth changes. Its outcome is PROVEN_GOOD for proved behavior or separate CANDIDATE findings. Missing permission law remains a decision gap.

The historical JC-258 base is JC-257 head `8708e06a7cbb397d4951feeca66acd2c3f426eef`. The current integration baseline is `523326e69a12213ed26f64d56be9d0070cf3b7a5`; corrected parent JC-257 / PR #219 is `291efbd45a420d92f5955c2ee65b38cbc0515b3e`. The original base and PR #219 review artifact `aa51787bf56dc2ef306793ba119e50792a67399d` remain historical evidence. JC-220 and JC-253 are accepted prerequisites. Current source contains the stored-method revocation capability.

## Authority and inspected behavior

`docs/governance/policy_matrix.md` explicitly defines SubscriptionPlan, Subscription and RenewalAttempt permissions. The current domain registers ten resources and 93 compiled actions. Eight actor contexts produce 744 policy preflight cells. Subscription has 24 actions. The three stack-only actions compared with the historical 90-action source count at canonical main `12cb5ee4107ca465c9b773b258c1cbae4754b2c7` are the two JC-248 generic reads and `Subscription.advance_payment_method_setup_generation`. The source-only comparison is not compiled main evidence.

The facade exports 48 names and 63 name/arity pairs. Its current source has 105 public `def` declarations. The system category contains 34 names, including `list_due_renewal_job_page_for_system`. The inventory test must match actual compiled exports rather than inferred names.

The matrix's SYSTEM-only Subscription lifecycle and RenewalAttempt write rows must be compared with current admin alternatives in resource policies. The support payment-method setup facade begins from a support-readable Subscription getter, reserves a generation, then creates a dedicated setup PaymentIntent under system authority. The dedicated PaymentIntent actions `create_subscription_setup` and `mark_setup_binding_applied` are outside the ten Subscription resources. Inspect them as related system-only operations, without adding them to the 93-action inventory or claiming direct execution certification. Keep the generic PaymentIntent `create` denial. That denial test does not directly test the dedicated setup action. Successful facade tests must retain the real calls and assert the captured generation, exact `pm-update:v2:<subscription_id>:<generation>` key and current Subscription generation. Setup supersession does not resolve whether support may initiate setup. These observations do not authorize permission changes.

The word LIMITED does not name support-readable fields. Inspect what the actual detail result exposes, using synthetic test references, but do not invent a forbidden-field list. Likewise, the matrix does not expressly name newer resources and actions. Record missing authority instead of deriving the intended role model from current implementation.

This is a single-tenant project. Prove customer ownership where defined; add no tenant fields or tenant architecture.

## Evidence design

Inventory every registered resource and named action from compiled metadata. Map each to explicit authority or a named decision gap. Inspect policy predicates and relevant public facade entry points, including actor-driven uses of private system orchestration.

Use the installed Ash version to determine whether a policy-only check yields a definite result without executing lifecycle handlers. `Ash.can?/3` treats an indeterminate result as true by default, so it cannot by itself certify a permission matrix. Any policy probe must distinguish permission from query filtering, valid input, lifecycle guards and actual execution. Add fixture-backed direct calls for required ownership and sensitive write/read proofs. Do not count an unrelated validation error as authorization denial.

Use existing DataCase, actor/role fixtures, Subscription fixtures and local provider test support. Keep fixtures sandboxed unless a concrete physical authority gate requires committed evidence. No real provider calls, new provider, production seam, infrastructure or permission changes are allowed. Run all database-dependent commands through the existing DevCore test environment with four-connection pools and one Mix owner.

## Work sequence

1. Verify the complete inventory and the Ash authorization-checking behavior before writing the executable matrix plan.
2. Add the smallest complete inventory and policy characterization evidence supported by that behavior. Prove direct owner/non-owner reads and governed write distinctions with valid fixtures.
3. Prove the support setup initiation and inspect support detail fields through the actual facade. Classify the remaining facade boundaries and missing authority without inferring Product law.
4. Search the existing queue, then record separate concrete findings or decision gaps in Linear. Write the durable current audit report. Implement no remediation.
5. Run focused and required repository checks, inspect the complete final diff and obtain specification and quality reviews for the exact head. Limit parent-migration edits to the inventory/setup tests and audit/design documents. Preserve the JC-257 audit, addendum and Agent 6 review blob byte-for-byte, along with the other two JC-258 test modules. Keep the PR draft for human review and merge.

Every implementation task gets a complete root-reviewed plan, a fresh worker, specification review and quality review. The final report will state which cells are proved, which observations are policy-only, which authority is absent and which lifecycle or sensitive-field dimensions remain inconclusive.
