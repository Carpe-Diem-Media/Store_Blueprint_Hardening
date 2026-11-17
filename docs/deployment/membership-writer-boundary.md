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

## Protected Elixir/OTP installation

The trusted bootstrap discovers the active setup-beam Elixir script and OTP root
from the running toolchain. It verifies System.version, OTP release and the full
OTP_VERSION file against `.tool-versions`. It copies those exact installations
under `/opt/store-membership-writer-ci/toolchain`, without changing access to the
runner's private setup-beam directories.

Internal symlinks are rewritten to relative links within the copied installation;
links outside that closure reject installation. Files and directories are owned
by root, with read/traverse/execute access and no unprivileged write access. The
bootstrap checks ELF RPATH/RUNPATH and ldd dependencies, rejects missing libraries
or writable/private dependency paths, and records namei/readlink/stat evidence.
It also makes the disposable VM's `/opt` ancestor root-owned with mode 0755;
an image-default writable ancestor must not permit replacement of the protected
installation. This restriction is never applied to a workstation or shared host.
System loader/libraries remain dependencies of the pinned runtime; their resolved
paths and ancestors must be root-owned and non-writable by unprivileged accounts.

ELF search directories are candidates, not required libraries. An absent optional
RPATH/RUNPATH directory, including `/usr/local/lib64`, is accepted only within the
allowed prefixes after checking every existing ancestor and traversed symlink.
The audit does not create it. Existing search directories remain subject to the
strict ownership/traversal audit. Writable ancestry, private/unapproved paths and
symlink escapes reject, including when the final directory is absent. Failures
identify the ELF object and search entry. Actual executables and ldd-resolved
libraries must exist and pass strict protection checks; unresolved required
libraries remain fatal. Disposable fixtures exercise these distinctions, including
a real ELF whose required fixture library is removed before its second ldd check.

Both the fixed launcher and the direct-runtime BEAM test use this installation,
fixed ERTS_BIN/ERL_ROOTDIR and a cleared environment. They run from the protected
installation directory. CI first proves that the runtime UID can execute the
installed version and obtain the expected relocated OTP root. Its authorization
test then requires both BEAM_STARTED and AUTH_DENIED markers plus exit 23. An
inaccessible executable or another nonzero exit fails the test. Each remaining
negative assertion checks its exact expected exit code; all three OS identities
must find no writable path anywhere in the toolchain tree.

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
