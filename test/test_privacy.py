#!/usr/bin/env python3
"""真实隔离 nginx：只用临时根、loopback 高端口和合成 TLS PEM，不加载生产配置。"""
import contextlib
import os
from pathlib import Path
import runpy
import socket
import ssl
import subprocess
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'ngx'
DUMMY = 'NGX_PRIVACY_DUMMY_123456'


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class PrivacyTests(unittest.TestCase):
    def test_generated_queryless_and_real_requests(self):
        for policy in ('standard', 'queryless'):
            with self.subTest(policy=policy), tempfile.TemporaryDirectory(prefix='ngx-privacy-') as tmp:
                root = Path(tmp)
                with contextlib.ExitStack() as stack:
                    old = os.environ.get('NGX_ROOT')
                    os.environ['NGX_ROOT'] = tmp
                    stack.callback(lambda: os.environ.pop('NGX_ROOT', None) if old is None else os.environ.__setitem__('NGX_ROOT', old))
                    m = runpy.run_path(str(SOURCE))
                etc = root / 'etc/nginx'
                etc.mkdir(parents=True)
                (root / 'run').mkdir()
                (etc / 'nginx.conf').write_text(
                    f'pid {root}/run/nginx.pid;\nerror_log {root}/master-error.log info;\n'
                    f'events {{}}\nhttp {{\naccess_log {root}/distro-access.log;\ninclude {etc}/conf.d/*.conf;\ninclude {etc}/sites-enabled/*;\n}}\n')
                if policy == 'queryless':
                    main = etc / 'nginx.conf'
                    main.write_text(m['queryless_main_config'](main.read_text()))
                m['config_set']('LOG_PRIVACY', policy)
                m['layout']()
                http_port, tls_port, dead_port = port(), port(), port()
                site = dict(m['DEFAULTS'], name='privacy', domains=['privacy.example'],
                            port=443, upstream=f'http://127.0.0.1:{dead_port}')
                m['save'](site)
                cert, key = map(Path, m['cert_files'](site))
                cert.parent.mkdir(parents=True)
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                                '-subj', '/CN=privacy.example', '-keyout', str(key), '-out', str(cert)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                m['generate'](site)
                m['symlink'](m['conf_path']('privacy'), m['link_path']('privacy'))
                m['privacy_guard']()
                # 测试副本只改监听地址到loopback高端口，策略本身完全来自生成器。
                for file in (etc / 'sites-available').glob('*.conf'):
                    text = file.read_text()
                    if policy == 'queryless':
                        self.assertEqual(text.count('server {'), text.count('error_log /dev/null;'))
                        self.assertEqual(text.count('server {'), text.count('access_log '))
                    text = text.replace('listen [::]:80', f'listen [::1]:{http_port}')
                    text = text.replace('listen 80', f'listen 127.0.0.1:{http_port}')
                    text = text.replace('listen [::]:443', f'listen [::1]:{tls_port}')
                    text = text.replace('listen 443', f'listen 127.0.0.1:{tls_port}')
                    file.write_text(text)
                if policy == 'queryless':
                    fmt = (etc / 'conf.d/ngx-http.conf').read_text().split('log_format ngx_queryless ', 1)[1].split(';', 1)[0]
                    for forbidden in ('$request', '$uri', '$args', '$http_', '$host', '$remote_user'):
                        # $request_time is bounded numeric, not the raw request.
                        self.assertNotIn(forbidden, fmt.replace('$request_time', ''))
                checked = subprocess.run(['nginx', '-t', '-p', tmp + '/', '-c', str(etc / 'nginx.conf')], capture_output=True)
                self.assertEqual(checked.returncode, 0, checked.stderr.decode())
                proc = subprocess.Popen(['nginx', '-p', tmp + '/', '-c', str(etc / 'nginx.conf'), '-g', 'daemon off;'],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            with socket.create_connection(('127.0.0.1', http_port), timeout=.1):
                                break
                        except OSError:
                            if time.monotonic() > deadline or proc.poll() is not None:
                                self.fail('isolated nginx did not become ready')
                    cases = [(http_port, False, 'privacy.example', '/redirect', False),
                             (http_port, False, 'privacy.example', '/.well-known/acme-challenge/missing', False),
                             (http_port, False, 'unknown.example', '/fallback', False),
                             (http_port, False, 'privacy.example', '/early', True),
                             (tls_port, True, 'privacy.example', '/upstream-fails', False),
                             (tls_port, True, 'privacy.example', '/.well-known/acme-challenge/missing', False),
                             (tls_port, True, 'privacy.example', '/early', True)]
                    statuses = []
                    for p, tls, host, path, malformed in cases:
                        conn = socket.create_connection(('127.0.0.1', p), timeout=2)
                        if tls:
                            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                            ctx.check_hostname = False
                            ctx.verify_mode = ssl.CERT_NONE  # 仅此合成自签测试，不改生成器TLS设置。
                            conn = ctx.wrap_socket(conn, server_hostname='privacy.example')
                        with conn:
                            extra = 'Host: duplicate.example\r\n' if malformed else ''
                            req = (f'GET {path}?api_key={DUMMY} HTTP/1.1\r\nHost: {host}\r\n{extra}'
                                   f'Referer: https://ref.invalid/?token={DUMMY}\r\n'
                                   f'User-Agent: {DUMMY}\r\nConnection: close\r\n\r\n')
                            conn.sendall(req.encode())
                            data = b''
                            while True:
                                chunk = conn.recv(65536)
                                if not chunk:
                                    break
                                data += chunk
                            statuses.append(int(data.split(b' ', 2)[1]))
                    self.assertEqual(statuses, [301, 404, 404, 400, 502, 404, 400])
                finally:
                    proc.terminate()
                    stdout, stderr = proc.communicate(timeout=5)
                logdata = b'\n'.join(p.read_bytes() for p in root.rglob('*.log')) + stdout + stderr
                if policy == 'queryless':
                    self.assertNotIn(DUMMY.encode(), logdata)
                    access = b'\n'.join(p.read_bytes() for p in root.rglob('*.access.log'))
                    self.assertTrue(access.strip(), 'queryless must retain safe status/timing logs')
                    self.assertIn(b'502', access)
                else:
                    self.assertIn(DUMMY.encode(), logdata, 'baseline must demonstrate the real leak')

    def test_guard_rejects_uncontrolled_configuration(self):
        with tempfile.TemporaryDirectory(prefix='ngx-privacy-guard-') as tmp:
            old = os.environ.get('NGX_ROOT')
            os.environ['NGX_ROOT'] = tmp
            try:
                m = runpy.run_path(str(SOURCE))
            finally:
                if old is None:
                    os.environ.pop('NGX_ROOT', None)
                else:
                    os.environ['NGX_ROOT'] = old
            root = Path(tmp)
            etc = root / 'etc/nginx'
            etc.mkdir(parents=True)
            (etc / 'nginx.conf').write_text(f'events {{}} http {{ include {etc}/conf.d/*.conf; include {etc}/sites-enabled/*; }}')
            m['config_set']('LOG_PRIVACY', 'queryless')
            m['layout']()
            m['privacy_guard']()
            custom = root / 'etc/ngx/custom/custom.conf'
            custom.write_text('error_log /tmp/raw.log;\n')
            with self.assertRaises(m['Fail']):
                m['privacy_guard']()
            custom.write_text('# comment only\n')
            m['privacy_guard']()
            main = etc / 'nginx.conf'
            baseline = main.read_text()
            main.write_text('events {} http { error_log /tmp/raw.log; }')
            with self.assertRaises(m['Fail']):
                m['privacy_guard']()
            main.write_text(baseline)
            extra = etc / 'conf.d/extra.conf'
            extra.write_text('server {}\n')
            with self.assertRaises(m['Fail']):
                m['privacy_guard']()

    def test_lexical_and_include_graph_bypasses_rejected(self):
        # Every case must be legal to real nginx and demonstrate a raw dummy leak
        # without the guard. Names alone (including managed names) confer no trust.
        for attack in ('quoted_error', 'quoted_include', 'quoted_server', 'hash_string',
                       'escaped_path', 'mime_server', 'managed_http', 'managed_site'):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory(prefix='ngx-privacy-attack-') as tmp:
                old = os.environ.get('NGX_ROOT')
                os.environ['NGX_ROOT'] = tmp
                try:
                    m = runpy.run_path(str(SOURCE))
                finally:
                    if old is None:
                        os.environ.pop('NGX_ROOT', None)
                    else:
                        os.environ['NGX_ROOT'] = old
                root = Path(tmp)
                etc = root / 'etc/nginx'
                etc.mkdir(parents=True)
                main = etc / 'nginx.conf'
                main.write_text(f'pid {root}/nginx.pid; error_log /dev/null; events {{}} http {{ include {etc}/conf.d/*.conf; include {etc}/sites-enabled/*; }}')
                m['config_set']('LOG_PRIVACY', 'queryless')
                m['layout']()
                p = port()
                raw = root / 'raw.log'
                server = f'server {{ listen 127.0.0.1:{p}; error_log /dev/null; access_log off; location / {{ return 404; }} }}'
                site = etc / 'sites-available/ngx-acme-80.conf'
                site.write_text(server)
                m['privacy_guard']()
                if attack == 'quoted_error':
                    # Connection failure produces an error containing the request query.
                    site.write_text(f'server {{ listen 127.0.0.1:{p}; "error_log" {raw} info; access_log off; location / {{ proxy_pass http://127.0.0.1:{port()}; }} }}')
                elif attack == 'escaped_path':
                    # nginx accepts escaped spaces in quoted filenames.
                    raw = root / 'raw file.log'
                    escaped = str(raw).replace(' ', '\\ ')
                    site.write_text(f'server {{ listen 127.0.0.1:{p}; access_log "{escaped}" combined; location / {{ return 404; }} }}')
                elif attack == 'quoted_include':
                    injected = root / 'injected.conf'
                    injected.write_text(f'access_log {raw} combined;')
                    site.write_text(server.replace('access_log off;', f'"include" {injected};'))
                elif attack == 'quoted_server':
                    site.write_text(server.replace('server {', '"server" {').replace('access_log off;', f'access_log {raw} combined;'))
                elif attack == 'hash_string':
                    http = etc / 'conf.d/ngx-http.conf'
                    http.write_text(http.read_text() + f'\nlog_format raw "$args#literal";\n')
                    site.write_text(server.replace('access_log off;', f'access_log {raw} raw;'))
                elif attack == 'mime_server':
                    site.write_text('')
                    mime = etc / 'mime.types'
                    mime.write_text('types { text/plain txt; }\n' + server.replace('access_log off;', f'access_log {raw} combined;'))
                    main.write_text(main.read_text().replace('http {', f'http {{ include {mime};'))
                elif attack == 'managed_http':
                    http = etc / 'conf.d/ngx-http.conf'
                    http.write_text(http.read_text().replace('ngx-http.access.log ngx_queryless', 'raw.log combined'))
                    site.write_text(server.replace('access_log off;', f'access_log {raw} combined;'))
                else:
                    site.write_text(server.replace('access_log off;', f'access_log {raw} combined;'))
                with self.assertRaises(m['Fail']):
                    m['privacy_guard']()
                checked = subprocess.run(['nginx', '-t', '-p', tmp + '/', '-c', str(main)], capture_output=True)
                self.assertEqual(checked.returncode, 0, checked.stderr.decode())
                proc = subprocess.Popen(['nginx', '-p', tmp + '/', '-c', str(main), '-g', 'daemon off;'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            conn = socket.create_connection(('127.0.0.1', p), timeout=.2)
                            break
                        except OSError:
                            if time.monotonic() > deadline or proc.poll() is not None:
                                self.fail('attack nginx failed to start')
                    with conn:
                        conn.sendall(f'GET /?api_key={DUMMY} HTTP/1.1\r\nHost: privacy.example\r\nConnection: close\r\n\r\n'.encode())
                        while conn.recv(65536):
                            pass
                finally:
                    proc.terminate()
                    stdout, stderr = proc.communicate(timeout=5)
                logs = b'\n'.join(f.read_bytes() for f in root.rglob('*.log')) + stdout + stderr
                self.assertIn(DUMMY.encode(), logs, 'unguarded attack must really leak in nginx')

    def test_tokenizer_preserves_hash_and_normalizes_directive_names(self):
        m = runpy.run_path(str(SOURCE))
        nodes = m['nginx_statements']('"error_log" "/raw#path" info; #comment\n "in"clude "/x";')
        self.assertEqual(nodes, [(['error_log', '/raw#path', 'info'], None), (['include', '/x'], None)])
        self.assertEqual(m['nginx_statements'](r'"error\_log" /raw;')[0][0][0], r'error\_log')
        for invalid in ('include "unfinished', 'http {', 'error_log /raw', '}'):
            with self.assertRaises(m['Fail']):
                m['nginx_statements'](invalid)

    def test_generated_policy_rolls_back_on_test_and_reload_failure(self):
        for stage in ('test', 'reload'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory(prefix='ngx-privacy-rollback-') as tmp:
                old = os.environ.get('NGX_ROOT')
                os.environ['NGX_ROOT'] = tmp
                try:
                    m = runpy.run_path(str(SOURCE))
                finally:
                    if old is None:
                        os.environ.pop('NGX_ROOT', None)
                    else:
                        os.environ['NGX_ROOT'] = old
                root = Path(tmp)
                etc = root / 'etc/nginx'
                etc.mkdir(parents=True)
                (etc / 'nginx.conf').write_text(f'pid {root}/nginx.pid; error_log {root}/original-error.log warn; events {{}} http {{ access_log {root}/original-access.log combined; include {etc}/conf.d/*.conf; include {etc}/sites-enabled/*; }}')
                (etc / 'nginx.conf').chmod(0o640)
                m['config_set']('LOG_PRIVACY', 'standard')
                m['layout']()
                def snapshot():
                    return {str(p.relative_to(root)): ('link', os.readlink(p)) if p.is_symlink() else ('file', p.read_bytes(), p.stat().st_mode & 0o7777)
                            for p in map(Path, m['managed_paths']()) if p.is_file() or p.is_symlink()}
                before = snapshot()
                reached = []
                real_test = m['nginx_test']
                def test():
                    self.assertEqual(m['config_get']('LOG_PRIVACY'), 'queryless')
                    self.assertIn('ngx_queryless', (etc / 'sites-available/ngx-acme-80.conf').read_text())
                    real_test()  # Real nginx -t against generated temporary files.
                    reached.append('test')
                    if stage == 'test':
                        raise m['Fail']('synthetic post-generation test failure')
                def reload():
                    reached.append('reload')
                    raise m['Fail']('synthetic reload failure; no systemctl invoked')
                with patch.dict(m['cmd_privacy'].__globals__, {'YES': True, 'nginx_test': test, 'nginx_reload': reload}):
                    with self.assertRaises(m['Fail']):
                        m['cmd_privacy'](SimpleNamespace(policy='queryless'))
                self.assertEqual(reached, ['test'] if stage == 'test' else ['test', 'reload'])
                self.assertEqual(m['config_get']('LOG_PRIVACY'), 'standard')
                self.assertEqual(snapshot(), before, 'generated files, policy, modes and symlinks must roll back')

    def test_main_log_spans_preserve_other_configuration(self):
        m = runpy.run_path(str(SOURCE))
        original = ('# keep this exactly\nuser nginx;\n"error_"log /var/log/nginx/error.log warn; # tail\n'
                    'events { worker_connections 123; }\nhttp {\n  access_log /var/log/nginx/access.log;\n'
                    '  error_log /var/log/nginx/http-error.log error;\n  sendfile on; # untouched\n}\n')
        expected = original.replace('"error_"log /var/log/nginx/error.log warn;', 'error_log /dev/null;').replace(
            'access_log /var/log/nginx/access.log;', 'access_log off;').replace(
            'error_log /var/log/nginx/http-error.log error;', 'error_log /dev/null;')
        self.assertEqual(m['queryless_main_config'](original), expected)
        self.assertEqual(m['queryless_main_config'](expected), expected)
        for directive in ('access_log /tmp/log combined buffer=32k;', 'access_log /tmp/$host.log;',
                          'error_log syslog:server=127.0.0.1;', 'error_log /tmp/log $level;'):
            with self.subTest(directive=directive), self.assertRaises(m['Fail']):
                m['queryless_main_config']('events {} http {' + directive + '}')

    def test_cli_transaction_and_rollback(self):
        with tempfile.TemporaryDirectory(prefix='ngx-privacy-cli-') as tmp:
            root = Path(tmp)
            etc = root / 'etc/nginx'
            etc.mkdir(parents=True)
            main = etc / 'nginx.conf'
            main.write_text(f'pid {root}/nginx.pid; error_log {root}/error.log; '
                            f'events {{}} http {{ include {etc}/conf.d/*.conf; include {etc}/sites-enabled/*; }}')
            env = dict(os.environ, NGX_ROOT=tmp)
            def cli(*args):
                return subprocess.run(['python3', str(SOURCE), 'privacy', *args], env=env, capture_output=True, text=True)
            enabled = cli('queryless', '-y')
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertIn('queryless', cli().stdout)
            self.assertIn('error_log /dev/null;', main.read_text())
            disabled = cli('standard', '-y')
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            standard_main = main.read_text()
            unsupported_main = standard_main.replace('http {', 'http { access_log /tmp/$host.log;')
            main.write_text(unsupported_main)
            refused = cli('queryless', '-y')
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(main.read_text(), unsupported_main, 'unsupported main syntax must not be rewritten')
            self.assertEqual(cli().stdout.strip(), 'standard')
            main.write_text(standard_main)
            custom = root / 'etc/ngx/custom/fail.conf'
            custom.write_text('error_log /tmp/raw.log;')
            refused = cli('queryless', '-y')
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(cli().stdout.strip(), 'standard', 'failed change must roll back policy')


if __name__ == '__main__':
    unittest.main()
