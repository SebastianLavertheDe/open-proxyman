#!/usr/bin/env python3
"""Check runtime signature failures and the real Security API on macOS."""
import ctypes
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from test_app_bundle import verify_runtime_signature


class SignatureFailureChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pm-signature-api-")
        self.addCleanup(self.temporary.cleanup)
        self.binary = Path(self.temporary.name) / "Fixture"
        self.binary.write_bytes(b"fixture")
        self.security = Mock()
        self.foundation = Mock()
        self.foundation.CFURLCreateFromFileSystemRepresentation.return_value = 1
        self.security.SecStaticCodeCreateWithPath.side_effect = self.create_code
        self.security.SecStaticCodeCheckValidity.return_value = 0
        self.libraries = patch("test_app_bundle.ctypes.CDLL", side_effect=[self.security, self.foundation])
        self.libraries.start()
        self.addCleanup(self.libraries.stop)

    @staticmethod
    def create_code(_url, _flags, output):
        ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = 2
        return 0

    def test_default_flags_match_the_running_application(self):
        verify_runtime_signature(self.binary)
        code, flags, requirement = self.security.SecStaticCodeCheckValidity.call_args.args
        self.assertEqual((code.value, flags, requirement), (2, 0, None))
        self.assertEqual(self.foundation.CFRelease.call_count, 2)

    def test_invalid_resource_signature_is_rejected(self):
        self.security.SecStaticCodeCheckValidity.return_value = -67030
        with self.assertRaisesRegex(ValueError, "OSStatus -67030"):
            verify_runtime_signature(self.binary)
        self.assertEqual(self.foundation.CFRelease.call_count, 2)

    def test_code_creation_failure_does_not_reach_validation(self):
        self.security.SecStaticCodeCreateWithPath.side_effect = None
        self.security.SecStaticCodeCreateWithPath.return_value = -50
        with self.assertRaisesRegex(ValueError, "OSStatus -50"):
            verify_runtime_signature(self.binary)
        self.security.SecStaticCodeCheckValidity.assert_not_called()
        self.foundation.CFRelease.assert_called_once_with(1)


@unittest.skipUnless(sys.platform == "darwin", "Native Security.framework requires macOS")
class NativeSignatureChecks(unittest.TestCase):
    def test_modified_signed_resource_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="pm-native-signature-") as temporary:
            app = Path(temporary) / "Fixture.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources").mkdir()
            shutil.copyfile("/usr/bin/true", contents / "MacOS/Fixture")
            (contents / "MacOS/Fixture").chmod(0o755)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "test.ProxyMirror.Signature",
                "CFBundlePackageType": "APPL",
            }))
            license_file = contents / "Resources/Fixture-LICENSE"
            license_file.write_text("Original signed license", encoding="utf-8")
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", app], check=True, capture_output=True)
            verify_runtime_signature(app)
            license_file.write_text("Changed after signing", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Runtime signature validation failed"):
                verify_runtime_signature(app)


if __name__ == "__main__":
    unittest.main()
