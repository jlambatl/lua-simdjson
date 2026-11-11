#!/usr/bin/env python3
"""Test suite for run_encode_diagnostics runner - RED/GREEN TDD."""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class TestRunEncodeDiagnostics(unittest.TestCase):
    """RED/GREEN TDD tests for Windows process-evidence pipeline."""

    def setUp(self):
        """Create temporary directories for test execution."""
        self.test_dir = tempfile.TemporaryDirectory()
        self.output_dir = Path(self.test_dir.name) / "output"
        self.output_dir.mkdir(exist_ok=True)
        self.module_dir = Path(self.test_dir.name) / "module"
        self.module_dir.mkdir(exist_ok=True)
        self.runner_path = Path(__file__).parent / "run_encode_diagnostics.py"

    def tearDown(self):
        """Clean up temporary directories."""
        self.test_dir.cleanup()

    def _create_probe_script(self):
        """Create a minimal probe script that outputs PASS for a case."""
        probe = self.module_dir / "tmp_rovo_probe.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "case = sys.argv[1]\n"
            "module_dir = sys.argv[2]\n"
            "print(f'PASS {case}')\n"
            "sys.exit(0)\n"
        )
        probe.chmod(0o755)
        return probe

    def test_success_requires_zero_exit_and_pass_marker(self):
        """RED: Runner must exit 0 and detect PASS marker in probe output."""
        # Verify runner exists
        self.assertTrue(
            self.runner_path.exists(),
            f"Runner not found at {self.runner_path}"
        )

        # Create minimal probe script
        probe = self._create_probe_script()

        # Create fake module file (platform-specific name)
        import platform
        if platform.system() == "Windows":
            module_file = self.module_dir / "simdjson.dll"
        else:
            module_file = self.module_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner with single case
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir),
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Verify exit code is 0
        self.assertEqual(result.returncode, 0,
                        f"Expected exit 0, got {result.returncode}\n"
                        f"stdout: {result.stdout}\nstderr: {result.stderr}")

        # Verify results.json exists
        results_file = self.output_dir / "results.json"
        self.assertTrue(results_file.exists(),
                       f"results.json not created at {results_file}")

        # Verify PASS marker detected
        with open(results_file) as f:
            results = json.load(f)
        self.assertIn("cases", results)
        self.assertIn("nan", results["cases"])
        self.assertTrue(results["cases"]["nan"]["pass"],
                       "PASS marker not detected for nan case")


    def test_nonzero_child_is_failure(self):
        """GREEN: Nonzero exit code means failure even with PASS marker."""
        # Create probe that outputs PASS but exits nonzero
        probe = self.module_dir / "tmp_rovo_probe_fail.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "case = sys.argv[1]\n"
            "print(f'PASS {case}')\n"
            "sys.exit(42)\n"
        )
        probe.chmod(0o755)

        # Create fake module file
        import platform
        if platform.system() == "Windows":
            module_file = self.module_dir / "simdjson.dll"
        else:
            module_file = self.module_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir),
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Runner should exit non-zero
        self.assertNotEqual(result.returncode, 0,
                           f"Expected non-zero exit for child failure")

        # Verify results show failure
        results_file = self.output_dir / "results.json"
        with open(results_file) as f:
            results = json.load(f)
        self.assertFalse(results["cases"]["nan"]["pass"],
                        "Should detect failure despite PASS text")

    def test_timeout_is_failure_and_preserves_output(self):
        """GREEN: Timeout should fail and preserve partial output."""
        # Create probe that hangs
        probe = self.module_dir / "tmp_rovo_probe_timeout.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "case = sys.argv[1]\n"
            "print('Starting probe...', flush=True)\n"
            "time.sleep(10)\n"
            "print(f'PASS {case}')\n"
        )
        probe.chmod(0o755)

        # Create fake module file
        import platform
        if platform.system() == "Windows":
            module_file = self.module_dir / "simdjson.dll"
        else:
            module_file = self.module_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner with short timeout
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir),
             "--timeout-seconds", "1",
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Runner should exit non-zero
        self.assertNotEqual(result.returncode, 0,
                           f"Expected non-zero exit on timeout")

        # Verify results show timeout
        results_file = self.output_dir / "results.json"
        with open(results_file) as f:
            results = json.load(f)
        self.assertTrue(results["cases"]["nan"]["timeout"],
                       "Should record timeout")
        self.assertFalse(results["cases"]["nan"]["pass"],
                        "Timeout should fail")
        self.assertIn("Starting probe", results["cases"]["nan"]["stdout"],
                     "Should preserve partial output")

    def test_all_eight_cases_run_independently(self):
        """GREEN: All 8 cases run independently even if some fail."""
        # Create probe that fails on specific case
        probe = self.module_dir / "tmp_rovo_probe_selective.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "case = sys.argv[1]\n"
            "if case == 'repeat-nan':\n"
            "    sys.exit(1)\n"
            "print(f'PASS {case}')\n"
        )
        probe.chmod(0o755)

        # Create fake module file
        import platform
        if platform.system() == "Windows":
            module_file = self.module_dir / "simdjson.dll"
        else:
            module_file = self.module_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner with all 8 cases (no --case specified)
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir)],
            capture_output=True,
            text=True,
            timeout=15
        )

        # Runner should exit non-zero (one case failed)
        self.assertNotEqual(result.returncode, 0,
                           "Expected non-zero exit when any case fails")

        # Verify all 8 cases were run
        results_file = self.output_dir / "results.json"
        with open(results_file) as f:
            results = json.load(f)
        
        expected_cases = [
            "nan", "negative-nan", "positive-infinity", "negative-infinity",
            "array-nan", "object-nan", "infinite-key", "repeat-nan"
        ]
        for case in expected_cases:
            self.assertIn(case, results["cases"],
                         f"Case {case} should be in results")
        
        # Verify repeat-nan failed but others passed
        self.assertFalse(results["cases"]["repeat-nan"]["pass"],
                        "repeat-nan should fail")
        self.assertTrue(results["cases"]["nan"]["pass"],
                       "nan should pass")

    def test_missing_module_fails_before_execution(self):
        """Test that missing module causes failure before probe execution."""
        # Create probe that would output marker file
        probe = self.module_dir / "tmp_rovo_probe_marker.py"
        marker_file = self.output_dir / "marker.txt"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"with open('{marker_file}', 'w') as f:\n"
            "    f.write('executed')\n"
            "case = sys.argv[1]\n"
            "print(f'PASS {case}')\n"
            "sys.exit(0)\n"
        )
        probe.chmod(0o755)

        # Do NOT create module file - this is the test
        # Run runner - it should fail before executing probe
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir),
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Runner should exit non-zero
        self.assertNotEqual(result.returncode, 0,
                           "Expected non-zero exit when module missing")
        
        # Verify stderr indicates module error
        self.assertIn("Module file not found", result.stderr,
                     "Should report missing module in stderr")
        
        # Verify marker file was never created (probe never executed)
        self.assertFalse(marker_file.exists(),
                        "Probe should not execute if module check fails")

    def test_paths_with_spaces_use_argument_vectors(self):
        """Test that paths with spaces are handled correctly via argv."""
        # Create subdirectory with spaces in name
        space_dir = Path(self.test_dir.name) / "module with spaces"
        space_dir.mkdir(exist_ok=True)
        
        # Create probe in the spaced directory
        probe = space_dir / "probe with spaces.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "# Verify we received args correctly\n"
            "case = sys.argv[1]\n"
            "module_dir = sys.argv[2]\n"
            "print(f'PASS {case}')\n"
            "sys.exit(0)\n"
        )
        probe.chmod(0o755)

        # Create module file in spaced directory
        import platform
        if platform.system() == "Windows":
            module_file = space_dir / "simdjson.dll"
        else:
            module_file = space_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner with paths containing spaces
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(space_dir),
             "--output", str(self.output_dir),
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Should succeed despite spaces in paths
        self.assertEqual(result.returncode, 0,
                        f"Failed with spaced paths: {result.stderr}")

        # Verify results indicate success
        results_file = self.output_dir / "results.json"
        with open(results_file) as f:
            results = json.load(f)
        self.assertTrue(results["cases"]["nan"]["pass"],
                       "Should detect PASS despite spaced paths")

    def test_malformed_no_pass_exit_zero_case(self):
        """Test that exit 0 without PASS marker still fails."""
        # Create probe that exits 0 but outputs nothing recognizable
        probe = self.module_dir / "tmp_rovo_probe_malformed.py"
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "case = sys.argv[1]\n"
            "print('Some random output')\n"
            "sys.exit(0)\n"  # Exit success but no PASS marker
        )
        probe.chmod(0o755)

        # Create fake module file
        import platform
        if platform.system() == "Windows":
            module_file = self.module_dir / "simdjson.dll"
        else:
            module_file = self.module_dir / "simdjson.so"
        module_file.write_text("fake module")

        # Run runner
        result = subprocess.run(
            [sys.executable, str(self.runner_path),
             "--lua", sys.executable,
             "--probe", str(probe),
             "--module-dir", str(self.module_dir),
             "--output", str(self.output_dir),
             "--case", "nan"],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Runner should exit non-zero (no PASS marker detected)
        self.assertNotEqual(result.returncode, 0,
                           "Expected non-zero for missing PASS marker")

        # Verify results show failure
        results_file = self.output_dir / "results.json"
        with open(results_file) as f:
            results = json.load(f)
        self.assertFalse(results["cases"]["nan"]["pass"],
                        "Should fail if PASS marker not found, even with exit 0")

    def test_runner_cases_match_probe_valid_cases(self):
        """Every runner case must be accepted by the Lua probe, and vice versa."""
        sys.path.insert(0, str(Path(__file__).parent))
        try:
            import run_encode_diagnostics
        finally:
            sys.path.pop(0)
        probe = (Path(__file__).parent / "encode_probe.lua").read_text()
        block = probe.split("local valid_cases = {", 1)[1].split("\n}", 1)[0]
        probe_cases = set(re.findall(r'\["([a-z-]+)"\] = true', block))
        self.assertEqual(set(run_encode_diagnostics.DEFAULT_CASES), probe_cases)
        self.assertEqual(len(run_encode_diagnostics.DEFAULT_CASES),
                         len(probe_cases), "DEFAULT_CASES contains duplicates")


if __name__ == "__main__":
    unittest.main()
