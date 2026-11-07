# JC-258 Subscription authorization audit

JC-258 requests a complete current action inventory, actor and ownership evidence, direct Ash invocation, sensitive support-read inspection, system-only permission checks, facade authorization classification and stable error behavior. It is an audit and forbids permission or shared-auth changes. Its outcome is PROVEN_GOOD for proved behavior or separate CANDIDATE findings. Missing permission law remains a decision gap.

The branch starts from JC-257 head `8708e06a7cbb397d4951feeca66acd2c3f426eef` and will create the seventh draft PR in the requested stack. Canonical main is `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. The live prerequisite JC-220 is Done. JC-253 is also Done and its stored-method revocation capability exists on main. Historical workstream pins and empty domain-map artifacts do not override current code or the accepted prerequisite.

## Authority and inspected behavior

`docs/governance/policy_matrix.md` explicitly defines SubscriptionPlan, Subscription and RenewalAttempt permissions. The current domain registers ten resources. Compiled Ash metadata on the stack reports 92 actions, including default and generic actions. Two generic audit reads were added by JC-248 and are absent from main. The report must distinguish these baselines and must not present a source-only inventory as compiled main evidence.

The matrix's SYSTEM-only Subscription lifecycle and RenewalAttempt write rows must be compared with current admin alternatives in resource policies. The support payment-method setup facade currently begins from a support-readable Subscription getter, then runs setup work under system authority without an actor argument. These are leads for executable evidence, not permission to patch the implementation inside this audit.

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
5. Run focused and required repository checks, inspect the complete final diff and obtain specification and quality reviews for the exact head. Publish the draft PR above JC-257 and retain human merge control.

Every implementation task gets a complete root-reviewed plan, a fresh worker, specification review and quality review. The final report will state which cells are proved, which observations are policy-only, which authority is absent and which lifecycle or sensitive-field dimensions remain inconclusive.
