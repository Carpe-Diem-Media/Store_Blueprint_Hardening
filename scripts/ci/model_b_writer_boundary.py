"""Job-local OS and fixed-command proof. Never provisions workstation identities."""
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path('/opt/store-membership-writer-ci')
RUNTIME = 'model_b_runtime_os'
OPERATOR = 'model_b_operator_os'
WRITER = 'model_b_writer_os'
TOOLCHAIN = ROOT / 'toolchain'
ELIXIR = TOOLCHAIN / 'elixir/bin/elixir'
OTP = TOOLCHAIN / 'otp'


def discover_toolchain():
    """Read the setup-beam runtime itself, not a guessed installation prefix."""
    result = subprocess.run([shutil.which('elixir'), '--erl', '+S 2:2', '-e',
        'IO.puts(System.version()); IO.puts(:code.root_dir()); IO.puts(System.otp_release())'],
        text=True, capture_output=True, timeout=15, check=True).stdout.splitlines()
    version, otp_root, otp_major = result
    pins = dict(line.split() for line in Path('.tool-versions').read_text().splitlines() if line.strip())
    otp_version = (Path(otp_root) / 'releases' / otp_major / 'OTP_VERSION').read_text().strip()
    if pins['elixir'] != f'{version}-otp-{otp_major}' or pins['erlang'] != otp_version:
        raise RuntimeError('setup-beam runtime does not match the repository pins')
    return dict(elixir_root=str(Path(shutil.which('elixir')).resolve().parent.parent),
                otp_root=str(Path(otp_root).resolve()), elixir_version=version,
                otp_version=otp_version, otp_major=otp_major)


def protected_path(path):
    """Every dependency and ancestor must be root-owned and non-writable."""
    resolved = path.resolve(strict=True)
    if not (resolved.is_relative_to(TOOLCHAIN) or
            resolved.is_relative_to('/usr') or resolved.is_relative_to('/lib')):
        raise RuntimeError(f'external toolchain dependency is not trusted: {resolved}')
    for entry in (resolved, *resolved.parents):
        info = entry.stat()
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError(f'toolchain dependency or ancestor is writable: {entry}')
        if entry.is_dir() and not info.st_mode & 0o001:
            raise RuntimeError(f'toolchain ancestor is not traversable: {entry}')
        if entry.is_file() and not info.st_mode & 0o004:
            raise RuntimeError(f'toolchain dependency is not readable: {entry}')
    return resolved


def protected_search_directory(path):
    """Allow missing search candidates, checking every traversed real ancestor.

    Walk links explicitly: resolving only the final destination would conceal a
    writable or unapproved intermediate directory in a chain of symlinks.
    Required executable/library paths still use strict protected_path instead.
    """
    roots = (TOOLCHAIN, Path('/usr'), Path('/lib'))
    budget = [40]

    def allowed(candidate, ancestor=False):
        return any(candidate.is_relative_to(root) or
                   (ancestor and root.is_relative_to(candidate)) for root in roots)

    def walk(candidate):
        if not candidate.is_absolute() or '$' in str(candidate):
            raise RuntimeError(f'unsupported ELF search path: {candidate}')
        current = Path('/')
        for part in candidate.parts[1:]:
            current = current.parent if part == '..' else current / part
            if not allowed(current, ancestor=True):
                raise RuntimeError(f'untrusted ELF search path: {current}')
            try:
                info = current.lstat()
            except FileNotFoundError:
                continue
            if info.st_uid != 0:
                raise RuntimeError(f'ELF search path is not root-owned: {current}')
            if stat.S_ISLNK(info.st_mode):
                budget[0] -= 1
                if budget[0] < 0:
                    raise RuntimeError('ELF search path symlink limit exceeded')
                target = Path(os.readlink(current))
                current = walk(target if target.is_absolute() else current.parent / target)
                if not allowed(current):
                    raise RuntimeError(f'ELF search symlink escapes allowed prefixes: {current}')
            elif not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022 or not info.st_mode & 0o001:
                raise RuntimeError(f'ELF search ancestor is writable or not traversable: {current}')
        return current

    resolved = walk(path)
    if not allowed(resolved):
        raise RuntimeError(f'ELF search path escapes allowed prefixes: {resolved}')
    # Check / and all actual ancestors as well as the traversed link chain.
    existing = resolved
    while not existing.exists():
        existing = existing.parent
    protected_path(existing)
    return protected_path(resolved) if resolved.exists() else resolved


