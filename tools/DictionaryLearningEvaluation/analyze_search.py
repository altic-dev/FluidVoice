import argparse, json, collections
from pathlib import Path
parser=argparse.ArgumentParser(description="Compare text and acoustic recovery on reference-aligned trials.")
parser.add_argument("trials",type=Path)
parser.add_argument("output",type=Path)
args=parser.parse_args()
trials=json.loads(args.trials.read_text())
counts={name:collections.Counter() for name in ['text','audio70','combined_fallback']}
errors=[]
for t in trials:
    text={i for i,w in enumerate(t['words']) if w['text']==t['known']}
    audio=set(); combined=set()
    for hit in t['hits']:
        indices=hit['indices']
        if not indices: continue
        audio.update(indices)
        known=' '.join(t['words'][i]['text'] for i in indices)==t['known']
        if hit['score'] >= (.7 if known else .85): combined.update(indices)
    combined.update(text)
    for name,pred in [('text',text),('audio70',audio),('combined_fallback',combined)]:
        for i,w in enumerate(t['words']):
            if 'reference' not in w: continue
            target=w['reference']==t['target']; accepted=i in pred
            counts[name]['tp' if target and accepted else 'fn' if target else 'fp' if accepted else 'tn']+=1
            if accepted and not target: errors.append(dict(mode=name,target=t['target'],language=t['language'],clip=t['clip'],text=w['text'],reference=w['reference']))
result={'trials':len(trials),'targets':len(set((t['language'],t['target']) for t in trials)),'counts':counts,'errors':errors}
args.output.write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
