"""Put Tools/probe on sys.path so tests import modules directly (no package needed)."""
import os
import sys

PROBE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROBE_DIR not in sys.path:
    sys.path.insert(0, PROBE_DIR)
