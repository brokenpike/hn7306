"""Translate an .srt subtitle file with the local OpenAI-compatible LLM server.

Subtitles are sent in numbered chunks so the model sees the surrounding
dialogue; numbers and timestamps are copied from the input, never from the
model. With --via-english the text goes source -> English with --model, then
English -> target with --polish-model (NorMistral handles nb/nn/en only).

Defaults for the server and model come from local.llm in the NixOS config
(substituted when Nix builds this script).
"""

import argparse
import json
import re
import sys
import urllib.request

DEFAULT_URL = "@BASE_URL@"
DEFAULT_MODEL = "@MODEL@"

LINE_RE = re.compile(r"^\s*\[(\d+)\]\s*(.*)$")

SYSTEM = (
    "You translate film and TV subtitles from {source} to {target}. "
    "Each input line is '[n] text'. Reply with exactly one line per input "
    "line, same numbers, in the form '[n] translation', and nothing else. "
    "Translate the meaning naturally, as spoken dialogue, short enough to "
    "read as a subtitle. A line can be part of a sentence that continues on "
    "the next line; keep the pieces in order so they still read correctly. "
    "Keep names consistent. Never merge, split, skip or add lines."
)

NORMISTRAL_TARGETS = {
    "norwegian bokmål": "bokmål",
    "norwegian bokmal": "bokmål",
    "bokmål": "bokmål",
    "norwegian nynorsk": "nynorsk",
    "nynorsk": "nynorsk",
    "english": "engelsk",
}


def parse_srt(text):
    """Return a list of (index, timing, text) from an .srt file's contents."""
    text = text.lstrip("﻿").replace("\r\n", "\n").replace("\r", "\n")
    blocks = []
    for raw in re.split(r"\n\s*\n", text.strip()):
        lines = raw.split("\n")
        if len(lines) < 2 or "-->" not in lines[1]:
            continue
        body = " ".join(line.strip() for line in lines[2:] if line.strip())
        blocks.append((lines[0].strip(), lines[1].strip(), body))
    return blocks


def write_srt(blocks, path):
    with open(path, "w", encoding="utf-8") as f:
        for index, timing, text in blocks:
            f.write(f"{index}\n{timing}\n{text}\n\n")


def wrap(text, width):
    """At most two lines, split at the space nearest the middle."""
    if len(text) <= width or " " not in text:
        return text
    middle = len(text) // 2
    spaces = [i for i, c in enumerate(text) if c == " "]
    cut = min(spaces, key=lambda i: abs(i - middle))
    return text[:cut] + "\n" + text[cut + 1:]


def chat(url, model, messages, temperature):
    body = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "stream": False,
        # Qwen-style models: no thinking for translation. Others ignore it.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        url.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=900) as resp:
        reply = json.load(resp)
    return reply["choices"][0]["message"]["content"] or ""


def translate_chunk(args, items, source, target, context):
    """items: list of (n, text). Returns {n: translation}; splits on failure."""
    numbered = "\n".join(f"[{n}] {t}" for n, t in items)
    messages = [{"role": "system", "content": SYSTEM.format(source=source, target=target)}]
    if context:
        ctx = "\n".join(f"{s}  =>  {t}" for s, t in context)
        messages.append({
            "role": "user",
            "content": "Previous lines, already translated, for context only "
                       "(do not output them):\n" + ctx,
        })
        messages.append({"role": "assistant", "content": "Understood."})
    messages.append({"role": "user", "content": numbered})

    reply = chat(args.url, args.model, messages, args.temperature)
    found = {}
    for line in reply.splitlines():
        m = LINE_RE.match(line)
        if m:
            found[int(m.group(1))] = m.group(2).strip()
    wanted = [n for n, _ in items]
    if all(n in found and found[n] for n in wanted):
        return {n: found[n] for n in wanted}
    if len(items) == 1:
        n, t = items[0]
        print(f"  line {n}: no usable answer, kept the original", file=sys.stderr)
        return {n: found.get(n) or t}
    half = len(items) // 2
    print(f"  chunk of {len(items)} came back incomplete, retrying in halves",
          file=sys.stderr)
    result = translate_chunk(args, items[:half], source, target, context)
    result.update(translate_chunk(args, items[half:], source, target, context))
    return result


def translate_all(args, texts, source, target):
    """texts: list of strings. Returns translations in the same order."""
    items = list(enumerate(texts, start=1))
    out = {}
    context = []
    for start in range(0, len(items), args.chunk):
        chunk = items[start:start + args.chunk]
        print(f"{source} -> {target}: lines {chunk[0][0]}-{chunk[-1][0]} of {len(items)}",
              file=sys.stderr)
        result = translate_chunk(args, chunk, source, target, context)
        out.update(result)
        context = [(t, result[n]) for n, t in chunk][-args.context:]
    return [out[n] for n, _ in items]


def polish_normistral(args, texts, target):
    """English -> target with NorMistral: system message = target language."""
    lang = NORMISTRAL_TARGETS.get(target.lower())
    if lang is None:
        sys.exit(f"--polish-model NorMistral only does bokmål, nynorsk, english; not '{target}'")
    out = []
    for i, text in enumerate(texts, start=1):
        if i % 25 == 1:
            print(f"English -> {target} ({args.polish_model}): line {i} of {len(texts)}",
                  file=sys.stderr)
        out.append(chat(args.url, args.polish_model, [
            {"role": "system", "content": lang},
            {"role": "user", "content": text},
        ], 0).strip())
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("input", help="input .srt")
    p.add_argument("-o", "--output", help="output .srt (default: <input>.<target code>.srt)")
    p.add_argument("--source", default="Japanese", help="source language (default: Japanese)")
    p.add_argument("--target", default="Norwegian Bokmål",
                   help="target language (default: Norwegian Bokmål)")
    p.add_argument("--model", default=DEFAULT_MODEL, help=f"model (default: {DEFAULT_MODEL})")
    p.add_argument("--via-english", action="store_true",
                   help="translate to English with --model, then to the target with --polish-model")
    p.add_argument("--polish-model", default="normistral-11b-translate",
                   help="model for the English -> target step (default: normistral-11b-translate)")
    p.add_argument("--url", default=DEFAULT_URL, help=f"OpenAI-compatible base URL (default: {DEFAULT_URL})")
    p.add_argument("--chunk", type=int, default=40, help="subtitles per request (default: 40)")
    p.add_argument("--context", type=int, default=6,
                   help="previous lines sent as context (default: 6)")
    p.add_argument("--width", type=int, default=42,
                   help="wrap to two lines above this many characters (default: 42)")
    p.add_argument("--temperature", type=float, default=0.2)
    args = p.parse_args()

    with open(args.input, encoding="utf-8-sig") as f:
        blocks = parse_srt(f.read())
    if not blocks:
        sys.exit(f"no subtitles found in {args.input}")
    texts = [b[2] for b in blocks]

    if args.via_english:
        english = translate_all(args, texts, args.source, "English")
        result = polish_normistral(args, english, args.target)
    else:
        result = translate_all(args, texts, args.source, args.target)

    out = [(i, timing, wrap(t, args.width)) for (i, timing, _), t in zip(blocks, result)]
    code = {"norwegian bokmål": "nb", "norwegian nynorsk": "nn", "english": "en"}.get(
        args.target.lower(), "translated")
    path = args.output or re.sub(r"(\.[a-z]{2,3})?\.srt$", "", args.input) + f".{code}.srt"
    write_srt(out, path)
    print(f"wrote {len(out)} subtitles to {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
