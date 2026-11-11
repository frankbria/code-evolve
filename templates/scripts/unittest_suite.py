#!/usr/bin/env python3
"""Decide whether `python -m unittest` runs a project's whole test suite.

Usage: unittest_suite.py <project_dir> [skipped directory name]...

Prints the unittest arguments (`discover`, or `discover -s tests`) when every test pytest
would collect is one unittest discovery loads too. Prints nothing otherwise: a suite unittest
would run in part, or not at all, must not pass as verified. Called by detect_stack.sh for a
project that has no pytest. The test files are parsed, never imported.
"""

import ast
import os
import re
import sys

UNITTEST_BASES = {"TestCase", "IsolatedAsyncioTestCase"}
# unittest discovery skips, without a word, a file whose name is not a module name.
MODULE_FILE = re.compile(r"[_a-z]\w*\.py\Z", re.IGNORECASE)
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)


def is_unittest_file(name):
    return name.startswith("test") and name.endswith(".py")


def project_test_files(project, skipped):
    """Every file pytest collects by name, or None when a conftest.py says the suite is pytest's."""
    found = set()
    for directory, subdirectories, names in os.walk(project):
        subdirectories[:] = [name for name in subdirectories if name not in skipped]
        if "conftest.py" in names:
            return None
        found.update(
            os.path.join(directory, name)
            for name in names
            if is_unittest_file(name) or name.endswith("_test.py")
        )
    return found


def discovered_files(directory):
    """The files unittest discovery loads from a start directory: its test files and, as it
    only enters packages, the __init__.py of each one it enters."""
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.is_file():
                if is_unittest_file(entry.name) and MODULE_FILE.match(entry.name):
                    yield entry.path
            elif (
                entry.is_dir(follow_symlinks=False)
                and entry.name.isidentifier()
                and os.path.isfile(os.path.join(entry.path, "__init__.py"))
            ):
                yield os.path.join(entry.path, "__init__.py")
                yield from discovered_files(entry.path)


def scope_statements(nodes):
    """Statements that run in one scope: its own and those under if, try, with and loops."""
    for node in nodes:
        if isinstance(node, ast.stmt):
            yield node
        if not isinstance(node, FUNCTIONS + (ast.ClassDef, ast.expr)):
            yield from scope_statements(ast.iter_child_nodes(node))


def is_test_function(node):
    return isinstance(node, FUNCTIONS) and node.name.startswith("test")


def may_hold_tests(node, test_free):
    """False only when a class that is not a TestCase is known to give pytest nothing to
    collect: no test method, no Test* class inside that may hold one, and every base a class
    of the same file known the same way. A base from elsewhere may bring tests along."""
    return any(
        is_test_function(statement)
        or (
            isinstance(statement, ast.ClassDef)
            and statement.name.startswith("Test")
            and may_hold_tests(statement, {"object"})
        )
        for statement in scope_statements(node.body)
    ) or not all(isinstance(base, ast.Name) and base.id in test_free for base in node.bases)


def imports_pytest(tree):
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0:
            modules = [node.module or ""]
        else:
            continue
        if any(module.split(".")[0] == "pytest" for module in modules):
            return True
    return False


def bound_names(statement):
    """The names a module-level statement binds: by def, class, import or assignment."""
    if isinstance(statement, FUNCTIONS + (ast.ClassDef,)):
        return {statement.name}
    if isinstance(statement, (ast.Import, ast.ImportFrom)):
        return {alias.asname or alias.name.split(".")[0] for alias in statement.names}
    if isinstance(statement, ast.Assign):
        targets = statement.targets
    elif isinstance(statement, (ast.AnnAssign, ast.AugAssign, ast.For, ast.AsyncFor)):
        targets = [statement.target]
    elif isinstance(statement, (ast.With, ast.AsyncWith)):
        targets = [item.optional_vars for item in statement.items if item.optional_vars]
    else:
        return set()
    return {
        node.id for target in targets for node in ast.walk(target) if isinstance(node, ast.Name)
    }


def unittest_module(node):
    """The name a base's module is reached through: `ut` for ut.TestCase and ut.case.TestCase."""
    if isinstance(node, ast.Attribute) and node.attr == "case":
        node = node.value
    return node.id if isinstance(node, ast.Name) else None


def classify(tree):
    """'pytest' when the file holds a test only pytest collects, 'unittest' when it defines a
    unittest.TestCase class and no such test, else 'neither'."""
    if imports_pytest(tree):
        return "pytest"
    unittest_modules = set()
    test_cases = set()
    test_free = {"object"}
    kind = "neither"
    # shortcut: names are followed inside one file only, so a Test* class whose base is
    # imported from the project's own module keeps pytest, TestCase or not. Resolve imports
    # across files if such suites need the unittest fallback.
    for statement in scope_statements(tree.body):
        names = bound_names(statement)
        # A load_tests hook decides itself what unittest loads from the module or package.
        if "load_tests" in names:
            return "pytest"
        # Whatever a name stood for, it now stands for what this statement binds.
        unittest_modules -= names
        test_cases -= names
        test_free -= names
        if isinstance(statement, ast.Import):
            for alias in statement.names:
                if alias.name == "unittest":
                    unittest_modules.add(alias.asname or "unittest")
                elif alias.name.startswith("unittest.") and alias.asname is None:
                    unittest_modules.add("unittest")
        elif isinstance(statement, ast.ImportFrom):
            if statement.module == "unittest" and statement.level == 0:
                test_cases.update(
                    alias.asname or alias.name
                    for alias in statement.names
                    if alias.name in UNITTEST_BASES
                )
            # pytest collects a test function a module imports as if it were defined there.
            if any((alias.asname or alias.name).startswith("test") for alias in statement.names):
                return "pytest"
        elif is_test_function(statement):
            return "pytest"
        elif isinstance(statement, ast.ClassDef):
            derives = any(
                (isinstance(base, ast.Name) and base.id in test_cases)
                or (
                    isinstance(base, ast.Attribute)
                    and base.attr in UNITTEST_BASES
                    and unittest_module(base.value) in unittest_modules
                )
                for base in statement.bases
            )
            if derives:
                test_cases.add(statement.name)
                kind = "unittest"
            elif not may_hold_tests(statement, test_free):
                test_free.add(statement.name)
            elif statement.name.startswith("Test"):
                # pytest collects it by its name; unittest does not.
                return "pytest"
    return kind


def unittest_arguments(project, skipped):
    test_files = project_test_files(project, skipped)
    if not test_files:
        return ""
    tests_directory = os.path.join(project, "tests")
    start = project
    arguments = "discover"
    # Discovery only enters packages, so a plain tests/ folder is named as the start instead.
    if (
        os.path.isdir(tests_directory)
        and not os.path.isfile(os.path.join(tests_directory, "__init__.py"))
        and any(discovered_files(tests_directory))
    ):
        start = tests_directory
        arguments = "discover -s tests"
    loaded = set(discovered_files(start))
    if not test_files <= loaded:
        return ""

    kinds = set()
    for path in loaded:
        try:
            with open(path, "rb") as source:
                kinds.add(classify(ast.parse(source.read(), filename=path)))
        except (OSError, SyntaxError, ValueError, RecursionError):
            # A file this Python cannot read or parse is left to pytest to report.
            return ""
    return arguments if "unittest" in kinds and "pytest" not in kinds else ""


if __name__ == "__main__":
    print(unittest_arguments(sys.argv[1], set(sys.argv[2:])))
