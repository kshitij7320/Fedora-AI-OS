import os
import unittest

class TestSystemdAndProfiles(unittest.TestCase):
    def test_llama_server_service(self):
        path = "systemd/llama-server.service"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("User=llamasrv", content)
        self.assertIn("SupplementaryGroups=render video", content)
        self.assertIn("ProtectSystem=strict", content)
        self.assertIn("DeviceAllow=/dev/dri", content)
        self.assertIn("DeviceAllow=/dev/accel", content)
        self.assertIn("ReadWritePaths=/var/lib/models", content)
        self.assertIn("MemoryDenyWriteExecute=no", content)

    def test_llama_env(self):
        path = "systemd/llama-server.env"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("LLAMA_HOST=127.0.0.1", content)
        self.assertIn("LLAMA_PORT=8080", content)
        self.assertIn("LLAMA_MODELS_DIR=/var/lib/models", content)

    def test_audio_filter_chain(self):
        path = "audio/99-deepfilter-pipewire.conf"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("pipewire-module-filter-chain", content)
        self.assertIn("deepfilter", content.lower())

    def test_wayland_autostart(self):
        path = "wayland/labwc-autostart"
        self.assertTrue(os.path.isfile(path), f"Missing {path}")
        with open(path, "r") as f:
            content = f.read()
        self.assertIn("foot", content)

if __name__ == "__main__":
    unittest.main()
