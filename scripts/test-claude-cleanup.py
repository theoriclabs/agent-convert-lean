#!/usr/bin/env python3
"""Converter noise stays metadata; literal text and execution status survive."""
import copy,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'cli'))
from claude_cleanup import clean
protocol={'protocol':'agent-convert.claude-carriers.v1'}
placeholder='[prior reasoning not retained as readable text: codex.reasoning]'
row={'type':'assistant','uuid':'a','parentUuid':None,'message':{'content':[{'type':'text','text':placeholder}]},'_agent_convert':{**protocol,'reasoning':[{'block':0,'source':{'kind':'unmodeled','label':'codex.reasoning','raw':{'encrypted_content':'opaque','summary':[]}}}]}}
error={'type':'user','uuid':'b','parentUuid':'a','message':{'content':[{'type':'tool_result','tool_use_id':'call','is_error':True,'content':[{'type':'text','text':'Script completed\nWall time 1 seconds\nOutput:\n'},{'type':'text','text':json.dumps({'chunk_id':'x','exit_code':1,'output':'JSONDecodeError: recorded failure'})}]}]},'_agent_convert':protocol}
literal={'type':'user','uuid':'c','parentUuid':'b','message':{'content':[{'type':'text','text':placeholder}]}}
original=copy.deepcopy([row,error,literal])
rows,archive=clean(original)
assert len(rows)==2 and len(archive)==2
assert rows[0]['parentUuid'] is None
result=rows[0]['message']['content'][0]
assert result['is_error'] is True and result['tool_use_id']=='call'
assert result['content']==[{'type':'text','text':'JSONDecodeError: recorded failure'}]
assert rows[1]['message']['content'][0]['text']==placeholder
assert original==[row,error,literal]
assert clean(rows)[0]==rows
print('Claude cleanup: no generated reasoning placeholders; exact metadata retained; graph, literal text, real failures preserved; idempotent.')
