#!/usr/bin/env python3
"""List the git / gh calls and script runs in a Bash command that run outside the checkout.

Usage: checkout-cwd.py --command <command or - for stdin> --cwd <hook cwd> --root <main checkout>

The checkout is the root's repository: the main checkout and every worktree of it,
told apart from other directories by their common git dir. Each call is judged in
the directories it may run in: the hook cwd, moved by each cd before it and by
env -C / sudo -D (--chdir), and for git by its -C options. One line is printed per call and directory outside the
checkout, "<kind>\\t<directory>\\t<word>", with an empty directory when the directory
cannot be known. A root without .git defines no checkout, so nothing is printed.
Exit 1 when the command cannot be parsed or git cannot read the root, or a worktree of it a call
runs in.

Heredocs and comments are removed before the command is read. Bodies are not
read: one with an unquoted delimiter that runs a command substitution is an
error, as are a heredoc that does not end at its delimiter and a case command
inside $( ). A script is judged by where it runs, not by what it runs: whether
it calls gh cannot be seen from here. Not a shell interpreter.
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
# Commands that run the command named after them, with the options that take a value.
# A value may also be joined to its option (-uHOME, --unset=HOME).
_WRAPPERS = {
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "xargs": {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "--max-args", "--max-procs",
              "--max-lines", "--delimiter", "--eof", "--max-chars", "--arg-file", "--replace"},
    "sudo": {"-u", "-g", "-h", "-p", "-U", "-r", "-t", "-C", "--user", "--group", "--host",
             "--prompt", "--other-user", "--role", "--type", "--close-from"},
    "nice": {"-n", "--adjustment"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "env": {"-u", "--unset"},
    "time": {"-f", "-o", "--format", "--output"},
    "exec": {"-a"},
    "nohup": set(), "command": set(), "builtin": set(),
}
# Wrapper options whose value is the directory the command runs in.
_CHDIR_OPTIONS = {"env": {"-C", "--chdir"}, "sudo": {"-D", "--chdir"}}
# Wrapper options after which the command cannot be read (env -S splits its value into one).
_OPAQUE_OPTIONS = {"env": {"-S", "--split-string"}}
_ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
_VARIABLE = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")
_DURATION = re.compile(r"[0-9.]+[smhd]?")
_FUNCTION = re.compile(r"(?:function[ \t]+[A-Za-z_][A-Za-z0-9_-]*(?=[\s({])"
                       r"|[A-Za-z_][A-Za-z0-9_-]*[ \t]*\([ \t\n]*\))")


def _dynamic(word):
    return any(c in word for c in "$`")


def _literal(word, variables):
    """The word with a whole-word $NAME / ${NAME} of a trusted literal assignment replaced,
    or None when it still expands."""
    match = _VARIABLE.fullmatch(word)
    if match:
        return variables.get(match.group(1) or match.group(2))
    return None if _dynamic(word) else word


def _assigned_once(segments):
    """The names assigned by exactly one NAME= word in the command and never written as a
    bare word (for NAME, read NAME, printf -v NAME ...), so nothing else changes them."""
    assigned, bare = {}, set()
    for words, _nested, _before, _after in segments:
        for word in words:
            match = _ASSIGNMENT.fullmatch(word)
            if match:
                assigned[match.group(1)] = assigned.get(match.group(1), 0) + 1
            elif re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", word):
                bare.add(word)
    return {name for name, count in assigned.items() if count == 1 and name not in bare}


def _heredoc_word(text, index):
    """(delimiter, end, quoted): the heredoc word at index with its quotes and backslashes
    removed, and whether it had any (a body is expanded only when it had none)."""
    word, quote, quoted = [], None, False
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = None
            else:
                word.append(char)
        elif char in "'\"":
            quote, quoted = char, True
        elif char == "\\" and index + 1 < len(text):
            index += 1
            quoted = True
            word.append(text[index])
        elif char in " \t\n;&|()<>":
            break
        else:
            word.append(char)
        index += 1
    return "".join(word), index, quoted


UNREADABLE_BODY = ("the body of an unquoted heredoc runs a command substitution, which is not read"
                   " here: quote its delimiter (<<'EOF'), which writes the substitution as text, or"
                   " assign its value to a variable before the heredoc (v=$(...)) and write $v in the body.")


def _check_body(body):
    """ValueError when bash would run a command in this unquoted heredoc body: an
    unescaped $(, ` or $((. A backslash in a body escapes only $, `, \\ and a newline."""
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\":
            index += 2
            continue
        if char == "`" or body.startswith("$(", index):
            raise ValueError(UNREADABLE_BODY)
        index += 1


def _command_position(command, index):
    """Whether the word at index starts a command: after (, ;, &, |, a newline, or a
    keyword that a command follows."""
    before = command[:index].rstrip(" \t")
    if not before or before[-1] in "(;&|\n":
        return True
    return re.search(r"(^|[\s;&|(])(then|do|else|if|elif|while|until|!|\{)$", before) is not None


def prepare_command(command):
    """Return (command without heredocs, has_function_definition). Quotes,
    parameter expansions, arithmetic and comments are followed so that a << inside
    them, or a <<<, starts no heredoc; command substitutions and backquotes are
    followed to their end, and a heredoc inside them is removed like any other. A
    comment is blanked out, keeping its #, so that no quote or << in it is read.
    ValueError when a heredoc has no delimiter or does not end at its delimiter line,
    a body with an unquoted delimiter runs a command substitution, a case command is
    inside $( ), or a quote or substitution does not end."""
    out, stack, pending, index, length = [], [["code", 0]], [], 0, len(command)
    has_function = False
    escaped = -1  # the index of the last character a backslash escaped
    closed = -1  # the index of the last ) that closed a $( or $((
    while index < length:
        char, context = command[index], stack[-1]
        kind = context[0]
        step = 1
        if kind == "sq":
            if char == "'":
                stack.pop()
        elif kind == "dq":
            if char == "\\":
                step = 2
            elif char == '"':
                stack.pop()
            elif command.startswith("$((", index):
                stack.append(["arith", 0])
                step = 3
            elif command.startswith("$(", index):
                stack.append(["sub", 0])
                step = 2
            elif command.startswith("${", index):
                stack.append(["param", 0])
                step = 2
            elif char == "`":
                stack.append(["bq", 0])
        elif kind in ("arith", "param"):
            if char == "\\":
                step = 2
            elif kind == "param" and char in "'\"":
                stack.append(["sq" if char == "'" else "dq", 0])
            elif kind == "param" and command.startswith("$(", index):
                stack.append(["sub", 0])
                step = 2
            elif kind == "arith" and command.startswith("))", index) and context[1] == 0:
                stack.pop()
                closed = index + 1
                step = 2
            elif char == ("(" if kind == "arith" else "{"):
                context[1] += 1
            elif char == (")" if kind == "arith" else "}"):
                if kind == "param" and context[1] == 0:
                    stack.pop()
                else:
                    context[1] -= 1
        elif char == "\\":
            escaped = index + 1
            step = 2
        elif char in "'\"":
            stack.append(["sq" if char == "'" else "dq", 0])
        elif char == "`":
            if kind == "bq":
                stack.pop()
            else:
                stack.append(["bq", 0])
        elif command.startswith("$((", index) or command.startswith("((", index):
            stack.append(["arith", 0])
            step = 3 if char == "$" else 2
        elif command.startswith("$(", index):
            stack.append(["sub", 0])
            step = 2
        elif command.startswith("${", index):
            stack.append(["param", 0])
            step = 2
        elif (kind == "sub" and command.startswith("case", index)
              and command[index + 4:index + 5] in (" ", "\t", "\n") and _command_position(command, index)):
            raise ValueError("a case command inside $( ) is not read here: its pattern ) would end the"
                             " substitution; move the case out of $( ) and set the variable in its branches.")
        elif ((index == 0 or command[index - 1] in " \t\n;&|({)")
              and (char.isalpha() or char == "_") and _FUNCTION.match(command, index)
              and (_command_position(command, index) or command[:index].rstrip().endswith(")"))):
            has_function = True
        elif char == "(" and kind == "sub":
            context[1] += 1
        elif char == ")" and kind == "sub":
            if context[1] == 0:
                stack.pop()
                closed = index
            else:
                context[1] -= 1
        elif char == "#" and (index == 0 or (command[index - 1] in " \t\n;&|()"
                                             and escaped != index - 1 and closed != index - 1)):
            # A comment runs to the end of the line; blanked so no quote or << in it counts.
            end = command.find("\n", index)
            end = length if end < 0 else end
            out.append("#" + " " * (end - index - 1))
            index = end
            continue
        elif command.startswith("<<<", index):
            step = 3
        elif command.startswith("<<", index):
            start = index + 2
            tabs = command.startswith("-", start)
            start += tabs
            while start < length and command[start] in " \t":
                start += 1
            delimiter, index, quoted = _heredoc_word(command, start)
            if not delimiter:
                raise ValueError("a heredoc has no delimiter.")
            pending.append((delimiter, tabs, quoted))
            out.append(" ")
            continue
        elif char == "\n" and pending:
            out.append(char)
            index += 1
            for delimiter, tabs, quoted in pending:
                body = []
                while True:
                    if index >= length:
                        raise ValueError("a heredoc does not end at its delimiter " + delimiter + ".")
                    end = command.find("\n", index)
                    end = length if end < 0 else end
                    line, index = command[index:end], end + 1
                    if (line.lstrip("\t") if tabs else line) == delimiter:
                        break
                    body.append(line)
                if not quoted:
                    _check_body("\n".join(body))
            pending = []
            continue
        out.append(command[index:index + step])
        index += step
    if pending:
        raise ValueError("a heredoc does not end at its delimiter " + pending[0][0] + ".")
    if len(stack) > 1:
        raise ValueError("a quote or substitution does not end.")
    return "".join(out), has_function


def _move(directories, value):
    """directories each moved to value (~ expanded), or None when that cannot be known."""
    value = os.path.expanduser(value)
    if Path(value).is_absolute():
        return {Path(value).resolve()}
    return None if directories is None else {(directory / value).resolve() for directory in directories}


def command_index(words, directories, variables):
    """(index, directories, opaque): the command a simple command runs, past assignments,
    keywords, redirections and wrappers with their options; the directories it runs in
    after a wrapper's chdir option; and whether the command cannot be read. index is None
    when it runs no command."""
    index, wrapper = 0, None
    while index < len(words):
        word = words[index]
        if isinstance(word, scope._Redirection):
            index = scope._redirection_end(words, index)
        elif _ASSIGNMENT.fullmatch(word) or word in scope._KEYWORDS:
            index += 1
        elif Path(word).name in _WRAPPERS:
            wrapper = Path(word).name
            index += 1
            if wrapper == "timeout":
                # timeout takes its duration before the command.
                while index < len(words) and words[index].startswith("-"):
                    option = words[index].split("=", 1)[0]
                    index += 2 if option in _WRAPPERS["timeout"] and "=" not in words[index] else 1
                if index < len(words) and _DURATION.fullmatch(words[index]):
                    index += 1
                continue
        elif wrapper and word.startswith("-") and word != "-":
            chdir, opaque = _CHDIR_OPTIONS.get(wrapper, set()), _OPAQUE_OPTIONS.get(wrapper, set())
            valued = _WRAPPERS[wrapper] | chdir | opaque
            option, sep, joined = word.partition("=")
            joined = joined if sep else None
            if joined is None and not option.startswith("--") and option[:2] in valued and len(option) > 2:
                option, joined = option[:2], option[2:]
            if option in opaque:
                # The split string can carry its own -C, so the directory is unknown too.
                return index, None, True
            if option not in valued:
                # A flag without a value.
                index += 1
                continue
            if joined is None:
                if index + 1 >= len(words):
                    return None, directories, False
                value, index = words[index + 1], index + 2
            else:
                value, index = joined, index + 1
            if option in chdir:
                target = _literal(value, variables)
                directories = None if target is None else _move(directories, target)
        else:
            return index, directories, False
    return None, directories, False


def kind_of(word, directories, path_dirs):
    """git, gh, script, or None for a command word run in directories."""
    if _dynamic(word):
        return "script"
    name = Path(word).name
    if name in ("git", "gh"):
        return name
    if word == "." or name in _INTERPRETERS or _PYTHON.fullmatch(name):
        return "script"
    if "/" in word:
        # A command named by a path outside the PATH directories is a script.
        resolved = _move(directories, word)
        if resolved is None or any(path.parent not in path_dirs for path in resolved):
            return "script"
    return None


def git_directories(words, index, directories, variables, changes):
    """(directories, changes) after applying each -C among the global options of the git
    at words[index]. A -C whose value is a variable leaves the directory as it was: the
    shell's own directory is what a cwd-dependent credential sees."""
    after_variable, position = False, index + 1
    while position < len(words):
        word = words[position]
        if isinstance(word, scope._Redirection):
            position = scope._redirection_end(words, position)
            continue
        if not word.startswith("-"):
            if _dynamic(word):
                position += 1
                continue
            break
        if word == "-C" or (word.startswith("-C") and not word.startswith("--")):
            if word == "-C":
                if position + 1 >= len(words):
                    break
                value, position = words[position + 1], position + 2
            else:
                value, position = word[2:], position + 1
            value = _literal(value, variables)
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
            continue
        position += 2 if word in scope._GIT_VALUE_OPTIONS else 1
    return directories, changes


def reject_compound_changes(segments, cwd, path_dirs, function=False):
    """Refuse conditional/repeated moves and deferred function calls, not their data.

    The segment reader does not execute branches, iterate loops or call functions.
    Inspect the whole command before yielding: even a call before a loop's cd may
    execute after that cd on its next iteration. Functions can run after an outer
    cd, regardless of where their definition appears.
    """
    openings = {"if": "fi", "for": "done", "while": "done", "until": "done",
                "select": "done", "case": "esac"}
    blocks = []
    moved = compound_move = protected = False
    base = {Path(cwd).resolve()}
    substitutions = []
    for original, nested, _before, after in segments:
        if nested is True:
            substitutions.append((original, False, _before, after))
            continue
        if substitutions:
            # A substitution keeps its directory changes. Its calls still inherit
            # outer changes, but a cd used only to resolve a path cannot move them.
            protected |= reject_compound_changes(substitutions, cwd, path_dirs, function)
            substitutions = []
        words = scope._without_redirections(original)
        if not words:
            continue
        start = 0
        while start < len(words):
            word = words[start]
            if word == "function":
                start += 2  # keyword and function name; the body may share this segment
                continue
            if word in openings:
                blocks.append(openings[word])
                if word in ("for", "select", "case"):
                    start = len(words)  # header words and case patterns are data
                    break
            elif word in ("fi", "done", "esac"):
                if blocks and blocks[-1] == word:
                    blocks.pop()
            elif word not in scope._KEYWORDS:
                break
            start += 1
        words = words[start:]
        index, directories, opaque = command_index(words, base, {})
        if index is None:
            continue
        if words[index] in scope._DIRECTORY_MOVERS:
            moved = True
            compound_move |= bool(blocks)
        elif opaque or kind_of(words[index], directories, path_dirs):
            protected = True
    if substitutions:
        protected |= reject_compound_changes(substitutions, cwd, path_dirs, function)
    if protected and (compound_move or (function and moved)):
        raise ValueError("cannot determine the working directory when a directory change is inside"
                         " if / case / a loop, or combined with a function definition; move the"
                         " directory change out of the compound command and run git / gh / scripts"
                         " in a separate Bash call from the checkout.")
    return protected


def each_call(command, cwd):
    """Yield (kind, directories, word) for each git / gh call and script run, in order.
    directories is the set it may run in, or None when that cannot be known.

    A literal cd moves the calls after it. One after ||, or to a directory that does
    not exist yet, may not take effect, so the calls after it may run in either
    directory. A cd in a pipeline or in the background runs in a subshell and moves
    nothing. A variable counts as literal when this command assigned it a literal
    value once and changes it nowhere else. A cd to any other variable, cd -,
    pushd / popd, and a cd with options or wrappers make the directory unknown. A cd
    in a ( ) group moves only the calls in that group, the groups inside it and the
    command substitutions of its commands; a cd in a command substitution moves only
    the calls in that run of substituted commands.
    """
    path_dirs = {Path(p).resolve() for p in os.environ.get("PATH", "").split(os.pathsep) if p}
    here, nested_here, in_nested, changes, variables = {Path(cwd).resolve()}, None, False, 0, {}
    group_dirs = {}  # enclosing group ids -> the directories their commands run in

    def group_base(ids):
        for end in range(len(ids), 0, -1):
            if ids[:end] in group_dirs:
                return group_dirs[ids[:end]]
        return here

    command, has_function = prepare_command(command)
    segments = scope.shell_segments(command, group_ids=True)
    reject_compound_changes(segments, cwd, path_dirs, has_function)
    trusted = _assigned_once(segments)
    for position, (words, nested, before, after) in enumerate(segments):
        group = nested[1] if isinstance(nested, tuple) else None
        substituted = nested is True
        if substituted and not in_nested:
            # A substitution's commands come just ahead of the command containing it,
            # which runs in its own group's directory.
            owner = next((segments[j][1] for j in range(position, len(segments))
                          if segments[j][1] is not True), False)
            nested_here = group_base(owner[1]) if isinstance(owner, tuple) else here
        in_nested = substituted
        base = nested_here if substituted else group_base(group) if group else here
        if not nested and all(_ASSIGNMENT.fullmatch(word) for word in words):
            for word in words:
                name, value = _ASSIGNMENT.fullmatch(word).groups()
                if _dynamic(value) or name not in trusted:
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
            may_fail = before == "||" or (moved is not None and any(not path.is_dir() for path in moved))
            if may_fail and moved is not None and base is not None:
                moved = moved | base
            elif may_fail:
                moved = None
            if substituted:
                nested_here = moved
            elif group:
                group_dirs[group] = moved
            else:
                here = moved
            continue
        index, directories, opaque = command_index(words, base, variables)
        if opaque:
            yield "script", directories, words[index]
            continue
        if index is None:
            continue
        kind = kind_of(words[index], directories, path_dirs)
        if kind is None:
            continue
        if kind == "git":
            directories, changes = git_directories(words, index, directories, variables, changes)
        yield kind, directories, words[index]


def rev_parse(directory, *options):
    return subprocess.run(["git", "-C", str(directory), "rev-parse", *options], capture_output=True, text=True)


def common_dir(directory):
    """The directory's common git dir, or None when git cannot give one."""
    result = rev_parse(directory, "--path-format=absolute", "--git-common-dir")
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else None


def unreadable(directory):
    return OSError("git cannot read the repository at " + str(directory) + ". git reports:\n"
                   + rev_parse(directory, "--path-format=absolute", "--git-common-dir").stderr.strip())


def worktrees(root):
    result = subprocess.run(["git", "-C", root, "worktree", "list", "--porcelain"], capture_output=True, text=True)
    if result.returncode != 0:
        raise OSError("git cannot list the worktrees of " + root + ". git reports:\n" + result.stderr.strip())
    # A prunable worktree is gone: a directory made at its path later is not in the checkout.
    blocks = [block.splitlines() for block in result.stdout.split("\n\n")]
    return [Path(block[0][len("worktree "):]).resolve() for block in blocks
            if block and block[0].startswith("worktree ") and not any(line.startswith("prunable") for line in block)]


def existing(directory):
    """The directory, or its nearest existing ancestor: a directory the command creates
    before it moves there does not exist yet."""
    return next(path for path in (directory, *directory.parents) if path.is_dir())


def main():
    parser = argparse.ArgumentParser()
    for name in ("command", "cwd", "root"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    # "-" reads the command from stdin, which a command of any length fits through.
    command = sys.stdin.read() if args.command == "-" else args.command
    checkout = common_dir(args.root)
    if checkout is None:
        if (Path(args.root) / ".git").exists():
            raise unreadable(args.root)
        return
    inside = {}
    trees = None
    for kind, directories, word in each_call(command, args.cwd):
        for directory in sorted(directories, key=str) if directories is not None else [None]:
            if directory is not None and directory not in inside:
                here = existing(directory)
                found = common_dir(here)
                if found is None:
                    # A git that fails in one of the checkout's own worktrees is an error, not
                    # "outside": the outside advice would be denied the same way.
                    trees = worktrees(args.root) if trees is None else trees
                    resolved = here.resolve()
                    if any(tree == resolved or tree in resolved.parents for tree in trees):
                        raise unreadable(here)
                inside[directory] = found == checkout
            if directory is None or not inside[directory]:
                print(kind + "\t" + ("" if directory is None else str(directory)) + "\t" + word)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("ERROR: checkout-cwd: " + str(error), file=sys.stderr)
        sys.exit(1)
