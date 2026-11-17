# Membership writer boundary proof

This DEV/TEST proof runs only in the existing disposable Model B CI job. It
does not install a workstation or production launcher and performs no financial
evaluation or acceptance. The existing PostgreSQL role and integrity proofs run
before it. No Phoenix endpoint, Oban job or long-running service is added.

The trusted GitHub job bootstrap uses its existing sudo capability to create
three job-local system identities. They have locked passwords, no home directory
and a nologin shell. The bootstrap remains trusted and holds provisioning secrets;
it is not the ordinary-runtime identity used for security assertions.

- `model_b_operator_os` can sudo to `model_b_writer_os` for exactly the installed
  `/opt/store-membership-writer-ci/launch` command with no arguments. Authentication
  is the OS account established by the trusted job supervisor and checked by sudo.
  Caller actor fields, environment variables and claimed usernames are not proof.
- `model_b_runtime_os` has no sudo permission, writer group membership or private
  file access. The tests run arbitrary probes and an actual BEAM under this UID.
- `model_b_writer_os` can read only its root-owned connection file and execute
  root-owned code. It receives the restricted allocation-writer database login,
  with no runtime, owner, migrator, provider or application secrets.

The fixed launcher checks its actual UID, discards the caller environment and
stdin, and executes one fixed release function under a 15-second process timeout.
No caller command, SQL, rate, tax context, code path or credential is accepted.
The function verifies its Linux UID and the fixed connection file, starts only
Postgrex dependencies, checks the actual database session principal and restricted
role attributes, closes the connection and exits. It starts no Store application,
Phoenix, Oban or Erlang distribution. Database timeouts are two seconds for this
read-only probe; financial acceptance timeouts and SQL helpers are unchanged.

CI checks authorized invocation, forbidden runtime invocation and impersonation,
file/code permissions, forged actor claims, extra arguments, direct runtime BEAM
invocation and cross-UID process environment/signal access. A harmless sleeping
process supplies the cross-UID `/proc` target; it contains no database credentials.
No single-process credential test is presented as OS separation.

The protected code copy and private files are outside the runtime-writable
checkout. Root and the trusted bootstrap can impersonate these accounts and remain
outside Model B's restricted-runtime threat model. A compromised writer remains
trusted under the approved model. The job's disposable VM destroys its identities,
sudo rule and installation after the run; nothing is installed on shared DevCore.

## Limits and next gate

GitHub job authorization and the supervisor-created operator OS identity are the
authentication root in this proof. This does not establish a human Store admin's
step-up, a workstation operator identity, or production launcher authorization.
The Pricing maintainer is outside this task. Existing host-level dev processes
running as the workstation owner do not gain this CI isolation automatically.

Workstation or production activation requires a separately verified supervisor,
operator account admission, protected code installation and private secret mount.
Do not substitute a shared UID, caller environment flag, extra Repo, or another
DATABASE_URL. No rollout or new service is authorized by this proof.

The later acceptance slice must add independently derived Pricing evidence and a
complete prelocked occurrence manifest. This probe grants no financial authority.

## Performance and resource safety

One cold process uses one Postgrex connection and one fixed read-only query. It
starts no application pool, cache, queue or background workflow. The connection is
closed after the query; the launcher kills over-budget processes. The CI harness
reaps its temporary process. Capacity and post-load convergence are unmeasured.
