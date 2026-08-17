#!/usr/bin/env python3
"""Score the WebKit snapshots in snapshots.json against local gemma3:1b."""
import json, statistics, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).parent
cases = json.loads((ROOT / "snapshots.json").read_text())
rows = []

def ask(prompt):
    body = json.dumps({"model":"gemma3:1b", "stream":False, "format":"json",
        "prompt":prompt, "options":{"temperature":0.1,"num_ctx":4096,"num_predict":180,
                                      "num_thread":4}}).encode()
    request = urllib.request.Request("http://127.0.0.1:11434/api/generate", body,
                                     {"Content-Type":"application/json"})
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    return result, (time.perf_counter()-started)*1000

for case in cases:
    valid_snapshots = [r for r in case["runs"] if r.get("jsonValid") and r.get("snapshot")]
    snapshot = valid_snapshots[0]["snapshot"] if valid_snapshots else {}
    corpus = json.dumps(snapshot, ensure_ascii=False)
    expected = case["expected"]
    accuracy = sum(term.lower() in corpus.lower() for term in expected) / len(expected)
    snapshot_stability = 0
    if valid_snapshots:
        canonical = [json.dumps(r["snapshot"], ensure_ascii=False, sort_keys=True) for r in valid_snapshots]
        snapshot_stability = sum(x == canonical[0] for x in canonical) / len(canonical)
    compact = {"url":snapshot.get("url"), "title":snapshot.get("title"),
        "description":snapshot.get("description"), "text":snapshot.get("text","")[:3500],
        "headings":snapshot.get("headings",[])[:20], "controls":snapshot.get("controls",[])[:30],
        "structuredData":snapshot.get("structuredData",[])[:1]}
    prompt = ("Return strict JSON: {pageType,title,primaryEntity,fields:[{name,value,evidence}],confidence}. "
              "Use null when absent. Evidence must be an exact quote from SNAPSHOT. Do not guess. "
              f"Expected category: {case['type']}. SNAPSHOT={json.dumps(compact, ensure_ascii=False)}")
    runs = []
    for _ in range(3):
        try:
            response, latency = ask(prompt)
            raw = response.get("response", "")
            try: parsed, valid = json.loads(raw), True
            except json.JSONDecodeError: parsed, valid = None, False
            hallucinations = 0
            checked = 0
            if valid and isinstance(parsed.get("fields"), list):
                for field in parsed["fields"]:
                    if field.get("value") is not None:
                        checked += 1
                        evidence = field.get("evidence")
                        if not evidence or evidence not in corpus: hallucinations += 1
            runs.append({"latencyMs":round(latency), "valid":valid, "parsed":parsed,
                "hallucinations":hallucinations, "checkedFields":checked,
                "promptTokens":response.get("prompt_eval_count",0), "outputTokens":response.get("eval_count",0)})
        except Exception as error:
            runs.append({"latencyMs":None,"valid":False,"error":str(error),"hallucinations":0,
                         "checkedFields":0,"promptTokens":0,"outputTokens":0,"parsed":None})
    identities = [json.dumps([r["parsed"].get("pageType"), r["parsed"].get("primaryEntity")],
                             ensure_ascii=False, sort_keys=True)
                  for r in runs if r["valid"]]
    model_stability = (max(identities.count(x) for x in set(identities))/len(identities)) if identities else 0
    latencies = [r["latencyMs"] for r in runs if r["latencyMs"] is not None]
    rows.append({"type":case["type"], "url":case["url"], "title":snapshot.get("title", ""),
        "coverageAccuracy":round(accuracy*100), "extractLatencyMs":round(statistics.median(r["latencyMs"] for r in case["runs"])),
        "snapshotStability":round(snapshot_stability*100), "jsonValidity":round(sum(r["valid"] for r in runs)/3*100),
        "modelStability":round(model_stability*100), "hallucinatedFields":sum(r["hallucinations"] for r in runs),
        "checkedFields":sum(r["checkedFields"] for r in runs), "modelLatencyMedianMs":round(statistics.median(latencies)) if latencies else None,
        "promptTokensMedian":round(statistics.median(r["promptTokens"] for r in runs)),
        "contextChars":len(corpus), "loadMs":case["loadMs"], "runs":runs})
    print(case["type"], rows[-1]["jsonValidity"], rows[-1]["modelLatencyMedianMs"], flush=True)

(ROOT / "results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
lat = sorted(r["modelLatencyMedianMs"] for r in rows if r["modelLatencyMedianMs"] is not None)
summary = {"pages":len(rows), "coverageAccuracyMean":round(statistics.mean(r["coverageAccuracy"] for r in rows)),
    "extractLatencyMedianMs":round(statistics.median(r["extractLatencyMs"] for r in rows)),
    "jsonValidityMean":round(statistics.mean(r["jsonValidity"] for r in rows)),
    "modelStabilityMean":round(statistics.mean(r["modelStability"] for r in rows)),
    "hallucinatedFields":sum(r["hallucinatedFields"] for r in rows),
    "checkedFields":sum(r["checkedFields"] for r in rows),
    "modelLatencyMedianMs":round(statistics.median(lat)), "modelLatencyP95Ms":lat[-1]}
(ROOT / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
