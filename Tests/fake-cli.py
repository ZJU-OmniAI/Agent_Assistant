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
    if os.path.exists(os.path.join(fixture, "server-broken")):
        sys.exit(3)
    threads, waiting = {}, {}

    def reply(message, result):
        print(json.dumps({"id": message["id"], "result": result}), flush=True)

    def notify(method, params):
        print(json.dumps({"method": method, "params": params}), flush=True)

    def event(entry):
        with open(os.path.join(fixture, "codex-server.log"), "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    for line in sys.stdin:
        message = json.loads(line)
        method, params = message.get("method"), message.get("params") or {}
        if "id" not in message:
            continue  # notifications such as "initialized"
        if method == "initialize":
            reply(message, {})
        elif method == "config/read":
            reply(message, {"config": {"mcp_servers": {"fixture_mcp": {"command": "true"}}}, "origins": {}})
        elif method == "model/list":
            if params.get("cursor") == "page-2":
                result = {"data": [{"model": "gpt-two", "displayName": "GPT Two"}], "nextCursor": None}
            else:
                result = {"data": [{"model": "gpt-fixture", "displayName": "GPT Fixture", "isDefault": True,
                                    "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "high"}],
                                    "serviceTiers": [{"id": "priority", "name": "Fast", "description": "1.5x speed, increased usage"},
                                                     {"id": "Bad Tier!", "name": "x"}]},
                                   {"model": "hidden-one", "hidden": True}], "nextCursor": "page-2"}
            reply(message, result)
        elif method == "thread/start":
            tid = "thread-%d-%d" % (os.getpid(), len(threads) + 1)
            threads[tid] = params
            event({"threadStart": tid})
            reply(message, {"thread": {"id": tid}})
        elif method == "turn/start":
            tid, turn_id = params["threadId"], "turn-" + params["threadId"]
            text = params["input"][0]["text"]
            log({"mode": "server", "args": args, "threadId": tid, "thread": threads.get(tid),
                 "turn": {k: v for k, v in params.items() if k != "input"}, "stdin": text})
            reply(message, {"turn": {"id": turn_id, "status": "inProgress", "items": []}})
            if json.loads(text[text.index("{"):])["messages"][-1]["content"] == "等待取消":
                open(os.path.join(fixture, "started"), "w").close()
                waiting[tid] = turn_id
                continue
            reply_text, error = answer(text)
            if error:
                detail = {"message": "You've hit your usage limit." if error == "quota" else error,
                          "codexErrorInfo": "usageLimitExceeded" if error == "quota" else "other"}
                notify("error", {"threadId": tid, "turnId": turn_id, "willRetry": False, "error": detail})
                notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "status": "failed", "items": [], "error": detail}})
            else:
                notify("item/completed", {"threadId": tid, "turnId": turn_id, "completedAtMs": 0,
                                          "item": {"type": "agentMessage", "id": "m1", "text": reply_text}})
                notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "status": "completed", "items": []}})
        elif method == "turn/interrupt":
            event({"interrupt": params.get("threadId")})
            reply(message, {})
            if params.get("threadId") in waiting:
                notify("turn/completed", {"threadId": params["threadId"],
                                          "turn": {"id": waiting.pop(params["threadId"]), "status": "interrupted", "items": []}})
        elif method == "thread/unsubscribe":
            event({"unsubscribe": params.get("threadId")})
            reply(message, {"status": "unsubscribed"})
        else:
            print(json.dumps({"id": message["id"], "error": {"code": -32601, "message": "unknown method"}}), flush=True)
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
