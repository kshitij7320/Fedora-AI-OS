import json
import os
import sys
import unittest

sys.path.insert(0, os.path.abspath("mcp"))

class TestLinuxMCPServer(unittest.TestCase):
    def setUp(self):
        import linux_mcp_server
        self.server = linux_mcp_server.LinuxMCPServer()

    def test_tools_list(self):
        req = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        resp = self.server.handle_request(req)
        self.assertEqual(resp["id"], 1)
        self.assertIn("result", resp)
        tools = [t["name"] for t in resp["result"]["tools"]]
        self.assertIn("get_system_metrics", tools)
        self.assertIn("get_npu_gpu_status", tools)
        self.assertIn("get_journal_logs", tools)
        self.assertIn("get_installed_packages", tools)

    def test_call_system_metrics(self):
        req = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "get_system_metrics", "arguments": {}}
        }
        resp = self.server.handle_request(req)
        self.assertEqual(resp["id"], 2)
        content = json.loads(resp["result"]["content"][0]["text"])
        self.assertIn("memory", content)
        self.assertIn("load_avg", content)
        self.assertIn("uptime_seconds", content)

    def test_call_npu_gpu_status(self):
        req = {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "get_npu_gpu_status", "arguments": {}}
        }
        resp = self.server.handle_request(req)
        self.assertEqual(resp["id"], 3)
        content = json.loads(resp["result"]["content"][0]["text"])
        self.assertIn("drm_devices", content)
        self.assertIn("accel_devices", content)

    def test_systemd_service_hardening(self):
        svc_path = "systemd/linux-mcp-server.service"
        self.assertTrue(os.path.isfile(svc_path), f"Missing {svc_path}")
        with open(svc_path, "r") as f:
            content = f.read()
        self.assertIn("ProtectSystem=strict", content)
        self.assertIn("ProtectHome=yes", content)
        self.assertIn("PrivateTmp=yes", content)
        self.assertIn("NoNewPrivileges=true", content)
        self.assertIn("CapabilityBoundingSet=", content)
        self.assertIn("User=mcpsrv", content)

    def test_systemd_socket_unit(self):
        sock_path = "systemd/linux-mcp-server.socket"
        self.assertTrue(os.path.isfile(sock_path), f"Missing {sock_path}")
        with open(sock_path, "r") as f:
            content = f.read()
        self.assertIn("ListenStream=/run/mcp/linux-mcp.sock", content)
        self.assertIn("SocketUser=mcpsrv", content)

if __name__ == "__main__":
    unittest.main()
