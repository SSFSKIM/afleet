"""Put Tools/fake-claude on sys.path so tests import fake_claude directly (no package needed)."""
import os
import sys

TOOL_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)
