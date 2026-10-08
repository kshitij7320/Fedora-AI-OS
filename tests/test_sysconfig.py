import configparser
import os
import re
import unittest

class TestSysconfig(unittest.TestCase):
    def test_dnf_minimal_conf(self):
        path = "dnf/99-minimal.conf"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        parser = configparser.ConfigParser()
        parser.read(path)
        self.assertIn("main", parser.sections())
        self.assertEqual(parser.get("main", "install_weak_deps").lower(), "false")
        self.assertEqual(parser.get("main", "nodocs").lower(), "true")
        self.assertEqual(parser.get("main", "keepcache").lower(), "false")

    def test_limits_memlock_conf(self):
        path = "limits.d/99-ai-memlock.conf"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertTrue(re.search(r"\*\s+soft\s+memlock\s+unlimited", content))
        self.assertTrue(re.search(r"\*\s+hard\s+memlock\s+unlimited", content))
        self.assertTrue(re.search(r"root\s+soft\s+memlock\s+unlimited", content))
        self.assertTrue(re.search(r"root\s+hard\s+memlock\s+unlimited", content))

    def test_sysctl_ai_tuning(self):
        path = "sysctl.d/99-ai-tuning.conf"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertTrue(re.search(r"vm\.max_map_count\s*=\s*1048576", content))
        self.assertTrue(re.search(r"vm\.overcommit_memory\s*=\s*1", content))
        self.assertTrue(re.search(r"fs\.file-max\s*=\s*2097152", content))

if __name__ == "__main__":
    unittest.main()
