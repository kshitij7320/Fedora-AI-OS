import os
import subprocess
import unittest

class TestBuildPipeline(unittest.TestCase):
    def test_config_toml(self):
        path = "config.toml"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("[[customizations.user]]", content)
        self.assertIn('name = "aioperator"', content)
        self.assertIn("wheel", content)
        self.assertIn("render", content)
        self.assertIn("video", content)

    def test_build_sh_help(self):
        path = "build.sh"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        self.assertTrue(os.access(path, os.X_OK), "build.sh is not executable")
        res = subprocess.run(["./build.sh", "--help"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertIn("--target", res.stdout)
        self.assertIn("--format", res.stdout)
        self.assertIn("--dry-run", res.stdout)

    def test_build_sh_dry_run(self):
        res = subprocess.run(["./build.sh", "--dry-run", "--target", "headless", "--format", "qcow2"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertIn("DRY RUN", res.stdout)
        self.assertIn("ai-headless", res.stdout)
        self.assertIn("bootc-image-builder", res.stdout)

    def test_github_actions_workflow(self):
        path = ".github/workflows/build-iso.yml"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("Build Bootable AI OS ISO", content)
        self.assertIn("workflow_dispatch:", content)
        self.assertIn("bootc-image-builder", content)
        self.assertIn("upload-artifact", content)

if __name__ == "__main__":
    unittest.main()
