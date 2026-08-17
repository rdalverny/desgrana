# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT

from __future__ import annotations

import importlib.util
import os

from .test_model import PRIVATE_DIR

PRIVATE_CASES_FILE = "cases.py"
PRIVATE_MODULE_NAME = "regression._private"


def _load() -> "tuple[list, list]":
    tests_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(tests_dir, PRIVATE_DIR, PRIVATE_CASES_FILE)
    if not os.path.isfile(path):
        return [], []

    # Load the file by path (Private/ is not a package).
    spec = importlib.util.spec_from_file_location(PRIVATE_MODULE_NAME, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(getattr(module, "CASES", [])), list(getattr(module, "SUITES", []))


PRIVATE_CASES, PRIVATE_SUITES = _load()
