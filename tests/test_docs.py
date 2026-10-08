import os
import unittest

class TestDocumentation(unittest.TestCase):
    def test_readme_sections(self):
        path = "README.md"
        self.assertTrue(os.path.isfile(path), "Missing README.md")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("Architecture Overview", content)
        self.assertIn("Benchmark & Test Plan", content)
        self.assertIn("RAM Footprint", content)
        self.assertIn("Decoupled Model Storage", content)
        self.assertIn("RamaLama", content)
        self.assertIn("Hardware Acceleration", content)
        self.assertIn("SELinux", content)
        self.assertIn("Model Context Protocol", content)

if __name__ == "__main__":
    unittest.main()
