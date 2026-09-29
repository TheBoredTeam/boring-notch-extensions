from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import catalog
from check_catalog_update import enforce_explicit_update
from test_catalog import listing, toml_dump


class ExplicitAggregateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repository = Path(temporary.name)
        self.source = self.repository / "extensions"
        self.source.mkdir()
        self.record = self.source / "org.example.focus.toml"
        self.record.write_text(toml_dump(listing()))
        self.aggregate = self.repository / "catalog.json"
        self.aggregate.write_bytes(catalog.generate(self.source))
        self.git("init", "-q")
        self.commit()
        self.base = self.git("rev-parse", "HEAD")

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.repository,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self):
        self.git("add", "--all")
        self.git("-c", "user.name=Catalog Test", "-c", "user.email=catalog@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture")

    def test_source_only_update_can_defer_aggregate_to_main(self):
        self.record.write_text(toml_dump(listing() | {"name": "Updated source"}))
        self.commit()
        self.assertFalse(enforce_explicit_update(self.repository, self.base))

    def test_explicit_unrelated_payload_cannot_bypass_toml_validation(self):
        self.aggregate.write_text('{"schemaVersion": 1, "extensions": []}\n')
        self.commit()
        with self.assertRaisesRegex(catalog.CatalogError, "explicitly changed"):
            enforce_explicit_update(self.repository, self.base)

    def test_explicit_aggregate_matching_source_passes(self):
        self.record.write_text(toml_dump(listing() | {"name": "Updated source"}))
        self.aggregate.write_bytes(catalog.generate(self.source))
        self.commit()
        self.assertTrue(enforce_explicit_update(self.repository, self.base))

    def test_deleted_aggregate_is_not_a_source_only_update(self):
        self.aggregate.unlink()
        self.commit()
        with self.assertRaisesRegex(catalog.CatalogError, "regular file"):
            enforce_explicit_update(self.repository, self.base)

    def test_initial_push_checks_aggregate_and_bad_event_base_fails(self):
        self.assertTrue(enforce_explicit_update(self.repository, "0" * 40))
        for base in ["HEAD", "--name-only", "a" * 40]:
            with self.subTest(base=base), self.assertRaises(catalog.CatalogError):
                enforce_explicit_update(self.repository, base)


if __name__ == "__main__":
    unittest.main()
