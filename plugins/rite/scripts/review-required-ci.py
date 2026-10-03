#!/usr/bin/env python3
"""Final review CI classification, never used to relax Ready/receipt gates.

Usage: python3 review-required-ci.py OWNER/REPO PR REVIEWED_SHA
Fetch classic protection and all active branch rules; an unavailable setting is
an error, not an empty requirement. Check states use the shared classifier.
Output: {state, checks, failed, warnings, required_checks, optional_checks,
         missing_required, all_state, commit_sha, base_branch}.
Exit 1: acquisition/classification error; stdout has no successful JSON.
"""
import json
import pathlib
import re
import subprocess
import sys
from urllib.parse import quote

QUERY = '''query($owner:String!, $repo:String!, $pr:Int!, $endCursor:String) {
 repository(owner:$owner, name:$repo) {
  pullRequest(number:$pr) {
   headRefOid baseRefName
   baseRef { branchProtectionRule {
    requiresStatusChecks requiredStatusCheckContexts
    requiredStatusChecks { context app { databaseId } }
   } }
   commits(last:1) { nodes { commit {
    oid statusCheckRollup { contexts(first:100, after:$endCursor) {
     nodes {
      __typename
      ...on CheckRun { name status conclusion detailsUrl checkSuite { app { databaseId } } }
      ...on StatusContext { context state targetUrl }
     }
     pageInfo { hasNextPage endCursor }
    } }
   } } }
  }
 }
}'''


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(*args):
    process = subprocess.run(['gh', 'api', *args], text=True, stdout=subprocess.PIPE)
    require(process.returncode == 0, 'required CI settings/check metadata API failed')
    return json.loads(process.stdout)


def app_id(value):
    require(value is None or (type(value) is int and value >= -1), 'invalid required app ID')
    return value if value and value > 0 else None


def requirement(context, app):
    require(isinstance(context, str) and bool(context), 'invalid required check context')
    return (context, app_id(app))


def classify(nodes):
    script = pathlib.Path(__file__).resolve().parents[1] / 'hooks/scripts/pr-checks-classify.sh'
    process = subprocess.run(['bash', str(script)], input=json.dumps({'statusCheckRollup': nodes}),
                             text=True, stdout=subprocess.PIPE)
    require(process.returncode == 0, 'CI classification failed')
    result = json.loads(process.stdout)
    require(result['state'] != 'unknown', 'unknown CI check state')
    return result


def main(owner_repo, pr, sha):
    owner, repo = owner_repo.split('/')
    require(bool(owner) and bool(repo) and re.fullmatch(r'[0-9a-fA-F]{40}', sha), 'invalid identity/SHA')
    require(pr.isdecimal() and int(pr) > 0, 'invalid PR number')
    checks, cursor, seen, baseline = [], None, set(), None
    while True:
        args = ['graphql', '-f', 'query=' + QUERY, '-f', 'owner=' + owner,
                '-f', 'repo=' + repo, '-F', 'pr=' + pr]
        if cursor is not None:
            args += ['-f', 'endCursor=' + cursor]
        page = api(*args)
        require(isinstance(page, dict) and not page.get('errors'), 'GraphQL settings response has errors')
        pull = page['data']['repository']['pullRequest']
        require(pull['headRefOid'] == sha, 'required CI metadata HEAD mismatch')
        base = pull['baseRefName']
        require(isinstance(base, str) and bool(base) and isinstance(pull['baseRef'], dict),
                'PR base/branch protection unavailable')
        protection = pull['baseRef']['branchProtectionRule']
        snapshot = (base, protection)
        require(baseline is None or baseline == snapshot, 'required CI settings changed during pagination')
        baseline = snapshot
        commits = pull['commits']['nodes']
        require(isinstance(commits, list) and len(commits) == 1 and commits[0]['commit']['oid'] == sha,
                'required CI commit metadata mismatch')
        rollup = commits[0]['commit']['statusCheckRollup']
        if rollup is None:
            require(cursor is None, 'check pagination disappeared')
            break
        contexts = rollup['contexts']
        require(isinstance(contexts['nodes'], list), 'invalid check page')
        checks.extend(contexts['nodes'])
        info = contexts['pageInfo']
        require(type(info['hasNextPage']) is bool, 'invalid check pagination')
        if not info['hasNextPage']:
            break
        cursor = info['endCursor']
        require(isinstance(cursor, str) and bool(cursor) and cursor not in seen, 'invalid check cursor')
        seen.add(cursor)

    required = set()
    if protection is not None:
        require(isinstance(protection, dict) and type(protection['requiresStatusChecks']) is bool,
                'invalid classic branch protection')
        if protection['requiresStatusChecks']:
            contexts, specs = protection['requiredStatusCheckContexts'], protection['requiredStatusChecks']
            require(isinstance(contexts, list) and isinstance(specs, list), 'invalid classic required checks')
            specified = set()
            for spec in specs:
                app = spec['app']
                require(app is None or isinstance(app, dict), 'invalid classic required app')
                required.add(requirement(spec['context'], None if app is None else app['databaseId']))
                specified.add(spec['context'])
            for context in contexts:
                entry = requirement(context, None)
                if context not in specified:
                    required.add(entry)
    pages = api('--paginate', '--slurp',
                f'repos/{quote(owner, safe="")}/{quote(repo, safe="")}/rules/branches/{quote(base, safe="")}?per_page=100')
    require(isinstance(pages, list) and bool(pages), 'invalid/empty rules pagination envelope')
    for rules in pages:
        require(isinstance(rules, list), 'invalid active branch rules page')
        for rule in rules:
            require(isinstance(rule, dict) and isinstance(rule.get('type'), str), 'invalid active rule')
            if rule['type'] == 'required_status_checks':
                specs = rule['parameters']['required_status_checks']
                require(isinstance(specs, list), 'invalid ruleset required checks')
                for spec in specs:
                    required.add(requirement(spec['context'], spec.get('integration_id')))

    all_result = classify(checks)
    required_nodes, optional_nodes, observed = [], [], set()
    for check in checks:
        kind = check['__typename']
        name = check.get('name') if kind == 'CheckRun' else check.get('context')
        candidates = [entry for entry in required if entry[0] == name]
        matches = []
        for entry in candidates:
            if entry[1] is None:
                matches.append(entry)
            elif kind == 'CheckRun':
                app = check['checkSuite']['app']
                require(isinstance(app, dict) and type(app['databaseId']) is int and app['databaseId'] > 0,
                        'required app metadata unavailable')
                if app['databaseId'] == entry[1]:
                    matches.append(entry)
        if matches:
            required_nodes.append(check)
            observed.update(matches)
        else:
            optional_nodes.append(check)
    missing = sorted(required - observed, key=lambda entry: (entry[0], entry[1] or 0))
    result, optional = classify(required_nodes), classify(optional_nodes)
    if missing:
        result['state'] = 'pending'
    result.update(warnings=optional['failed'], required_checks=result['checks'],
                  optional_checks=optional['checks'], all_state=all_result['state'],
                  checks=all_result['checks'], missing_required=[{'context': name, 'app_id': app} for name, app in missing],
                  commit_sha=sha, base_branch=base)
    print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 4, 'expected OWNER/REPO PR REVIEWED_SHA')
        main(*sys.argv[1:])
    except (ValueError, KeyError, TypeError, IndexError, OSError) as error:
        message = str(error)
        # GitHub display metadata may contain terminal control characters.
        message = ''.join(c if c >= ' ' and not '\x7f' <= c <= '\x9f' else ' ' for c in message)
        print('ERROR: required CI classification: ' + message, file=sys.stderr)
        sys.exit(1)
