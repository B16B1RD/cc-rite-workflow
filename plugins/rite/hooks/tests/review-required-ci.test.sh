#!/bin/bash
# Final required CI policy through persistence and unchanged receipt/Ready gates.
set -euo pipefail
PLUGIN_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$PLUGIN_ROOT" <<'PY'
import copy,json,os,pathlib,subprocess,sys,tempfile
plugin=pathlib.Path(sys.argv[1]); checks=0

def check(condition,label):
 global checks
 assert condition,label
 checks+=1

def dump(path,data):path.write_text(json.dumps(data))

with tempfile.TemporaryDirectory(prefix='rite-required-ci-') as tmp:
 root=pathlib.Path(tmp); (root/'bin').mkdir()
 env=dict(os.environ)
 for key in ('CODEX_THREAD_ID','GROK_SESSION_ID','CLAUDE_SESSION_ID','CLAUDE_CODE_SESSION_ID','RITE_HOST','RITE_STATE_ROOT','GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE'):
  env.pop(key,None)
 env.update(PATH=str(root/'bin')+os.pathsep+env['PATH'],CI_FIXTURE=tmp,RITE_HOST='claude',CLAUDE_CODE_SESSION_ID='required-ci-test',RITE_STATE_ROOT=tmp,TMPDIR=tmp)
 gh=root/'bin/gh'
 gh.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
r=pathlib.Path(os.environ['CI_FIXTURE']); a=sys.argv[1:]
with (r/'calls').open('a') as f:f.write(json.dumps(a)+'\\n')
if a[0]=='pr':
 p=json.loads((r/'pr.json').read_text())
 print(p['headRefOid'] if '--jq' in a else json.dumps(p)); sys.exit(0)