def linked_dependencies(target, linked):
    """Required ldd results never inherit optional-search-directory semantics."""
    if 'not found' in linked.stdout or (linked.returncode and
            'not a dynamic executable' not in linked.stdout + linked.stderr and
            'statically linked' not in linked.stdout + linked.stderr):
        raise RuntimeError(f'unresolved required ELF dependency: {target}')
    return {str(protected_path(Path(value)))
            for value in re.findall(r'(/[^\s()]+)', linked.stdout)}


def verify_audit_cases():
    """Real root-owned disposable fixtures, before exposing the writer process."""
    def reject(action, label):
        try:
            action()
        except (RuntimeError, FileNotFoundError):
            print(f'PASS ELF_audit rejected={label}', flush=True)
        else:
            raise RuntimeError(f'ELF audit failed to reject {label}')

    optional = Path('/usr/local/lib64')
    was_absent = not optional.exists()
    protected_search_directory(optional)
    if optional.exists() == was_absent:
        raise RuntimeError('optional search directory was unexpectedly created/removed')
    print(f'PASS ELF_audit optional_usr_local_lib64 absent={was_absent}', flush=True)
    with tempfile.TemporaryDirectory(prefix='.audit-', dir=TOOLCHAIN) as directory:
        fixture = Path(directory)
        fixture.chmod(0o755)
        protected_search_directory(fixture)
        protected_search_directory(fixture / 'absent/child')
        print('PASS ELF_audit existing_trusted_and_absent_optional_directories', flush=True)
        writable = fixture / 'writable'
        writable.mkdir(mode=0o755)
        writable.chmod(0o777)
        reject(lambda: protected_search_directory(writable), 'writable_directory')
        reject(lambda: protected_search_directory(writable / 'absent'), 'absent_under_writable_ancestor')
        reject(lambda: protected_search_directory(Path('/tmp/untrusted-elf-search')), 'unapproved_prefix')
        reject(lambda: protected_search_directory(Path('relative/search')), 'relative_search_path')
        reject(lambda: protected_search_directory(Path('/usr/$UNEXPANDED')), 'unexpanded_search_token')
        escape = fixture / 'escape'
        escape.symlink_to('/tmp')
        reject(lambda: protected_search_directory(escape / 'absent'), 'symlink_escape')
        redirect = fixture / 'redirect'
        redirect.symlink_to(writable)
        reject(lambda: protected_search_directory(redirect / 'absent'), 'writable_symlink_intermediate')
        reject(lambda: protected_path(fixture / 'missing.so'), 'strict_missing_dependency')
        # A real ELF first resolves its fixture library, then loses that library.
        # No program is executed; ldd must report the unresolved DT_NEEDED entry.
        library = fixture / 'libmodel_b_audit_fixture.so'
        executable = fixture / 'required-library-probe'
        subprocess.run(['/usr/bin/cc', '-shared', '-fPIC', '-x', 'c', '-', '-o', str(library)],
            input='int model_b_audit_fixture(void) { return 0; }', text=True,
            capture_output=True, timeout=10, check=True)
        subprocess.run(['/usr/bin/cc', '-x', 'c', '-', '-L'+str(fixture),
            '-Wl,-rpath,'+str(fixture), '-lmodel_b_audit_fixture', '-o', str(executable)],
            input='extern int model_b_audit_fixture(void); int main(void) { return model_b_audit_fixture(); }',
            text=True, capture_output=True, timeout=10, check=True)
        linked = subprocess.run(['/usr/bin/ldd', str(executable)],
                                text=True, capture_output=True, timeout=5, check=False)
        linked_dependencies(executable, linked)
        library.unlink()
        linked = subprocess.run(['/usr/bin/ldd', str(executable)],
                                text=True, capture_output=True, timeout=5, check=False)
        if 'libmodel_b_audit_fixture.so => not found' not in linked.stdout:
            raise RuntimeError('missing-library ELF fixture did not exercise ldd not found')
        reject(lambda: linked_dependencies(executable, linked), 'actual_ldd_missing_required_library')


