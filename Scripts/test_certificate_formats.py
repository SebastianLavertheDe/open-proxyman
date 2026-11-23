#!/usr/bin/env python3
"""Reproduce the certificate helper's OpenSSL protocol and private-file checks.

Runs on Linux or macOS with Python 3 and OpenSSL/LibreSSL. This verifies actual
PKCS#12 and encrypted PKCS#8 files, not the Swift runtime, Security framework,
certificate importer UI, or macOS trust installation. Swift-side purpose/SAN and
storage checks live in Tests/ProxyMirrorCoreChecks/CertificateFormatChecks.swift.

    python3 Scripts/test_certificate_formats.py
    python3 Scripts/test_certificate_formats.py --openssl /usr/bin/openssl
"""

import argparse
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import uuid


OPENSSL = "/usr/bin/openssl"


class CertificateConversionProtocolChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-cert-protocol-")
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        self.password = "fixture-'$-密钥-123"
        self.password_key = "PM_CERT_PASSWORD_" + uuid.uuid4().hex.upper()
        self.calls = []
        self.key = self.private_file("key.pem")
        self.certificate = self.private_file("cert.pem")
        self.run_openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.key)])
        self.run_openssl(["req", "-new", "-x509", "-key", str(self.key), "-out", str(self.certificate),
                          "-days", "1", "-subj", "/CN=ProxyMirror Conversion Fixture"])

    def tearDown(self):
        directory = self.directory
        self.temporary.cleanup()
        self.assertFalse(directory.exists(), "temporary certificate material must be removed")

    def private_file(self, filename):
        path = self.directory / filename
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        return path

    def run_openssl(self, arguments, *, password_option=None, password=None, succeeds=True, public_output=False):
        argv = [OPENSSL] + list(arguments)
        environment = {"PATH": "/usr/bin:/bin", "LANG": "C"}
        if password_option:
            secret = self.password if password is None else password
            environment[self.password_key] = secret
            argv += [password_option, "env:" + self.password_key]
            self.assertTrue(all(secret not in argument for argument in argv) if secret else True,
                            "password values must never be command-line arguments")
        self.calls.append(tuple(argv))
        result = subprocess.run(argv, env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE if public_output else subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        # Avoid including stdout, stderr, file contents, or passwords in failure reports.
        self.assertEqual(result.returncode == 0, succeeds,
                         "unexpected OpenSSL result for " + arguments[0])
        return result.stdout if public_output else None

    def export_p12(self):
        destination = self.private_file("identity.p12")
        self.run_openssl(["pkcs12", "-export", "-in", str(self.certificate), "-inkey", str(self.key),
                          "-name", "ProxyMirror CA", "-out", str(destination)], password_option="-passout")
        return destination

    def public_key(self, path, *, encrypted=False):
        return self.run_openssl(["pkey", "-in", str(path), "-pubout", "-outform", "DER"],
                                password_option="-passin" if encrypted else None, public_output=True)

    def test_p12_roundtrip_extracts_certificate_and_matching_key(self):
        identity = self.export_p12()
        certificates = self.private_file("certificates.pem")
        keys = self.private_file("keys.pem")
        normalized = self.private_file("normalized-key.pem")
        self.run_openssl(["pkcs12", "-in", str(identity), "-nokeys", "-out", str(certificates)],
                          password_option="-passin")
        self.run_openssl(["pkcs12", "-in", str(identity), "-nocerts", "-nodes", "-out", str(keys)],
                          password_option="-passin")
        self.run_openssl(["pkey", "-in", str(keys), "-out", str(normalized)],
                          password_option="-passin", password="")
        original = self.run_openssl(["x509", "-in", str(self.certificate), "-outform", "DER"], public_output=True)
        extracted = self.run_openssl(["x509", "-in", str(certificates), "-outform", "DER"], public_output=True)
        self.assertEqual(original, extracted, "P12 must retain the exact certificate DER")
        self.assertEqual(self.public_key(self.key), self.public_key(normalized),
                         "P12 must retain the same private-key identity")

    def test_encrypted_pkcs8_accepts_unicode_and_shell_characters_in_password(self):
        encrypted = self.private_file("encrypted-key.pem")
        self.run_openssl(["pkey", "-in", str(self.key), "-aes-256-cbc", "-out", str(encrypted)],
                          password_option="-passout")
        self.assertTrue(encrypted.read_bytes().startswith(b"-----BEGIN ENCRYPTED PRIVATE KEY-----"))
        self.assertEqual(self.public_key(self.key), self.public_key(encrypted, encrypted=True))

    def test_incorrect_passwords_are_rejected(self):
        identity = self.export_p12()
        self.run_openssl(["pkcs12", "-in", str(identity), "-noout"], password_option="-passin",
                          password="incorrect", succeeds=False)
        encrypted = self.private_file("encrypted-key.pem")
        self.run_openssl(["pkey", "-in", str(self.key), "-aes-256-cbc", "-out", str(encrypted)],
                          password_option="-passout")
        self.run_openssl(["pkey", "-in", str(encrypted), "-noout"], password_option="-passin",
                          password="incorrect", succeeds=False)

    def test_existing_private_output_modes_are_preserved_by_helpers(self):
        self.export_p12()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for path in self.directory.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600,
                             "certificate helper outputs must remain private")
        self.assertTrue(all(self.password not in argument for call in self.calls for argument in call))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", default=OPENSSL, help="OpenSSL/LibreSSL executable (default /usr/bin/openssl)")
    options, remaining = parser.parse_known_args()
    OPENSSL = str(Path(shutil.which(options.openssl) or options.openssl).resolve())
    if not os.access(OPENSSL, os.X_OK):
        parser.error("OpenSSL executable is not available")
    print("Checking OpenSSL conversion protocol and private file permissions; Swift/macOS UI is not executed.", flush=True)
    unittest.main(argv=[__file__] + remaining)
