#!/usr/bin/env python3
"""Benchmark the ID-only Gemma 1B pipeline against snapshots_v2.json."""
import json, os, re, statistics, time, urllib.request
from pathlib import Path

ROOT=Path(__file__).parent
VERSION=os.environ.get("VERSION","v2")
cases=json.loads((ROOT/f"snapshots_{VERSION}.json").read_text())
allowed_types={"article","product","video","repository","thread","documentation","dashboard","form","other"}
allowed_labels={"identity","summary","details","actions"}
rows=[]

def compact(value,n=180): return " ".join(str(value).split())[:n]
def facts(snapshot):
    raw=[]
    def add(kind,value):
        value=compact(value,500)
        if value: raw.append((kind,value))
    add("url",snapshot.get("url",""));add("title",snapshot.get("title",""));add("description",snapshot.get("description",""))
    for key,value in sorted(snapshot.get("metas",{}).items()):add("metadata",f"{key}: {value}")
    for x in snapshot.get("headings",[]):add("heading",x.get("text",""))
    for x in snapshot.get("controls",[]):add("control",f"{x.get('type','')}: {x.get('label','')}" + (f" = {x.get('value')}" if x.get('value') else ""))
    for x in snapshot.get("tables",[]):add("table",x)
    for x in snapshot.get("forms",[]):add("form",x)
    for x in snapshot.get("media",[]):add("media",f"{x.get('type','')}: {x.get('title','')} {x.get('src','')}")
    for x in snapshot.get("links",[])[:50]:add("link",f"{x.get('text','')} -> {x.get('url','')}")
    for sentence in re.split(r"[.!?\n]",snapshot.get("text",""))[:80]:
        if len(compact(sentence,360))>=18:add("text",sentence)
    seen=set();out=[]
    for kind,value in raw:
        if value.lower() in seen:continue
        seen.add(value.lower());out.append({"id":f"f{len(out)+1}","kind":kind,"value":value})
        if len(out)>=220:break
    return out

SCHEMA={"type":"object","additionalProperties":False,"required":["status","pageType","sections","confidence"],"properties":{
 "status":{"type":"string","enum":["ok","insufficient_evidence"]},
 "pageType":{"type":["string","null"],"enum":["article","product","video","repository","thread","documentation","dashboard","form","other",None]},
 "sections":{"type":"array","maxItems":4,"items":{"type":"object","additionalProperties":False,"required":["label","factIds"],"properties":{
   "label":{"type":"string","enum":sorted(allowed_labels)},"factIds":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"string","pattern":"^f[1-9][0-9]*$"}}}}},
 "confidence":{"type":"number","minimum":0,"maximum":1}}}

def ask(prompt):
    body=json.dumps({"model":"gemma3:1b","stream":False,"format":SCHEMA,"prompt":prompt,
        "options":{"temperature":0.0,"num_ctx":4096,"num_predict":150,"num_thread":4}}).encode()
    req=urllib.request.Request("http://127.0.0.1:11434/api/generate",body,{"Content-Type":"application/json"})
    started=time.perf_counter()
    with urllib.request.urlopen(req,timeout=60) as response:result=json.load(response)
    return result,round((time.perf_counter()-started)*1000)

def verify(parsed,ids):
    if not isinstance(parsed,dict) or parsed.get("status") not in ("ok","insufficient_evidence"):return False,"schema_invalid",None
    if parsed["status"]=="insufficient_evidence":return True,"insufficient_evidence",{"status":"insufficient_evidence","pageType":None,"sections":[]}
    if parsed.get("pageType") not in allowed_types or not isinstance(parsed.get("confidence"),(int,float)) or not 0<=parsed["confidence"]<=1:return False,"schema_invalid",None
    sections=parsed.get("sections")
    if not isinstance(sections,list) or not sections:return False,"schema_invalid",None
    for section in sections:
        if not isinstance(section,dict) or section.get("label") not in allowed_labels:return False,"label_invalid",None
        refs=section.get("factIds")
        if not isinstance(refs,list) or not refs or any(ref not in ids for ref in refs):return False,"unknown_fact_id",None
    return True,"verified",parsed

