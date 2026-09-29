import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import catalog
import validate_registry
from test_catalog import artifact, legacy_pack, listing, toml_dump


class Response(io.BytesIO):
    status = 200

    def __init__(self, data=b"legacy release", url="https://example.org/Legacy.zip", headers=None):
        super().__init__(data)
        self.url = url
        self.headers = headers or {}

    def geturl(self):
        return self.url


class RegistryValidationTests(unittest.TestCase):
    def test_legacy_hash_and_reachability_gate_is_retained(self):
        pack = legacy_pack()
        pack["release"]["sha256"] = hashlib.sha256(b"legacy release").hexdigest()
        fetch = mock.Mock(side_effect=lambda *args, **kwargs: Response())
        validate_registry.check_legacy_artifact(pack, opener=fetch)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(fetch.call_args_list[0].args[0].get_method(), "HEAD")
        pack["release"]["sha256"] = "a" * 64
        with self.assertRaisesRegex(catalog.CatalogError, "sha256 mismatch"):
            validate_registry.check_legacy_artifact(pack, opener=fetch)

    def test_legacy_download_rejects_unsafe_redirects_and_oversized_body(self):
        with self.assertRaisesRegex(catalog.CatalogError, "unsafe URL"):
            validate_registry.check_legacy_artifact(legacy_pack(), opener=lambda *a, **k: Response(url="http://example.org"))
        with self.assertRaisesRegex(catalog.CatalogError, "archive limit"):
            validate_registry.check_legacy_artifact(legacy_pack(), opener=lambda *a, **k: Response(headers={"Content-Length": str(2**32)}))
        with mock.patch.object(validate_registry, "MAX_LEGACY_ARCHIVE_BYTES", 5):
            with self.assertRaisesRegex(catalog.CatalogError, "archive limit"):
                validate_registry.check_legacy_artifact(legacy_pack(), opener=lambda *a, **k: Response())

    def test_native_records_do_not_enter_legacy_download_or_update_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = listing() | {"status": "available", "artifact": artifact(), "update": {"strategy": "github-release"}}
            root.joinpath(native["id"] + ".toml").write_text(toml_dump(native))
            pack = legacy_pack()
            root.joinpath(pack["id"] + ".toml").write_text(toml_dump(pack))
            with mock.patch.object(validate_registry, "check_legacy_artifact") as check:
                self.assertEqual(validate_registry.validate_registry(root, check_artifacts=True), (1, 1))
                check.assert_called_once_with(pack)
            self.assertEqual(catalog.record_kind(native, native["id"] + ".toml"), "native")


if __name__ == "__main__":
    unittest.main()
