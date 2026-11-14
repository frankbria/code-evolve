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
# Where those classes can be imported from.
UNITTEST_MODULES = {"unittest", "unittest.case", "unittest.async_case"}
# unittest discovery skips, without a word, a file whose name is not a module name.
MODULE_FILE = re.compile(r"[_a-z]\w*\.py\Z", re.IGNORECASE)
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
UNREADABLE = (OSError, SyntaxError, ValueError, RecursionError)
# unittest never calls these pytest hooks on a TestCase.
CLASS_HOOKS = {"setup_class", "teardown_class", "setup_method", "teardown_method"}
# A chain of base classes across files is followed this far.
MAX_BASE_FILES = 10
# Module-level names that make the two runners behave differently.
RUNNER_HOOKS = {
    "load_tests",
    "setup_module",
    "teardown_module",
    "setup_function",
    "teardown_function",
}


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


def bound_names(statement):
    """The names a statement binds in its scope: by def, class, import or assignment."""
    if isinstance(statement, FUNCTIONS + (ast.ClassDef,)):
        return [statement.name]
    if isinstance(statement, (ast.Import, ast.ImportFrom)):
        return [alias.asname or alias.name.split(".")[0] for alias in statement.names]
    if isinstance(statement, ast.Assign):
        targets = statement.targets
    elif isinstance(statement, (ast.AnnAssign, ast.AugAssign, ast.For, ast.AsyncFor)):
        targets = [statement.target]
    elif isinstance(statement, (ast.With, ast.AsyncWith)):
        targets = [item.optional_vars for item in statement.items if item.optional_vars]
    else:
        return []
    # Only a name that is stored to: `unittest.TestCase.maxDiff = None` binds nothing.
    return [
        node.id
        for target in targets
        for node in ast.walk(target)
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store)
    ]


def binding_sources(tree, statements):
    """What binds each name: the thing an import names, else the binding statement itself.
    Importing the same thing twice (unittest and unittest.mock, or in try and except) is one
    source; a name with several may stand for any of them."""
    # `(name := value)` binds from inside an expression, wherever it is.
    sources = {
        node.target.id: {id(node)} for node in ast.walk(tree) if isinstance(node, ast.NamedExpr)
    }
    for statement in statements:
        imported = {}
        if isinstance(statement, ast.Import):
            imported = {
                alias.asname or alias.name.split(".")[0]: alias.name if alias.asname else alias.name.split(".")[0]
                for alias in statement.names
            }
        elif isinstance(statement, ast.ImportFrom) and statement.level == 0:
            imported = {
                alias.asname or alias.name: "%s.%s" % (statement.module, alias.name)
                for alias in statement.names
            }
        for name in bound_names(statement):
            sources.setdefault(name, set()).add(imported.get(name, id(statement)))
    return sources