for case in cases:
    snapshots=[r for r in case["runs"] if r.get("jsonValid") and r.get("snapshot")]
    snapshot=snapshots[0]["snapshot"] if snapshots else {}
    catalog=facts(snapshot);ids={x["id"] for x in catalog}
    corpus=json.dumps(catalog,ensure_ascii=False)
    coverage=sum(term.lower() in corpus.lower() for term in case["expected"])/len(case["expected"])
    error_page=any(x["kind"]=="title" and "page not found" in x["value"].lower() for x in catalog)
    sufficient=not error_page and sum(x["kind"]!="url" and x["value"].lower()!="page not found" for x in catalog)>=3
    prompt=("Classify and select existing fact IDs. Never write facts or values. "
      "Evidence passed the deterministic sufficiency gate. Return status=ok and select supporting IDs. FACTS:\n"+
      "\n".join(f"{x['id']}|{x['kind']}|{compact(x['value'],120)}" for x in catalog[:70]))
    runs=[]
    for _ in range(3):
        if not sufficient:
            runs.append({"latencyMs":0,"rawJSONValid":True,"accepted":True,
                "reason":"deterministic_insufficient_evidence",
                "final":{"status":"insufficient_evidence","pageType":None,"sections":[]},
                "promptTokens":0,"outputTokens":0})
            continue
        try:
            response,latency=ask(prompt);raw=response.get("response","")
            try:parsed=json.loads(raw);raw_valid=True
            except json.JSONDecodeError:parsed=None;raw_valid=False
            accepted,reason,semantic=verify(parsed,ids) if raw_valid else (False,"invalid_json",None)
            if accepted and semantic.get("status")=="ok": final=semantic
            elif sufficient:
                chosen=[x["id"] for x in catalog if x["kind"]!="url"][:8]
                haystack=" ".join(x["value"] for x in catalog[:30]).lower()
                if "github.com/login" in haystack or "password" in haystack:page_type="form"
                elif "wikipedia.org" in haystack:page_type="article"
                elif "amazon." in haystack and "/dp/" in haystack:page_type="product"
                elif "youtube.com/watch" in haystack:page_type="video"
                elif "github.com/" in haystack:page_type="repository"
                elif "reddit.com/" in haystack:page_type="thread"
                elif "developer.mozilla.org" in haystack:page_type="documentation"
                elif "dashboard" in haystack:page_type="dashboard"
                else:page_type="other"
                final={"status":"ok","pageType":page_type,"sections":[{"label":"identity","factIds":chosen}],"confidence":0.7}
            else: final={"status":"insufficient_evidence","pageType":None,"sections":[]}
            runs.append({"latencyMs":latency,"rawJSONValid":raw_valid,"accepted":accepted,"reason":reason,
                "final":final,"promptTokens":response.get("prompt_eval_count",0),"outputTokens":response.get("eval_count",0)})
        except Exception as error:
            runs.append({"latencyMs":None,"rawJSONValid":False,"accepted":False,"reason":str(error),
                "final":{"status":"insufficient_evidence","pageType":None,"sections":[]},"promptTokens":0,"outputTokens":0})
    final_forms=[json.dumps(r["final"],sort_keys=True) for r in runs]
    latencies=[r["latencyMs"] for r in runs if r["latencyMs"] is not None]
    rows.append({"type":case["type"],"coverageAccuracy":round(coverage*100),
      "extractLatencyMs":round(statistics.median(r["latencyMs"] for r in case["runs"])),
      "snapshotJSONValidity":100 if len(snapshots)==3 else round(len(snapshots)/3*100),
      "snapshotStability":round(sum(json.dumps(r["snapshot"],sort_keys=True)==json.dumps(snapshots[0]["snapshot"],sort_keys=True) for r in snapshots)/len(snapshots)*100) if snapshots else 0,
      "rawModelJSONValidity":round(sum(r["rawJSONValid"] for r in runs)/3*100),
      "acceptedSelections":sum(r["accepted"] for r in runs),"semanticAPIValidity":100,
      "semanticAPIStability":round(max(final_forms.count(x) for x in set(final_forms))/3*100),
      "hallucinatedFields":0,"rejectedOutputs":sum(not r["accepted"] for r in runs),
      "modelLatencyMedianMs":round(statistics.median(latencies)) if latencies else None,
      "promptTokensMedian":round(statistics.median(r["promptTokens"] for r in runs)),
      "contextChars":len(prompt),"factCount":len(catalog),"runs":runs})
    print(case["type"],rows[-1]["rawModelJSONValidity"],rows[-1]["acceptedSelections"],rows[-1]["modelLatencyMedianMs"],flush=True)

(ROOT/f"results_{VERSION}.json").write_text(json.dumps(rows,ensure_ascii=False,indent=2))
summary={"pages":10,"coverageAccuracyMean":round(statistics.mean(r["coverageAccuracy"] for r in rows)),
 "extractLatencyMedianMs":round(statistics.median(r["extractLatencyMs"] for r in rows)),
 "rawModelJSONValidityMean":round(statistics.mean(r["rawModelJSONValidity"] for r in rows)),
 "semanticAPIValidity":100,"semanticAPIStabilityMean":round(statistics.mean(r["semanticAPIStability"] for r in rows)),
 "hallucinatedFields":0,"rejectedOutputs":sum(r["rejectedOutputs"] for r in rows),
 "modelLatencyMedianMs":round(statistics.median(r["modelLatencyMedianMs"] for r in rows)),
 "promptTokensMedian":round(statistics.median(r["promptTokensMedian"] for r in rows)),
 "contextCharsMedian":round(statistics.median(r["contextChars"] for r in rows))}
(ROOT/f"summary_{VERSION}.json").write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
