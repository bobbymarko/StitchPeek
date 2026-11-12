"""Checks the Python EMB reference (Scripts/emb_reference.py, which StitchKit's Swift reader
mirrors) against an independent implementation, emb_inspect.py, on real EMB files.

    python3 Scripts/test_emb_reference.py            # or: python3 -m unittest Scripts/test_emb_reference.py

Needs `olefile` and the sample files, and skips cleanly without them. The samples are private
and never live in this repo:

    EMB_SAMPLES    glob of .EMB files, recursive "**" allowed (required, else the sample tests skip)
    EMB_INSPECT    path to emb_inspect.py, the independent reader to compare with (required)
    EMB_LIMIT      check at most this many files (default: all)

Failures name a file by a short hash, never by path, so a log can be shared.
"""
import glob
import hashlib
import importlib.util
import os
import sys
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import emb_reference as ref  # noqa: E402

def load_inspect():
    path = os.path.expanduser(os.environ.get("EMB_INSPECT", ""))
    if not path or not os.path.exists(path):
        return None
    try:
        import olefile  # noqa: F401
    except ImportError:
        return None
    spec = importlib.util.spec_from_file_location("emb_inspect", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def samples():
    pattern = os.path.expanduser(os.environ.get("EMB_SAMPLES", ""))
    patterns = [pattern] if pattern else []
    if pattern.lower().endswith(".emb"):
        patterns = [pattern[:-4] + ext for ext in (".EMB", ".emb")]      # both spellings occur
    files = sorted({f for p in patterns for f in glob.glob(p, recursive=True)})
    limit = int(os.environ.get("EMB_LIMIT", "0") or 0)
    return files[:limit] if limit else files


def tag(path):
    return hashlib.sha1(path.encode()).hexdigest()[:8]


class ReferenceAgainstInspect(unittest.TestCase):

    def setUp(self):
        self.inspect = load_inspect()
        if self.inspect is None:
            self.skipTest("olefile or emb_inspect.py not available")
        self.files = samples()
        if not self.files:
            self.skipTest("no sample EMB files (set EMB_SAMPLES)")

    def test_design_info_matches(self):
        for path in self.files:
            with self.subTest(file=tag(path)):
                info = self.inspect.design_info(path)
                _props, num, txt, _threads, _previews = ref.parse(path)
                self.assertEqual(round(num("number of stitches", 6)), info["number of stitches"])
                self.assertEqual(round(num("number of trims", 5)), info["number of trims"])
                self.assertEqual(round(num("number of colours", 3)), info["number of colours"])
                self.assertEqual(round(num("number of stops", 4)), info["number of stops"])
                self.assertEqual(round(num("number of colour changes", 27)), info["number of colour changes"])
                self.assertEqual(round(num("number of objects", 7)), info["number of objects"])
                self.assertEqual(num("design width", 17), info["design width"])
                self.assertEqual(num("design height", 16), info["design height"])
                self.assertEqual(txt("embroidery machine name", 19), info.get("embroidery machine name") or None)
                self.assertEqual(txt("source", 43), info.get("source") or None)

    def test_threads_match(self):
        for path in self.files:
            with self.subTest(file=tag(path)):
                expected = self.inspect.sequence(self.inspect.design_info(path))
                got = ref.parse(path)[3]
                self.assertEqual(len(got), len(expected))
                for g, e in zip(got, expected):
                    self.assertEqual((g["stop"], g["slot"], g["code"], g["name"], g["chart"], g["hex"]),
                                     (e["stop"], e["slot"], e["code"], e["name"], e["chart"], e["rgb"]))

    def test_previews_match(self):
        import olefile
        for path in self.files:
            with self.subTest(file=tag(path)):
                previews = ref.parse(path)[4]
                ole = olefile.OleFileIO(path)
                self.addCleanup(ole.close)
                for key, stream in (("bmp", "DESIGN_ICON"), ("jpeg", "TRUEVIEW_ICON")):
                    expected = zlib.decompress(ole.openstream(stream).read()[4:])
                    self.assertEqual(previews[key], expected)
                self.assertTrue(previews["bmp"].startswith(b"BM"))
                self.assertTrue(previews["jpeg"].startswith(b"\xff\xd8\xff"))

    def test_stream_set_matches(self):
        import olefile
        for path in self.files:
            with self.subTest(file=tag(path)):
                cfb = ref.CFBFile(ref.read_file(path))
                ole = olefile.OleFileIO(path)
                self.assertEqual(sorted(cfb.streams), sorted("/".join(e) for e in ole.listdir()))

    def test_encrypted_stream_is_never_read(self):
        """The reader must parse a file without ever asking for the DesignDocument stream."""
        asked = []
        original = ref.CFBFile.stream

        def spy(self, name):
            asked.append(name)
            return original(self, name)

        ref.CFBFile.stream = spy
        try:
            ref.parse(self.files[0])
        finally:
            ref.CFBFile.stream = original
        self.assertNotIn("DesignDocument", asked)
        self.assertEqual(sorted(asked), sorted([ref.DDD, "DESIGN_ICON", "TRUEVIEW_ICON"]))


class Robustness(unittest.TestCase):
    """No samples needed: damaged input must raise CFBError, never loop or crash."""

    def test_garbage(self):
        for data in (b"", b"x" * 100, ref.SIGNATURE + b"\0" * 504, b"\xff" * 4096):
            with self.assertRaises(Exception):
                ref.CFBFile(data)

    def test_truncated_real_file(self):
        files = samples()
        if not files:
            self.skipTest("no sample EMB files")
        data = ref.read_file(files[0])
        for cut in (600, 1024, len(data) // 2):
            try:
                cfb = ref.CFBFile(data[:cut])
                cfb.stream(ref.DDD)
            except ref.CFBError:
                pass


if __name__ == "__main__":
    unittest.main()