def may_hold_tests(node, test_free):
    """False only when a class that is not a TestCase is known to give pytest nothing to
    collect: nothing named test* in its body (a method, or a function assigned to the name),
    no Test* class inside that may hold one, and every base a class of the same file known
    the same way. A base from elsewhere may bring tests along."""
    return any(
        any(name.startswith("test") for name in bound_names(statement))
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


def unittest_module(node):
    """The name a base's module is reached through: `ut` for ut.TestCase, ut.case.TestCase
    and ut.async_case.IsolatedAsyncioTestCase."""
    if isinstance(node, ast.Attribute) and node.attr in ("case", "async_case"):
        node = node.value
    return node.id if isinstance(node, ast.Name) else None


def names_a_test(name):
    """A module-level name pytest looks at, apart from unittest's own classes."""
    return name.startswith(("test", "Test")) and name not in UNITTEST_BASES


def project_module_paths(statement, directories):
    """The files of the project that `from module import ...` may read, nearest first; none when
    the module is found nowhere in `directories` (an installed one)."""
    relative = (statement.module or "").replace(".", os.sep)
    if statement.level:
        # `from ..module`: one package up from the file's own for each further dot.
        package = directories[0]
        for _ in range(statement.level - 1):
            package = os.path.dirname(package)
        directories = [package]
    paths = []
    for directory in directories:
        for path in (
            os.path.join(directory, relative + ".py"),
            os.path.join(directory, relative, "__init__.py"),
        ):
            if os.path.isfile(path) and os.path.realpath(path) not in map(os.path.realpath, paths):
                paths.append(path)
    return paths


def project_module_path(statement, directories):
    paths = project_module_paths(statement, directories)
    return paths[0] if paths else None


def star_import_brings_tests(statement, directories):
    """True when `from module import *` reads a file of the project that binds a name pytest
    looks at or a load_tests hook, has a star import of its own, or cannot be parsed. A module
    found nowhere in `directories` is an installed one and brings none."""
    path = project_module_path(statement, directories)
    if path is None:
        return False
    try:
        return any(
            names_a_test(name) or name == "*" or name in RUNNER_HOOKS
            for imported in scope_statements(parse(path).body)
            for name in bound_names(imported)
        )
    except UNREADABLE:
        return True


def imported_test_cases(statement, directories, visited):
    """The names `from module import Name` brings in that the project's file defines as
    unittest TestCase classes. Nothing when the file is not found, not readable, or already
    being read (an import cycle)."""
    paths = project_module_paths(statement, directories)
    # Two files the import could read: which one Python takes depends on sys.path at run time.
    if len(paths) != 1 or paths[0] in visited or len(visited) >= MAX_BASE_FILES:
        return set()
    path = paths[0]
    found = set()
    try:
        # A file that holds a test only pytest runs may also hold bases unittest would run wrongly.
        if classify(
            parse(path), [os.path.dirname(path)] + directories[1:], found, visited + (path,)
        ) == "pytest":
            return set()
    except UNREADABLE:
        return set()
    return {alias.asname or alias.name for alias in statement.names if alias.name in found}


def parse(path):
    with open(path, "rb") as source:
        return ast.parse(source.read(), filename=path)


# Values a test_* name can hold that are test data, never a test: literals and displays.
DATA_VALUES = (
    ast.Constant, ast.List, ast.Tuple, ast.Dict, ast.Set, ast.JoinedStr,
    ast.ListComp, ast.DictComp, ast.SetComp,
)


def is_callable_value(node):
    """Anything but a literal may be callable (a name, a lambda, a partial, a factory's result),
    and pytest collects a callable test_* name, so only test data is left out."""
    return node is not None and not isinstance(node, DATA_VALUES)


# Calls that can bind module-level names no statement shows (`globals()["test_x"] = ...`).
DYNAMIC_NAMESPACE_CALLS = {"globals", "vars", "exec"}


def attaches_test(statement, test_cases):
    """True for a module-level statement that gives pytest a test the def and class syntax
    does not show, on anything but a TestCase of the file (unittest sees those too)."""
    if not isinstance(statement, FUNCTIONS + (ast.ClassDef,)) and any(
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id in DYNAMIC_NAMESPACE_CALLS
        for node in ast.walk(statement)
    ):
        return True
    # A loop or with target is left bound to its last value.
    if isinstance(statement, (ast.For, ast.AsyncFor, ast.With, ast.AsyncWith)):
        return any(name.startswith(("test", "Test")) for name in bound_names(statement))
    if isinstance(statement, (ast.Assign, ast.AnnAssign)):
        targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
        names = bound_names(statement)
        return (
            # A class made by a call is collected under the name it is assigned to.
            any(name.startswith("Test") for name in names)
            or (
                any(name.startswith("test") for name in names)
                and (
                    is_callable_value(statement.value)
                    # `test_a, test_b = make(1), make(2)`: each name takes one element.
                    or any(isinstance(target, (ast.Tuple, ast.List)) for target in targets)
                )
            )
            or any(
                isinstance(node, ast.Attribute)
                and isinstance(node.ctx, ast.Store)
                and node.attr.startswith("test")
                and not is_known(node.value, test_cases)
                for target in targets
                # `X.test_a, X.test_b = ...` stores to attributes inside an unpacking target.
                for node in ast.walk(target)
            )
        )
    call = statement.value if isinstance(statement, ast.Expr) else None
    return (
        isinstance(call, ast.Call)
        and isinstance(call.func, ast.Name)
        and call.func.id == "setattr"
        and len(call.args) >= 2
        and not is_known(call.args[0], test_cases)
        # A name computed at run time may well start with test.
        and (
            not isinstance(call.args[1], ast.Constant)
            or str(call.args[1].value).startswith("test")
        )
    )


def is_known(node, test_cases):
    return isinstance(node, ast.Name) and node.id in test_cases


def marks_class_as_test(statement):
    """`__test__ = True` in a class body: pytest collects the class whatever it is named."""
    return any(
        isinstance(inner, (ast.Assign, ast.AnnAssign))
        and "__test__" in bound_names(inner)
        and inner.value is not None
        # pytest takes any true value; only a constant known to be false is safe.
        and not (isinstance(inner.value, ast.Constant) and not inner.value.value)
        for inner in scope_statements(statement.body)
    )


def classify(tree, directories, test_cases=None, visited=()):
    """'pytest' when the file holds a test only pytest collects, 'unittest' when it defines a
    unittest.TestCase class and no such test, else 'neither'. `directories` are where a
    module the file imports may be: the file's own first. The names of the file's TestCase
    classes are added to `test_cases`; `visited` holds the files being read to resolve bases."""
    if imports_pytest(tree):
        return "pytest"
    unittest_modules = set()
    test_cases = set() if test_cases is None else test_cases
    test_free = {"object"}
    # Classes of this file, and those that bring pytest's class hooks (their own or a base's).
    local_classes = set()
    hooked = set()
    # TestCase names this file trusts only because another file of the project defines them.
    imported_cases = set()
    kind = "neither"
    statements = list(scope_statements(tree.body))
    sources = binding_sources(tree, statements)
    # A load_tests hook decides itself what unittest loads from the module or package, and
    # only pytest calls its own setup and teardown hooks.
    if RUNNER_HOOKS & sources.keys():
        return "pytest"
    # `(test_x := ...)` binds a name from inside an expression, which no statement shows.
    if any(
        isinstance(node, ast.NamedExpr) and node.target.id.startswith(("test", "Test"))
        for node in ast.walk(tree)
    ):
        return "pytest"

    def trust(names, name):
        # A name bound to two things (in two branches, or again later) may stand for either.
        if len(sources[name]) == 1:
            names.add(name)

    for statement in statements:
        if isinstance(statement, ast.Import):
            for alias in statement.names:
                if alias.name == "unittest":
                    trust(unittest_modules, alias.asname or "unittest")
                elif alias.name in UNITTEST_MODULES and alias.asname:
                    trust(unittest_modules, alias.asname)
                elif alias.name.startswith("unittest.") and alias.asname is None:
                    trust(unittest_modules, "unittest")
        elif isinstance(statement, ast.ImportFrom):
            if statement.module in UNITTEST_MODULES and statement.level == 0:
                for alias in statement.names:
                    if alias.name in UNITTEST_BASES:
                        trust(test_cases, alias.asname or alias.name)
                    elif statement.module == "unittest" and alias.name in ("case", "async_case"):
                        trust(unittest_modules, alias.asname or alias.name)
            # pytest collects a test function or Test* class a module imports as if it were
            # defined there.
            elif any(names_a_test(alias.asname or alias.name) for alias in statement.names):
                return "pytest"
            elif statement.names[0].name != "*":
                for name in imported_test_cases(statement, directories, visited):
                    trust(test_cases, name)
                    imported_cases.add(name)
            elif statement.names[0].name == "*" and star_import_brings_tests(
                statement, directories
            ):
                return "pytest"
        elif is_test_function(statement) or attaches_test(statement, test_cases):
            return "pytest"
        elif isinstance(statement, ast.ClassDef):
            if marks_class_as_test(statement):
                return "pytest"
            local_classes.add(statement.name)
            if CLASS_HOOKS & {
                name for inner in scope_statements(statement.body) for name in bound_names(inner)
            } or any(isinstance(base, ast.Name) and base.id in hooked for base in statement.bases):
                hooked.add(statement.name)
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
                # unittest never calls pytest's class hooks, the class's own or a mixin's.
                if statement.name in hooked:
                    return "pytest"
                # A decorator may turn it into a plain class pytest collects by name; on a base
                # from another file that is followed only by this check, so keep pytest.
                if statement.decorator_list and any(
                    isinstance(base, ast.Name) and base.id in imported_cases for base in statement.bases
                ):
                    return "pytest"
                # Trusted as a base only when everything it is made of is known: a decorator may
                # return something else, and a mixin from elsewhere may bring hooks (its own tests
                # are still unittest's).
                if not statement.decorator_list and all(
                    (isinstance(base, ast.Name) and (base.id in test_cases or base.id in local_classes))
                    or (isinstance(base, ast.Attribute) and base.attr in UNITTEST_BASES)
                    for base in statement.bases
                ):
                    trust(test_cases, statement.name)
                    # A local subclass of an imported TestCase is followed by the same check.
                    if any(isinstance(base, ast.Name) and base.id in imported_cases for base in statement.bases):
                        imported_cases.add(statement.name)
                kind = "unittest"
            elif not may_hold_tests(statement, test_free):
                trust(test_free, statement.name)
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
            directories = [os.path.dirname(path), start, project, os.path.join(project, "src")]
            kinds.add(classify(parse(path), directories))
        except UNREADABLE:
            # A file this Python cannot read or parse is left to pytest to report.
            return ""
    return arguments if "unittest" in kinds and "pytest" not in kinds else ""


if __name__ == "__main__":
    print(unittest_arguments(sys.argv[1], set(sys.argv[2:])))
