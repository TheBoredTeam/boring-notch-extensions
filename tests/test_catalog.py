import importlib.util
from pathlib import Path
import json
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("catalog", Path(__file__).resolve().parents[1] / "scripts/catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{key} = {toml_value(item)}" for key, item in value.items()) + " }"
    raise TypeError(value)


def toml_dump(item):
    return "".join(f"{key} = {toml_value(value)}\n" for key, value in item.items())


def legacy_pack():
    return {"id": "org.example.Legacy", "name": "Legacy", "version": "1.0.0", "publisher": "Example",
            "repository": "https://github.com/example/legacy",
            "release": {"url": "https://example.org/Legacy.zip", "sha256": "a" * 64},
            "extensions": [{"bundleID": "org.example.Legacy.Extension", "scenes": ["notch.ui"]}],
            "update": {"strategy": "github-release"}}


def listing(identifier="org.example.focus", slug="focus"):
    return {
        "schemaVersion": 1, "id": identifier, "slug": slug, "name": "Focus",
        "tagline": "A test fixture", "description": "Metadata validation fixture, not a distributed product.",
        "developer": {"name": "Example", "url": "https://example.org"},
        "categories": ["Productivity"], "price": {"amount": 0, "currency": "USD", "billing": "free"},
        "status": "preview", "version": "1.0.0", "requirements": ["macOS 14 or later"],
        "sourceUrl": "https://example.org/source", "supportUrl": "https://example.org/support"
    }


