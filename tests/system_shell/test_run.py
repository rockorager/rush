import tempfile
import unittest
from pathlib import Path

from run import read_statuses


class StatusTests(unittest.TestCase):
    def check_statuses(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.tsv"
            if text is not None:
                path.write_text(text)
            return read_statuses(path)

    def test_completed_success(self):
        stages, errors = self.check_statuses("stage\tstatus\tseconds\nmake\t0\t1\nshell-target\t0\t0\n")
        self.assertFalse(errors)
        self.assertEqual(stages["make"]["seconds"], "1")

    def test_missing_empty_and_incomplete_are_not_success(self):
        for text in (None, "stage\tstatus\tseconds\n", "stage\tstatus\tseconds\nmake\t0\t1\n"):
            with self.subTest(text=text):
                self.assertTrue(self.check_statuses(text)[1])

    def test_failure_timeout_and_skip_are_not_success(self):
        for status in (1, 124, 125, 137):
            with self.subTest(status=status):
                text = f"stage\tstatus\tseconds\ncheck\t{status}\t1\nshell-target\t0\t0\n"
                self.assertIn(f"check exited {status}", self.check_statuses(text)[1])

    def test_duplicate_and_invalid_statuses_are_rejected(self):
        text = "stage\tstatus\tseconds\nshell-target\tbad\t0\nshell-target\t0\t0\n"
        self.assertEqual(len(self.check_statuses(text)[1]), 2)


if __name__ == "__main__":
    unittest.main()
