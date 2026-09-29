#!/usr/bin/env python3
"""List the git / gh calls and script runs in a Bash command that run outside the checkout.

Usage: checkout-cwd.py --command <command> --cwd <hook cwd> --root <main checkout>

The checkout is the root's repository: the main checkout and every worktree of it,
told apart from other directories by their common git dir. Each call is judged in
the directories it may run in: the hook cwd, moved by each cd before it and, for
git, by its -C options. One line is printed per call and directory outside the
checkout, "<kind>\\t<directory>\\t<word>", with an empty directory when the directory
cannot be known. A root that is not a repository defines no checkout, so nothing is
printed. Exit 1 when the command cannot be parsed.

A script is judged by where it runs, not by what it runs: whether it calls gh
cannot be seen from here. Not a shell interpreter.
"""
import argparse
import importlib
import os
from pathlib import Path
import re
import subprocess
import sys

scope = importlib.import_module("review-fix-scope")

_INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "node", "perl", "ruby", "source", ".", "eval"}
_PYTHON = re.compile(r"python[0-9.]*")
# Commands that run the command named after them.
_WRAPPERS = {"timeout", "xargs", "sudo", "nice", "stdbuf", "nohup", "env", "command", "exec", "time", "builtin"}
_ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
_VARIABLE = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")
_WRAPPER_VALUE = re.compile(r"[0-9.]+[smhd]?")


def _dynamic(word):
    return any(c in word for c in "$`")


def _literal(word, variables):
    """The word with a whole-word $NAME / ${NAME} of a literal assignment replaced,
    or None when it still expands."""
    match = _VARIABLE.fullmatch(word)
    if match:
        return variables.get(match.group(1) or match.group(2))
    return None if _dynamic(word) else word


def _move(directories, value):
    """directories each moved to value (~ expanded), or None when that cannot be known."""
    value = os.path.expanduser(value)
    if Path(value).is_absolute():
        return {Path(value).resolve()}
    return None if directories is None else {(directory / value).resolve() for directory in directories}


def command_index(words):
    """Index of the command a simple command runs, past assignments, keywords,
    redirections and wrappers, or None when it runs none."""
    index, wrapped = 0, False
    while index < len(words):
        word = words[index]
        if isinstance(word, scope._Redirection):
            index = scope._redirection_end(words, index)
        elif _ASSIGNMENT.fullmatch(word) or word in scope._KEYWORDS:
            index += 1
        elif Path(word).name in _WRAPPERS:
            index, wrapped = index + 1, True
        elif wrapped and (word.startswith("-") or _WRAPPER_VALUE.fullmatch(word)):
            index += 1
        else:
            return index
    return None


def kind_of(word, directories, path_dirs):
    """git, gh, script, or None for a command word run in directories."""
    if _dynamic(word):
        return "script"
    name = Path(word).name
    if name in ("git", "gh"):
        return name
    if name in _INTERPRETERS or _PYTHON.fullmatch(name):
        return "script"
    if "/" in word:
        # A command named by a path outside the PATH directories is a script.
        resolved = _move(directories, word)
        if resolved is None or any(path.parent not in path_dirs for path in resolved):
            return "script"
    return None


def each_call(command, cwd):
    """Yield (kind, directories, word) for each git / gh call and script run, in order.
    directories is the set it may run in, or None when that cannot be known.

    A literal cd moves the calls after it; one after || may not run, so the calls
    after it may run in either directory. A cd in a pipeline or in the background
    runs in a subshell and moves nothing. A variable counts as literal when this
    command assigned it a literal value before. A cd to any other variable, cd -,
    pushd / popd, and a cd with options or wrappers make the directory unknown. A cd
    in a subshell or command substitution moves only the calls in that run of
    nested commands. A git -C whose value is a variable leaves the directory as it
    was: the shell's own directory is what a cwd-dependent credential sees.
    """
    path_dirs = {Path(p).resolve() for p in os.environ.get("PATH", "").split(os.pathsep) if p}
    here, nested_here, in_nested, changes, variables = {Path(cwd).resolve()}, None, False, 0, {}

    for words, nested, before, after in scope.shell_segments(command):
        if nested and not in_nested:
            nested_here = here
        in_nested = bool(nested)
        base = nested_here if nested else here
        if not nested and all(_ASSIGNMENT.fullmatch(word) for word in words):
            for word in words:
                name, value = _ASSIGNMENT.fullmatch(word).groups()
                if _dynamic(value):
                    variables.pop(name, None)
                else:
                    variables[name] = value
            continue
        if scope.moves_directory(words):
            start = 0
            while start < len(words) and words[start] in scope._KEYWORDS:
                start += 1
            bare = scope._without_redirections(words[start:])
            target = None
            if bare[0] == "cd" and len(bare) <= 2:
                target = "~" if len(bare) == 1 else _literal(bare[1], variables)
                if target is not None and target.startswith("-"):
                    target = None
            if after in ("|", "&") or before == "|":
                continue
            if target is None or changes >= scope.MAX_DIRECTORY_CHANGES:
                moved = None
            else:
                changes += 1
                moved = _move(base, target)
            if before == "||" and moved is not None and base is not None:
                moved = moved | base
            elif before == "||":
                moved = None
            if nested:
                nested_here = moved
            else:
                here = moved
            continue
        index = command_index(words)
        if index is None:
            continue
        kind = kind_of(words[index], base, path_dirs)
        if kind is None:
            continue
        directories = base
        if kind == "git":
            _sub, steps, _alternate = scope.git_global_options(words, index)
            after_variable = False
            for step, value in steps:
                value = value if step == "-C" else None
                value = None if value is None else _literal(value, variables)
                if value is None:
                    after_variable = True
                elif changes >= scope.MAX_DIRECTORY_CHANGES:
                    directories = None
                else:
                    changes += 1
                    if after_variable and not Path(os.path.expanduser(value)).is_absolute():
                        directories = None
                    else:
                        directories = _move(directories, value)
                        after_variable = False
        yield kind, directories, words[index]


def common_dir(directory):
    result = subprocess.run(["git", "-C", str(directory), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser()
    for name in ("command", "cwd", "root"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    checkout = common_dir(args.root)
    if checkout is None:
        return
    inside = {}
    for kind, directories, word in each_call(args.command, args.cwd):
        for directory in sorted(directories, key=str) if directories is not None else [None]:
            if directory is not None and directory not in inside:
                inside[directory] = directory.is_dir() and common_dir(directory) == checkout
            if directory is None or not inside[directory]:
                print(kind + "\t" + ("" if directory is None else str(directory)) + "\t" + word)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("ERROR: checkout-cwd: " + str(error), file=sys.stderr)
        sys.exit(1)
