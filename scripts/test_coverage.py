"""Check report filtering and weighted totals without Swift or LLVM."""
import unittest

from coverage import check_coverage, core_files, summary


def file(path, covered, count):
    metric = {"covered": covered, "count": count, "percent": covered / count * 100}
    return {"filename": path, "summary": dict.fromkeys(("lines", "functions", "regions"), metric)}


class CoverageTests(unittest.TestCase):
    def test_excludes_tests_and_app_and_weights_by_executable_lines(self):
        report = {"data": [{"files": [
            file("/repo/Sources/UllageCore/A.swift", 1, 1),
            file("/repo/Sources/UllageCore/Harnesses/B.swift", 7, 9),
            file("/repo/Tests/Tests.swift", 100, 100),
            file("/repo/Sources/UllageApp/App.swift", 0, 100),
        ]}]}
        files = core_files(report)
        self.assertEqual(len(files), 2)
        self.assertIn("| Lines | 8 | 10 | 80.00% |", summary(files))
        self.assertIn("`Harnesses/B.swift`", summary(files))

    def test_missing_core_coverage_fails(self):
        with self.assertRaises(ValueError):
            core_files({"data": [{"files": [file("/repo/Tests/Test.swift", 1, 1)]}]})

    def test_line_coverage_floor(self):
        check_coverage([file("/repo/Sources/UllageCore/A.swift", 85, 100)])
        with self.assertRaises(ValueError):
            check_coverage([file("/repo/Sources/UllageCore/A.swift", 84, 100)])


if __name__ == "__main__":
    unittest.main()
