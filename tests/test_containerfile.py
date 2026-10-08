import os
import re
import unittest

class TestContainerfile(unittest.TestCase):
    def setUp(self):
        self.path = "Containerfile"
        self.assertTrue(os.path.isfile(self.path), "Containerfile missing")
        with open(self.path, "r") as f:
            self.content = f.read()

    def test_base_image_and_targets(self):
        self.assertIn("FROM quay.io/fedora/fedora-bootc:latest AS base-os", self.content)
        self.assertIn("FROM base-os AS ai-headless", self.content)
        self.assertIn("FROM ai-headless AS ai-gui", self.content)

    def test_omission_pruning(self):
        omissions = ["cups", "sane", "bluez", "ModemManager", "avahi", "geoclue2"]
        for o in omissions:
            self.assertTrue(
                re.search(rf"\b{o}\b", self.content, re.IGNORECASE),
                f"Missing removal or exclusion of {o}"
            )

    def test_hardware_acceleration(self):
        self.assertIn("mesa-vulkan-drivers", self.content)
        self.assertIn("vulkan-loader", self.content)
        self.assertIn("vulkan-tools", self.content)
        self.assertIn("clinfo", self.content)

    def test_user_creation_and_groups(self):
        self.assertIn("llamasrv", self.content)
        self.assertIn("mcpsrv", self.content)
        self.assertIn("render", self.content)
        self.assertIn("groupadd", self.content)

    def test_stateful_directories(self):
        self.assertIn("/var/lib/models", self.content)
        self.assertIn("/var/lib/ramalama", self.content)

if __name__ == "__main__":
    unittest.main()