def install_toolchain(data):
    sources = [(Path(data['elixir_root']), TOOLCHAIN / 'elixir'),
               (Path(data['otp_root']), OTP)]
    for source, destination in sources:
        shutil.copytree(source, destination, symlinks=True)
    # Preserve only links within the copied installation closure. Rewrite
    # absolute source-prefix links as relative links to the protected copy.
    for _, destination in sources:
        for directory, directories, files in os.walk(destination, followlinks=False):
            for name in directories + files:
                link = Path(directory) / name
                if not link.is_symlink():
                    continue
                source = next(s for s, d in sources if link.is_relative_to(d))
                original = source / link.relative_to(destination)
                target = original.resolve(strict=True)
                mapped = next((d / target.relative_to(s) for s, d in sources if target.is_relative_to(s)), None)
                if mapped is None:
                    raise RuntimeError(f'toolchain symlink leaves copied closure: {original}')
                link.unlink()
                link.symlink_to(os.path.relpath(mapped, link.parent))
    for directory, directories, files in os.walk(TOOLCHAIN, followlinks=False):
        for path in [Path(directory)] + [Path(directory) / n for n in directories + files]:
            os.chown(path, 0, 0, follow_symlinks=False)
            if not path.is_symlink():
                mode = path.stat().st_mode
                path.chmod(0o555 if path.is_dir() or mode & 0o111 else 0o444)
    verify_audit_cases()
    count = 0
    dependencies = set()
    for path in TOOLCHAIN.rglob('*'):
        target = protected_path(path)
        if path.is_symlink() and not target.is_relative_to(TOOLCHAIN):
            raise RuntimeError('installed symlink escapes the protected toolchain')
        if not target.is_file() or path.is_symlink():
            continue
        with target.open('rb') as file:
            if file.read(4) != b'\x7fELF':
                continue
        count += 1
        dynamic = subprocess.run(['/usr/bin/readelf', '-d', str(target)],
                                 text=True, capture_output=True, timeout=5, check=True).stdout
        for paths in re.findall(r'\((?:RPATH|RUNPATH)\).*\[(.*?)\]', dynamic):
            for value in paths.split(':'):
                value = value.replace('${ORIGIN}', str(target.parent)).replace('$ORIGIN', str(target.parent))
                try:
                    if not value:
                        raise RuntimeError('empty dynamic search path')
                    protected_search_directory(Path(value))
                except (RuntimeError, OSError, ValueError) as error:
                    raise RuntimeError(f'ELF={target} search_path={value}: {error}') from error
        linked = subprocess.run(['/usr/bin/ldd', str(target)], text=True,
                                capture_output=True, timeout=5, check=False)
        dependencies.update(linked_dependencies(target, linked))
    for command in ('/bin/sh', '/usr/bin/env', '/usr/bin/timeout', '/usr/bin/id',
                    '/usr/bin/dirname', '/usr/bin/basename', '/usr/bin/readlink'):
        protected_path(Path(command))
    print(f'PASS protected_toolchain elixir={data["elixir_version"]} OTP={data["otp_version"]} '
          f'ELF_objects={count} system_dependencies={len(dependencies)}', flush=True)
    subprocess.run(['/usr/bin/namei', '-l', str(ELIXIR)], check=True)
    subprocess.run(['/usr/bin/readlink', '-f', str(ELIXIR)], check=True)
    subprocess.run(['/usr/bin/stat', '-c', '%U:%G %a %n', str(ELIXIR), str(OTP / 'bin/erl')], check=True)