file='graphql-next.json' if a[1]=='graphql' and 'endCursor=next' in a else 'graphql.json' if a[1]=='graphql' else 'rules.json'
if (r/(file+'.fail')).exists(): print('fixture: settings API denied',file=sys.stderr); sys.exit(1)
print((r/file).read_text())
''');gh.chmod(0o755)
 sleep=root/'bin/sleep';sleep.write_text('#!/bin/bash\necho wait >> "$CI_FIXTURE/waits"\n');sleep.chmod(0o755)
 def run(args):return subprocess.run(list(map(str,args)),cwd=root,env=env,text=True,capture_output=True)
 def success(args):
  result=run(args);check(result.returncode==0,repr(args)+'\n'+result.stderr+'\n'+result.stdout);return result
 success(['git','init','-q'])
 success(['git','-c','user.email=test@example.com','-c','user.name=test','commit','-q','--allow-empty','-m','fixture'])
 sha=success(['git','rev-parse','HEAD']).stdout.strip()
 def node(name,state='SUCCESS',app=15368):
  return dict(__typename='CheckRun',name=name,status='IN_PROGRESS' if state=='PENDING' else 'COMPLETED',conclusion=None if state=='PENDING' else state,detailsUrl='https://example.test/jobs/'+name,checkSuite=dict(app=dict(databaseId=app)))
 def setup(nodes=None,contexts=None,enabled=True,rules=None,specs=None):
  for file in ('graphql.json.fail','rules.json.fail','graphql-next.json','waits','calls'):
   (root/file).unlink(missing_ok=True)
  nodes=nodes if nodes is not None else [node('required'),node('advisory','FAILURE')]
  contexts=contexts if contexts is not None else ['required']
  dump(root/'pr.json',dict(headRefOid=sha,statusCheckRollup=nodes))
  pull=dict(headRefOid=sha,baseRefName='release/a',baseRef=dict(branchProtectionRule=dict(requiresStatusChecks=enabled,requiredStatusCheckContexts=contexts,requiredStatusChecks=specs or [])),commits=dict(nodes=[dict(commit=dict(oid=sha,statusCheckRollup=dict(contexts=dict(nodes=nodes,pageInfo=dict(hasNextPage=False,endCursor=None)))))]))
  dump(root/'graphql.json',dict(data=dict(repository=dict(pullRequest=pull))))
  dump(root/'rules.json',rules if rules is not None else [[]])
  content=dict(schema_version='1.1.0',pr_number=71,timestamp='__RITE_TS_PLACEHOLDER_7f3a9b2c__',commit_sha=sha,findings=[],non_blocking_findings=[],guardrail_audit_log=[],acceptance_criteria=[dict(id='AC-1',status='satisfied',evidence='fixture => pass',finding_id=None)])
  dump(root/'result.json',content)
  success(['bash',plugin/'scripts/review-measured-gate.sh','--input',root/'result.json','--reject-preset-verification'])
 def gate(ok):
  before=(root/'result.json').read_bytes()
  result=run(['bash',plugin/'scripts/pr-review-step.sh','ci-completion-check','--owner-repo','owner/repo','--pr','71','--input',root/'result.json','--wait-seconds','1','--poll-seconds','1'])
  check((result.returncode==0)==ok,'CI gate rc: '+result.stderr+result.stdout)
  if ok:check('REVIEW_CI_FINAL=passed' in result.stdout,'passed marker')
  else:
   check('REVIEW_CI_FINAL=passed' not in result.stdout,'no false pass')
   check((root/'result.json').read_bytes()==before,'failure never saves CI JSON')
  return result
 setup();gate(True)
 content=json.loads((root/'result.json').read_text())
 check(content['verdict']=='mergeable' and content['measured_gate']['blocking']==0,'optional failure leaves measured zero blocking')
 check(content['ci_status']['warnings'][0]==dict(name='advisory',status='COMPLETED',conclusion='FAILURE',url='https://example.test/jobs/advisory'),'warning proof persisted')
 check(not (root/'waits').exists(),'optional failure no wait')
 calls=[json.loads(line) for line in (root/'calls').read_text().splitlines()]
 check(any('repos/owner/repo/rules/branches/release%2Fa?per_page=100' in call and '--paginate' in call and '--slurp' in call for call in calls),'base encoded and all rules pages requested')
 setup([node('required'),node('advisory','PENDING')]);gate(True);check(not (root/'waits').exists(),'optional pending no wait')
 setup([node('required','FAILURE'),node('advisory','PENDING')]);gate(False);check(not (root/'waits').exists(),'required failure does not wait on optional pending')
 for source in ('graphql.json','rules.json'):
  setup();(root/(source+'.fail')).touch();result=gate(False)
  check('required_set_unavailable' in result.stdout and 'API denied' in result.stderr,source+' fails loud')
  setup();(root/source).write_text('{}');gate(False)
 setup();g=json.loads((root/'graphql.json').read_text());g['errors']=[dict(message='denied')];dump(root/'graphql.json',g);gate(False)
 setup([],[],rules=[[]]);gate(True);check(json.loads((root/'result.json').read_text())['ci_status']['state']=='none','confirmed empty set succeeds')
 setup([node('stale','FAILURE')],['stale'],enabled=False);gate(True)
 setup([node('required'),node('second','FAILURE')],rules=[[],[dict(type='required_status_checks',parameters=dict(required_status_checks=[dict(context='second',integration_id=None)]))]])
 gate(False)
 setup([node('other')]);result=gate(False);check('reason=timeout' in result.stdout and (root/'waits').exists(),'missing required waits then stops')
 setup([node('required','PENDING')]);gate(False)
 spec=[dict(context='required',app=dict(databaseId=15368))]
 setup([node('required','SUCCESS',15368),node('required','FAILURE',1)],specs=spec);gate(True)
 check(len(json.loads((root/'result.json').read_text())['ci_status']['warnings'])==1,'wrong app failure optional')
 setup([node('required','SUCCESS',1)],specs=spec);gate(False)
 setup(specs=spec);g=json.loads((root/'graphql.json').read_text());del g['data']['repository']['pullRequest']['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts']['nodes'][0]['checkSuite'];dump(root/'graphql.json',g);gate(False)
 setup();g=json.loads((root/'graphql.json').read_text());g['data']['repository']['pullRequest']['headRefOid']='b'*40;dump(root/'graphql.json',g);gate(False)
 setup();g=json.loads((root/'graphql.json').read_text());g['data']['repository']['pullRequest']['baseRef']['branchProtectionRule']=None;dump(root/'graphql.json',g);gate(True)
 check(json.loads((root/'result.json').read_text())['ci_status']['state']=='none','successful null classic protection is explicit absence')
 setup([node('required'),dict(__typename='StatusContext',context='advisory',state='FAILURE',targetUrl='https://example.test/status')]);gate(True)
 check(json.loads((root/'result.json').read_text())['ci_status']['warnings'][0]['conclusion']=='FAILURE','legacy optional StatusContext warning')
 setup();g=json.loads((root/'graphql.json').read_text());nextpage=copy.deepcopy(g)
 c=g['data']['repository']['pullRequest']['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts'];c.update(nodes=[node('required')],pageInfo=dict(hasNextPage=True,endCursor='next'))
 c=nextpage['data']['repository']['pullRequest']['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts'];c.update(nodes=[node('advisory','FAILURE')])
 dump(root/'graphql.json',g);dump(root/'graphql-next.json',nextpage);gate(True)
 check(len(json.loads((root/'result.json').read_text())['ci_status']['checks'])==2,'GraphQL checks include later pages')
 setup(rules=[[dict(type='required_status_checks',parameters=dict(required_status_checks=[dict(context='required')]))]])
 gate(True)
 # Compose real review-finish receipt and the unchanged Ready gates after optional failure.
 setup()
 hooks=plugin/'hooks'
 success(['bash',hooks/'flow-state.sh','set','--phase','pr','--pr','71','--next','review'])
 dump(root/'selection.json',['code-quality-reviewer'])
 success(['bash',hooks/'flow-state.sh','review-start','--selection',root/'selection.json'])
 statepath=root/'.rite/sessions/required-ci-test.flow-state'
 context=json.loads(statepath.read_text())['review_cycle']['review_context']
 content=json.loads((root/'result.json').read_text());content.update(reviewers=['code-quality-reviewer'],review_context=context);dump(root/'result.json',content)
 gate(True)
 raw=root/'raw.md';raw.write_text('### 評価: 可\n### 所見\nChecked.\n### 指摘事項\nNone.\n### 監査ログ\nNone.\n')
 record=dict(reviewer='code-quality-reviewer',agent_id='fixture-child',status='completed',started_at='2026-01-01T00:00:00Z',ended_at='2026-01-01T00:01:00Z',output_file=str(raw),review_context=context)
 dump(root/'manifest.json',dict(schema_version=1,parent_agent_id='required-ci-test',selected_reviewers=['code-quality-reviewer'],reviewers=[record],review_context=context))
 success(['bash',hooks/'flow-state.sh','review-finish','--manifest',root/'manifest.json','--content-file',root/'result.json'])
 saved=list((root/'.rite/review-results').glob('71-*.json'));check(len(saved)==1,'saved result exists')
 saved_json=json.loads(saved[0].read_text());check(saved_json['ci_status']['warnings'][0]['name']=='advisory','warning survives receipt persistence')
 ready=['bash',hooks/'scripts/ready-reviewed-head-gate.sh','--pr','71','--repo','owner/repo','--plugin-root',plugin]
 success(ready)
 success(['bash',hooks/'flow-state.sh','set','--phase','ready','--next','merge'])
 check(json.loads(statepath.read_text())['phase']=='ready','phase ready via valid receipt')
 saved_json['ci_status']['warnings']=[];dump(saved[0],saved_json)
 check(run(['bash',hooks/'flow-state.sh','review-finish','--manifest',root/'manifest.json','--content-file',root/'result.json']).returncode!=0,'receipt replay rejects different saved content')
print('PASS:',checks,'FAIL: 0')
PY