def artifact():
    return {"downloadURL": "https://example.org/focus-1.0.0.zip", "sha256": "a" * 64,
            "publisherTeamID": "ABCDE12345", "version": "1.0.0", "apiVersion": 1}


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def write(self, item, name=None):
        path = self.directory / (name or item["id"] + ".toml")
        path.write_text(toml_dump(item))
        return path

    def test_deterministic_full_records_sort_by_id_without_source_version(self):
        self.write(listing("org.zulu.focus", "zulu"))
        self.write(listing("org.alpha.focus", "alpha"))
        first = catalog.generate(self.directory)
        second = catalog.generate(self.directory)
        self.assertEqual(first, second)
        result = json.loads(first)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual([item["id"] for item in result["extensions"]], ["org.alpha.focus", "org.zulu.focus"])
        self.assertNotIn("schemaVersion", result["extensions"][0])
        self.assertEqual(result["extensions"][0]["developer"]["name"], "Example")

    def test_empty_catalog_is_valid_and_legacy_packs_do_not_leak(self):
        self.assertEqual(json.loads(catalog.generate(self.directory))["extensions"], [])
        pack = legacy_pack()
        path = self.write(pack)
        before = path.read_bytes()
        self.write(listing())
        result = json.loads(catalog.generate(self.directory))
        self.assertEqual([item["id"] for item in result["extensions"]], [listing()["id"]])
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(catalog.record_kind(pack, path.name), "legacy")

    def test_canonical_artifact_and_matching_legacy_alias_normalize(self):
        item = listing()
        item["status"] = "available"
        item["artifact"] = artifact()
        item["artifact"]["url"] = item["artifact"]["downloadURL"]
        item["artifact"]["sha256"] = "A" * 64
        self.write(item)
        release = json.loads(catalog.generate(self.directory))["extensions"][0]["artifact"]
        self.assertNotIn("url", release)
        self.assertEqual(release["downloadURL"], artifact()["downloadURL"])
        self.assertEqual(release["sha256"], "a" * 64)
        legacy = artifact()
        legacy["url"] = legacy.pop("downloadURL")
        self.assertEqual(catalog.validate_artifact(legacy, "1.0.0")["downloadURL"], artifact()["downloadURL"])

    def test_available_without_actual_artifact_is_rejected(self):
        item = listing()
        item["status"] = "available"
        self.write(item)
        with self.assertRaisesRegex(catalog.CatalogError, "reviewed artifact"):
            catalog.generate(self.directory)

    def test_invalid_release_identity_hash_version_and_url_are_rejected(self):
        invalid = [
            {"sha256": ""}, {"publisherTeamID": "development"}, {"version": "2.0.0"}, {"apiVersion": 2},
            {"downloadURL": "http://example.org/focus.zip"},
            {"downloadURL": "https://user:secret@example.org/focus.zip"},
            {"downloadURL": "https://example.org/checkout"},
            {"downloadURL": "https://example.org:abc/plugin.zip"},
            {"downloadURL": "https://[::1]:abc/plugin.zip"},
            {"downloadURL": "https://example.org:65536/plugin.zip"},
            {"downloadURL": "https://exa\\mple.org/plugin.zip"},
            {"url": "https://example.org/other.zip"}
        ]
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(catalog.CatalogError):
                catalog.validate_artifact(artifact() | changes, "1.0.0")

    def test_filename_and_unique_slug_are_enforced(self):
        wrong = self.write(listing(), "wrong.toml")
        with self.assertRaisesRegex(catalog.CatalogError, "filename"):
            catalog.generate(self.directory)
        wrong.unlink()
        self.write(listing())
        self.write(listing("org.other.focus"))
        with self.assertRaisesRegex(catalog.CatalogError, "duplicate extension slug"):
            catalog.generate(self.directory)

    def test_full_toml_rejects_duplicate_keys_tables_and_invalid_syntax(self):
        invalid = [
            'id = "first"\nid = "second"\n',
            '[developer]\nname = "First"\n[developer]\nname = "Second"\n',
            'developer.name = "First"\n[developer]\nname = "Second"\n',
            'name = "unterminated\n', 'categories = ["One"\n',
            'name = "bad\\q"\n', '[broken\n',
        ]
        for document in invalid:
            with self.subTest(document=document):
                path = self.directory / "broken.toml"
                path.write_text(document)
                with self.assertRaisesRegex(catalog.CatalogError, "invalid source TOML"):
                    catalog.read_record(path)
        path.write_bytes(b"id = \"\xff\"\n")
        with self.assertRaisesRegex(catalog.CatalogError, "invalid source TOML"):
            catalog.read_record(path)

    def test_links_and_nested_files_are_rejected(self):
        original = self.write(listing())
        link = self.directory / "org.example.link.toml"
        link.symlink_to(original)
        with self.assertRaisesRegex(catalog.CatalogError, "not a link"):
            catalog.read_source(link)
        link.unlink()
        nested = self.directory / "nested"
        nested.mkdir()
        original.rename(nested / original.name)
        with self.assertRaisesRegex(catalog.CatalogError, "directly"):
            catalog.generate(self.directory)

    def test_source_and_item_count_limits(self):
        path = self.directory / "oversized.toml"
        path.write_bytes(b" " * (catalog.MAX_SOURCE_BYTES + 1))
        with self.assertRaisesRegex(catalog.CatalogError, "64 KiB"):
            catalog.read_source(path)
        path.unlink()
        for number in range(catalog.MAX_ITEMS + 1):
            (self.directory / f"org.example.p{number}.toml").touch()
        with self.assertRaisesRegex(catalog.CatalogError, "500"):
            catalog.generate(self.directory)

    def test_aggregate_limit_is_checked_before_publication(self):
        for number in range(125):
            item = listing(f"org.example.p{number}", f"p{number}")
            item["description"] = "x" * 16_384
            self.write(item)
        with self.assertRaisesRegex(catalog.CatalogError, "2 MB"):
            catalog.generate(self.directory)

    def test_https_assets_and_legacy_assets_are_supported_without_unsafe_paths(self):
        for value in ["https://raw.githubusercontent.com/owner/repo/main/icon.png", "assets/extensions/focus.svg"]:
            self.assertTrue(catalog.asset(value))
        for value in ["http://example.org/icon.png", "assets/extensions/../secret.png", "assets/extensions//icon.png",
                      "assets/extensions/icon.png?secret=1", "https://user:pass@example.org/icon.png"]:
            self.assertFalse(catalog.asset(value))

    def test_type_price_and_schema_rules(self):
        invalid = [
            {"schemaVersion": True}, {"schemaVersion": 2}, {"id": "org.Example.Focus"}, {"name": ""},
            {"status": []}, {"price": {"amount": True, "currency": "USD", "billing": "free"}},
            {"price": {"amount": 1, "currency": "USD", "billing": "free"}},
            {"price": {"amount": float("nan"), "currency": "USD", "billing": "one-time"}},
            {"price": {"amount": 1, "currency": "USD", "billing": []}}
        ]
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(catalog.CatalogError):
                catalog.validate_item(listing() | changes, "org.example.focus.toml")

    def test_optional_publisher_product_fields_survive_generation(self):
        item = listing()
        item.update({"websiteUrl": "https://example.org/focus", "purchaseUrl": "https://example.org/buy", "privacy": "Publisher-owned terms.",
                     "features": [{"title": "One", "description": "Two"}], "featured": True})
        self.write(item)
        result = json.loads(catalog.generate(self.directory))["extensions"][0]
        self.assertEqual(result["websiteUrl"], item["websiteUrl"])
        self.assertEqual(result["purchaseUrl"], item["purchaseUrl"])
        self.assertEqual(result["features"], item["features"])
        self.assertTrue(result["featured"])

    def test_optional_product_website_requires_safe_https(self):
        for url in ["http://example.org/focus", "https://user:secret@example.org/focus",
                    "https://example.org:abc/focus", "https://exa\\mple.org/focus"]:
            with self.subTest(url=url), self.assertRaisesRegex(catalog.CatalogError, "websiteUrl"):
                catalog.validate_item(listing() | {"websiteUrl": url}, "org.example.focus.toml")

    def test_full_toml_tables_arrays_multiline_and_quoted_keys_survive(self):
        item = listing()
        item.pop("developer")
        item.pop("price")
        path = self.write(item)
        with path.open("a") as stream:
            stream.write('''
[developer]
name = 'Example # "Studio"' # this comment is not part of the name
url = "https://example.org"
[price]
amount = 0.0
currency = "USD"
billing = "free"
[[features]]
title = """A multiline
title"""
description = ''' + "'''Literal \\\\ and # stay literal'''" + '''
[[features]]
title = "Second"
description = "A second entry"
[[previews]]
image = "https://example.org/preview.png"
caption = "Preview"
[extra."quoted.key"]
count = 1_000
flags = [true, false,]
''')
        result = json.loads(catalog.generate(self.directory))["extensions"][0]
        self.assertEqual(result["developer"]["name"], 'Example # "Studio"')
        self.assertEqual(result["features"][0]["title"], "A multiline\ntitle")
        self.assertIn("# stay literal", result["features"][0]["description"])
        self.assertEqual(len(result["features"]), 2)
        self.assertEqual(result["previews"][0]["caption"], "Preview")
        self.assertEqual(result["extra"]["quoted.key"], {"count": 1000, "flags": [True, False]})

    def test_unsupported_or_missing_native_schema_never_silently_skips(self):
        for version in [True, 0, 2, "1"]:
            with self.subTest(version=version):
                self.write(listing() | {"schemaVersion": version})
                with self.assertRaisesRegex(catalog.CatalogError, "schemaVersion"):
                    catalog.generate(self.directory)
        native = listing()
        del native["schemaVersion"]
        self.write(native)
        with self.assertRaisesRegex(catalog.CatalogError, "native records require schemaVersion"):
            catalog.generate(self.directory)
        self.write({"id": "org.example.focus"})
        with self.assertRaisesRegex(catalog.CatalogError, "unrecognized record"):
            catalog.generate(self.directory)
        for version in [1, 2]:
            with self.subTest(legacy_version=version), self.assertRaises(catalog.CatalogError):
                catalog.record_kind(legacy_pack() | {"schemaVersion": version}, "org.example.Legacy.toml")

    def test_legacy_shape_must_be_complete_and_cannot_mix_native_artifacts(self):
        invalid = [
            {"release": {}}, {"extensions": []}, {"extensions": [{"bundleID": "Example", "scenes": "notch.ui"}]},
            {"release": {"url": "https://example.org/Legacy.zip", "sha256": ""}},
            {"repository": "http://example.org"}, {"artifact": artifact()},
        ]
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(catalog.CatalogError):
                catalog.record_kind(legacy_pack() | changes, "org.example.Legacy.toml")

    def test_dates_times_and_nonfinite_values_cannot_leak_through_extra_metadata(self):
        for literal in ["1979-05-27", "07:32:00", "1979-05-27T07:32:00Z", "nan", "+nan", "inf", "-inf"]:
            with self.subTest(literal=literal):
                path = self.write(listing())
                with path.open("a") as stream:
                    stream.write(f"[extra]\nvalues = [{{ value = {literal} }}]\n")
                with self.assertRaisesRegex(catalog.CatalogError, "unsupported TOML value|nonfinite"):
                    catalog.generate(self.directory)

    def test_metadata_depth_is_bounded(self):
        path = self.write(listing())
        with path.open("a") as stream:
            stream.write("[" + ".".join(["extra"] * (catalog.MAX_METADATA_DEPTH + 1)) + "]\nvalue = 1\n")
        with self.assertRaisesRegex(catalog.CatalogError, "nesting levels"):
            catalog.generate(self.directory)

    def test_symlink_directories_cannot_hide_or_redirect_sources(self):
        self.write(listing())
        link = self.directory / "linked"
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(catalog.CatalogError, "not a link"):
            catalog.generate(self.directory)
        with self.assertRaisesRegex(catalog.CatalogError, "must not be a link"):
            catalog.generate(link)

    def test_urls_use_foundation_compatible_hosts_and_percent_escapes(self):
        invalid = [
            "https://%/", "https://host%zz/", "https://foo|bar/", "https://foo<bar/", "https://foo^bar/",
            "https://\u0085example.org/", "https://example.org/\u200bhidden", "https://exa_mple.org/",
            "https://-example.org/", "https://example-.org/", "https://example..org/",
            "https://example.org/%", "https://example.org/%2G", "https://example.org:0/",
            "https://%65xample.org/", "https://256.1.1.1/", "https://[fe80::1%25en0]/",
            "https://" + "a" * 64 + ".org/", "https://\ud800example.org/",
        ]
        for url in invalid:
            with self.subTest(url=repr(url)):
                self.assertFalse(catalog.https(url))
        for url in ["https://example.org", "https://sub.example.org.:443/a%20b?c=d%23e",
                    "https://bücher.example/focus.zip", "https://xn--bcher-kva.example/",
                    "https://[2001:db8::1]:8443/", "https://192.0.2.1/"]:
            with self.subTest(url=url):
                self.assertTrue(catalog.https(url))

    def test_all_integer_metadata_stays_in_signed_64_bit_range(self):
        for value in [-(2**63), 2**63 - 1]:
            self.write(listing() | {"extra": {"integer": value}})
            actual = json.loads(catalog.generate(self.directory))["extensions"][0]["extra"]["integer"]
            self.assertEqual(actual, value)
        for value in [-(2**63) - 1, 2**63]:
            self.write(listing() | {"extra": {"integer": value}})
            with self.subTest(value=value), self.assertRaisesRegex(catalog.CatalogError, "signed 64-bit"):
                catalog.generate(self.directory)
        path = self.write(listing())
        with path.open("a") as stream:
            stream.write("[extra]\ninteger = " + "9" * 5000 + "\n")
        # Python may cap int conversion first; runtimes with that cap disabled
        # reach the shared signed-64-bit check. Both must fail as CatalogError.
        with self.assertRaisesRegex(catalog.CatalogError, "invalid source TOML|signed 64-bit"):
            catalog.generate(self.directory)


if __name__ == "__main__":
    unittest.main()