def install():
    # Trusted ephemeral CI bootstrap only. This is not an invocation interface.
    if os.geteuid() != 0:
        raise RuntimeError('job bootstrap requires root')
    data = json.load(sys.stdin)
    if ROOT.exists():
        raise RuntimeError('refusing to replace an existing boundary installation')
    for identity in (RUNTIME, OPERATOR, WRITER):
        subprocess.run(['/usr/sbin/useradd', '--system', '--user-group', '--no-create-home',
                        '--shell', '/usr/sbin/nologin', identity], check=True)
    import pwd
    writer = pwd.getpwnam(WRITER)
    # Hosted image /opt permissions are not an isolation guarantee. Seal the
    # ancestor in this disposable VM before exposing any unprivileged process.
    # Do not relax the closure audit or touch the runner-private source tree.
    subprocess.run(['/usr/bin/stat', '-c', 'before %U:%G %a %n', '/opt'], check=True)
    os.chown('/opt', 0, 0)
    Path('/opt').chmod(0o755)
    subprocess.run(['/usr/bin/stat', '-c', 'after %U:%G %a %n', '/opt'], check=True)
    ROOT.mkdir(mode=0o755)
    install_toolchain(data)
    for library in Path('_build/test/lib').iterdir():
        if (library / 'ebin').is_dir():
            shutil.copytree(library / 'ebin', ROOT / 'lib' / library.name / 'ebin')
    for directory, _, files in os.walk(ROOT / 'lib'):
        os.chmod(directory, 0o555)
        for name in files:
            os.chmod(Path(directory) / name, 0o444)
    private = ROOT / 'private'
    private.mkdir(mode=0o750)
    os.chown(private, 0, writer.pw_gid)
    credential = private / 'connection.json'
    credential.write_text(json.dumps(dict(
        hostname='127.0.0.1', port=55433, database='model_b_role_proof',
        username='model_b_allocation_writer', password=data['password'],
        writer_uid=writer.pw_uid,
    )))
    os.chown(credential, 0, writer.pw_gid)
    credential.chmod(0o440)
    # No shell input, caller command, arguments, environment or credential fallback.
    launcher = ROOT / 'launch'
    import shlex
    launcher.write_text(
        '#!/bin/sh\nset -eu\n'
        '[ "$#" -eq 0 ] || exit 23\n'
        f'[ "$(/usr/bin/id -u)" -eq {writer.pw_uid} ] || exit 23\n'
        f'cd {ROOT}\n'
        'exec /usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin LANG=C.UTF-8 '
        + 'ERTS_BIN=' + shlex.quote(str(OTP / 'bin') + '/') + ' '
        + 'ERL_ROOTDIR=' + shlex.quote(str(OTP)) + ' '
        '/usr/bin/timeout --signal=KILL 15s '
        + shlex.quote(str(ELIXIR))
        + " --erl '+S 2:2' -pa '/opt/store-membership-writer-ci/lib/*/ebin' "
        + "-e 'case Store.Release.membership_writer_boundary_probe() do "
        + ":ok -> :ok; _ -> System.halt(23) end' </dev/null\n"
    )
    launcher.chmod(0o755)
    rule = Path('/etc/sudoers.d/model-b-writer-ci')
    rule.write_text(f'{OPERATOR} ALL=({WRITER}) NOPASSWD:NOSETENV: {launcher} ""\n')
    rule.chmod(0o440)
    subprocess.run(['/usr/sbin/visudo', '-cf', str(rule)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def verify_writer_boundary(h):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('MODEL_B_CI_DISPOSABLE') != 'true':
        raise RuntimeError('OS boundary proof requires the disposable CI job')
    if not Path('_build/test/lib/store/ebin/Elixir.Store.Orders.MembershipWriterBoundary.beam').is_file():
        raise RuntimeError('fixed isolated writer boundary is not implemented')
    toolchain = discover_toolchain()
    bootstrap = subprocess.run(
        ['sudo', '-n', sys.executable, __file__, '--install'],
        input=json.dumps(dict(password=h.PASSWORDS[h.WRITER], **toolchain)),
        text=True, capture_output=True, timeout=180,
    )
    diagnostic = bootstrap.stdout + bootstrap.stderr
    for secret in list(h.PASSWORDS.values()) + [h.ADMIN_PASSWORD]:
        if secret:
            diagnostic = diagnostic.replace(secret, '[REDACTED]')
    print(diagnostic[-6000:], flush=True)
    if bootstrap.returncode:
        raise RuntimeError('job-local OS boundary bootstrap failed')

    def run(identity, command, expected=0, env=None, label=None):
        # The harness has bootstrap authority. The tested command itself runs
        # under the real unprivileged identity, with none of that authority.
        result = subprocess.run(['sudo', '-n', '-u', identity, '--'] + command,
            text=True, capture_output=True, timeout=20, env=env, cwd=ROOT)
        if result.returncode != expected:
            diagnostic = result.stderr[-2000:]
            for secret in list(h.PASSWORDS.values()) + [h.ADMIN_PASSWORD]:
                if secret:
                    diagnostic = diagnostic.replace(secret, '[REDACTED]')
            print(f'Boundary diagnostic returncode={result.returncode}: {diagnostic}', flush=True)
            raise RuntimeError(f'OS boundary assertion failed for {identity}')
        if label:
            print(f'PASS OS_principal={identity} {label} exit={result.returncode}', flush=True)
        return result

    beam = ['/usr/bin/env', '-i', 'HOME=/nonexistent', 'PATH=/usr/bin:/bin',
            'ERTS_BIN='+str(OTP / 'bin')+'/', 'ERL_ROOTDIR='+str(OTP),
            str(ELIXIR), '--erl', '+S 2:2', '-pa', str(ROOT / 'lib/*/ebin')]
    version = run(RUNTIME, beam + ['-e',
        'IO.puts(System.version()); IO.puts(:code.root_dir()); IO.puts(System.otp_release())'],
        label='installed_BEAM_executes')
    if version.stdout.splitlines() != [toolchain['elixir_version'], str(OTP), toolchain['otp_major']]:
        raise RuntimeError('relocated toolchain version/root mismatch')
    for identity in (RUNTIME, OPERATOR, WRITER):
        writable = run(identity, ['/usr/bin/find', str(TOOLCHAIN), '-writable', '-print', '-quit'])
        if writable.stdout:
            raise RuntimeError(f'protected toolchain is writable by {identity}')
        print(f'PASS OS_principal={identity} toolchain_tree_not_writable', flush=True)

    launch = ['/usr/bin/sudo', '-n', '-u', WRITER, '--', str(ROOT / 'launch')]
    result = run(OPERATOR, launch)
    report = json.loads(result.stdout)
    writer_uid = int(subprocess.run(['/usr/bin/id', '-u', WRITER], text=True,
                                   capture_output=True, check=True).stdout)
    if (report.get('database_role') != h.WRITER or report.get('session_role') != h.WRITER
            or report.get('store_started') is not False or report.get('privileged_membership') is not False
            or report.get('os_uid') != writer_uid):
        raise RuntimeError('writer process attestation failed')
    print('PASS operator_fixed_invocation ' + json.dumps(report, sort_keys=True), flush=True)
    for identity in (RUNTIME,):
        run(identity, launch, expected=1, label='sudo_writer_denied')
        run(identity, ['/usr/bin/sudo', '-n', '-u', OPERATOR, '--', str(ROOT / 'launch')], expected=1, label='operator_impersonation_denied')
        run(identity, [str(ROOT / 'launch')], expected=23, label='direct_launcher_UID_denied')
        run(identity, ['/usr/bin/cat', str(ROOT / 'private/connection.json')], expected=1, label='credential_read_denied')
        run(identity, ['/usr/bin/test', '-w', str(ROOT / 'launch')], expected=1, label='launcher_write_denied')
        run(identity, ['/usr/bin/test', '-w', str(ROOT / 'lib/store/ebin/Elixir.Store.Release.beam')], expected=1, label='code_write_denied')
    print('PASS runtime_launch_impersonation_credentials_and_code_write_denied', flush=True)
    # Missing OS authentication and supplied actor/environment claims do not
    # create authority. Even the authorized operator cannot change the command.
    run(OPERATOR, [str(ROOT / 'launch')], expected=23, label='missing_writer_UID_denied')
    run(OPERATOR, launch + ['system=true'], expected=1, label='extra_arguments_denied')
    run(RUNTIME, ['/usr/bin/env', 'SUDO_USER='+OPERATOR, 'STORE_SYSTEM=true'] + launch, expected=1, label='forged_actor_environment_denied')
    print('PASS missing_forged_authentication_and_arbitrary_arguments_denied', flush=True)
    # Exercise the exported release function inside an ordinary-runtime BEAM.
    denied = run(RUNTIME, beam + ['-e',
        'IO.puts("BEAM_STARTED"); '
        'case Store.Release.membership_writer_boundary_probe() do '
        '{:error, :writer_boundary_denied} -> IO.puts("AUTH_DENIED"); System.halt(23); _ -> System.halt(1) end'], expected=23)
    if denied.stdout.splitlines() != ['BEAM_STARTED', 'AUTH_DENIED']:
        raise RuntimeError('ordinary runtime BEAM did not reject direct invocation')
    print('PASS actual_runtime_BEAM_direct_entrypoint_denied', flush=True)
    # Cross-UID /proc isolation is tested with a harmless writer-UID process.
    # It contains no database secret, and is not an alternate writer entrypoint.
    child = subprocess.Popen(['sudo', '-n', '-u', WRITER, '--', '/usr/bin/sleep', '10'])
    try:
        import time
        for _ in range(50):
            pid = subprocess.run(['pgrep', '-u', WRITER, '-x', 'sleep'],
                text=True, capture_output=True, check=False).stdout.strip()
            if pid.isdigit():
                break
            time.sleep(.02)
        else:
            raise RuntimeError('writer OS process could not be observed')
        run(RUNTIME, ['/usr/bin/cat', f'/proc/{pid}/environ'], expected=1, label='cross_UID_environment_read_denied')
        run(RUNTIME, ['/usr/bin/kill', '-0', pid], expected=1, label='cross_UID_signal_denied')
        print('PASS runtime_cross_UID_environment_read_and_process_control_denied', flush=True)
    finally:
        subprocess.run(['sudo', '-n', '/usr/bin/pkill', '-u', WRITER, '-x', 'sleep'],
                       capture_output=True, check=False)
        child.communicate(timeout=5)


if __name__ == '__main__':
    if sys.argv != [__file__, '--install']:
        raise SystemExit(23)
    install()
