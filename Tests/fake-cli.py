#!/usr/bin/env python3
"""Stands in for the Claude Code and Codex CLIs. Behaviour follows the file name."""
import json
import os
import subprocess
import sys
import time

name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
fixture = os.environ["FIXTURE_DIR"]


def log(entry):
    with open(os.path.join(fixture, name + ".log"), "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def answer(prompt):
    """Reply to the newest question in the request, like a model would."""
    start = prompt.index("{")
    messages = json.loads(prompt[start:])["messages"]
    question = messages[-1]["content"]
    if "触发额度" in question:
        return None, "quota"
    if question == "等待取消":
        child = subprocess.Popen(["sleep", "30"])
        with open(os.path.join(fixture, "grandchild.pid"), "w") as f:
            f.write(str(child.pid))
        open(os.path.join(fixture, "started"), "w").close()
        child.wait()
        return "不应到达", None
    if question == "请重试":
        marker = os.path.join(fixture, "retried")
        if not os.path.exists(marker):
            open(marker, "w").close()
            return None, "fixture failure"
        return "重试成功", None
    replies = {"请解释": "解释成功", "继续": "继续成功"}
    return replies.get(question, "动作上的分布。"), None


if args[:1] == ["--version"]:
    print("99.0.0 (fixture)" if name == "claude" else "codex-cli 99.0.0")
    sys.exit(0)

if name == "claude":
    if args[:2] == ["auth", "status"]:
        print(json.dumps({"loggedIn": not os.path.exists(os.path.join(fixture, "logged-out"))}))
        sys.exit(0)
    if "--input-format" in args:
        sys.stdin.readline()
        print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
        print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": "models", "response": {
            "models": [{"value": "default", "displayName": "Default"},
                       {"value": "sonnet", "displayName": "Sonnet Fixture", "supportsEffort": True,
                        "supportedEffortLevels": ["low", "high", "bogus"]},
                       {"value": "haiku", "displayName": "Haiku Fixture", "supportsEffort": False}]}}}), flush=True)
        time.sleep(20)  # The catalog reader must stop us once it has the answer.
        sys.exit(0)
    prompt = sys.stdin.read()
    log({"args": args, "stdin": prompt})
    text, error = answer(prompt)
    if error == "quota":
        print(json.dumps({"type": "result", "is_error": True,
                          "result": "You've hit your weekly usage limit · resets 5pm (Asia/Shanghai)"}))
        sys.exit(1)
    if error:
        print(json.dumps({"type": "result", "is_error": True, "result": error}))
        sys.exit(1)
    print(json.dumps({"type": "result", "is_error": False, "result": text}))
    sys.exit(0)

# codex
if args[:2] == ["login", "status"]:
    print("Logged in using ChatGPT")
    sys.exit(0)
if args[:1] == ["app-server"]:
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("method") == "initialize":
            print(json.dumps({"id": 1, "result": {}}), flush=True)
        elif message.get("method") == "model/list":
            if message["params"].get("cursor") == "page-2":
                result = {"data": [{"model": "gpt-two", "displayName": "GPT Two"}], "nextCursor": None}
            else:
                result = {"data": [{"model": "gpt-fixture", "displayName": "GPT Fixture", "isDefault": True,
                                    "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "high"}],
                                    "serviceTiers": [{"id": "priority", "name": "Fast", "description": "1.5x speed, increased usage"},
                                                     {"id": "Bad Tier!", "name": "x"}]},
                                   {"model": "hidden-one", "hidden": True}], "nextCursor": "page-2"}
            print(json.dumps({"id": 2, "result": result}), flush=True)
    sys.exit(0)
if args[:1] == ["exec"]:
    prompt = sys.stdin.read()
    log({"args": args, "stdin": prompt})
    output = args[args.index("-o") + 1]
    print(json.dumps({"type": "thread.started"}))
    text, error = answer(prompt)
    if error:
        print(json.dumps({"type": "turn.failed", "error": {"message": "You've hit your usage limit."}}))
        sys.exit(1)
    with open(output, "w") as f:
        f.write(text)
    print(json.dumps({"type": "turn.completed"}))
    sys.exit(0)
sys.exit(2)
