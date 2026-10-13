"""デモ専用の負荷生成ツール。

- compare: 同じリクエスト列を複数ターゲットへミラーリングし、TTFT とテナント×Pod の偏りを並べて表示
- single : 1 リクエストだけ送り、どの Pod が処理したか・TTFT を表示（Step 3 用）
"""

from __future__ import annotations

import asyncio
import csv
import json
import random
import statistics
import time
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Annotated

import httpx
import typer
from rich.console import Console, Group
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

app = typer.Typer(add_completion=False, no_args_is_help=True)
console = Console()

MODEL = "demo-llm"
POD_HEADER = "x-inference-pod"

# sim のダミートークナイザは正規表現で単語・記号を数えるので、単語数 ≒ トークン数になる
_VOCAB = (
    "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november "
    "oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu cluster node "
    "pod service gateway route policy tenant invoice ledger shipment order customer account "
    "region zone volume network subnet router balancer cache token prompt model engine queue"
).split()

_QUESTIONS = [
    "Summarize the latest status.",
    "What should I check first?",
    "List three risks.",
    "Explain this in one sentence.",
    "Draft a short reply.",
    "What changed since yesterday?",
    "Give me the next action.",
    "Is anything blocked?",
]


def tenant_system_prompt(tenant: int, n_tokens: int) -> str:
    """テナント固有の長いシステムプロンプト（シード固定で決定的に生成）。"""
    rng = random.Random(10_000 + tenant)
    words = [f"tenant{tenant}"] + [rng.choice(_VOCAB) for _ in range(max(1, n_tokens - 1))]
    return " ".join(words)


def short_pod(pod: str) -> str:
    """Pod 名の末尾（ReplicaSet ハッシュ + ランダム部）だけ表示する。"""
    parts = pod.split("-")
    return "-".join(parts[-2:]) if len(parts) >= 2 else pod


@dataclass
class Result:
    ts: float
    target: str
    tenant: int
    pod: str
    ttft_ms: float | None
    e2e_ms: float | None
    status: str
    request_id: str


@dataclass
class TargetStats:
    name: str
    results: list[Result] = field(default_factory=list)
    errors: int = 0
    inflight: int = 0

    def ok(self, window_s: float | None = None) -> list[Result]:
        now = time.time()
        return [
            r
            for r in self.results
            if r.status == "200" and r.ttft_ms is not None and (window_s is None or now - r.ts <= window_s)
        ]

    def ttft_quantiles(self, window_s: float | None = 60.0) -> tuple[float | None, float | None]:
        vals = sorted(r.ttft_ms for r in self.ok(window_s) if r.ttft_ms is not None)
        if not vals:
            return None, None
        p50 = statistics.median(vals)
        p95 = vals[min(len(vals) - 1, int(round(0.95 * (len(vals) - 1))))]
        return p50, p95

    def matrix(self, window_s: float | None = None) -> dict[int, dict[str, int]]:
        m: dict[int, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        for r in self.ok(window_s):
            m[r.tenant][r.pod] += 1
        return m

    def concentration(self, window_s: float | None = None) -> float | None:
        """テナントごとに「最も多く当たった Pod の割合」を平均（1.0 = 完全に固定、1/Pod数 = ばらばら）。"""
        m = self.matrix(window_s)
        shares = [max(row.values()) / sum(row.values()) for row in m.values() if sum(row.values()) > 0]
        return statistics.mean(shares) if shares else None


async def send_one(
    client: httpx.AsyncClient,
    url: str,
    target: str,
    tenant: int,
    system_prompt: str,
    question: str,
    max_tokens: int,
    request_id: str,
) -> Result:
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": question},
        ],
        "max_tokens": max_tokens,
        "stream": True,
    }
    start = time.perf_counter()
    ts = time.time()
    ttft = None
    pod = "?"
    try:
        async with client.stream(
            "POST",
            f"{url.rstrip('/')}/v1/chat/completions",
            json=body,
            headers={"x-request-id": request_id},
        ) as resp:
            pod = resp.headers.get(POD_HEADER, "?")
            if resp.status_code != 200:
                await resp.aread()
                return Result(ts, target, tenant, pod, None, None, str(resp.status_code), request_id)
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                if ttft is None:
                    ttft = (time.perf_counter() - start) * 1000
                if line.strip() == "data: [DONE]":
                    break
        e2e = (time.perf_counter() - start) * 1000
        return Result(ts, target, tenant, pod, ttft, e2e, "200", request_id)
    except httpx.HTTPError as e:
        return Result(ts, target, tenant, pod, None, None, type(e).__name__, request_id)


def fmt_ms(v: float | None) -> str:
    return "-" if v is None else f"{v:,.0f} ms"


def render_target(stats: TargetStats, tenants: int, elapsed: float) -> Panel:
    p50, p95 = stats.ttft_quantiles(60)
    conc = stats.concentration(60)
    ok_all = stats.ok()
    thr = len(ok_all) / elapsed if elapsed > 0 else 0.0

    summary = Table.grid(padding=(0, 2))
    summary.add_column(style="dim")
    summary.add_column(justify="right", style="bold")
    summary.add_row("TTFT p50 (直近60s)", fmt_ms(p50))
    summary.add_row("TTFT p95 (直近60s)", fmt_ms(p95))
    summary.add_row("成功 / エラー", f"{len(ok_all)} / {stats.errors}")
    summary.add_row("スループット", f"{thr:.2f} req/s")
    summary.add_row("処理中", str(stats.inflight))
    summary.add_row("テナント固定度 (直近60s)", "-" if conc is None else f"{conc:.0%}")

    m = stats.matrix(60)
    pods = sorted({p for row in m.values() for p in row})
    heat = Table(title="テナント × Pod（直近60s のリクエスト数）", title_style="dim", expand=False, show_lines=False)
    heat.add_column("tenant", style="dim")
    for p in pods:
        heat.add_column(short_pod(p), justify="right")
    for t in range(tenants):
        row = m.get(t, {})
        total = sum(row.values())
        cells = []
        for p in pods:
            n = row.get(p, 0)
            share = n / total if total else 0
            # 割合が大きいほど濃い色
            if share >= 0.75:
                style = "bold white on dark_green"
            elif share >= 0.5:
                style = "white on green4"
            elif share >= 0.25:
                style = "black on dark_sea_green"
            elif n > 0:
                style = "dim"
            else:
                style = "grey30"
            cells.append(Text(str(n) if n else "·", style=style))
        heat.add_row(f"t{t}", *cells)

    return Panel(Group(summary, Text(""), heat), title=f"[bold]{stats.name}[/bold]", border_style="cyan")


def parse_targets(targets: list[str]) -> list[tuple[str, str]]:
    out = []
    for t in targets:
        if "=" in t:
            name, url = t.split("=", 1)
        else:
            name, url = t.rstrip("/").split("/")[-1], t
        out.append((name, url))
    return out


@app.command()
def compare(
    target: Annotated[list[str], typer.Option(help="name=URL（複数指定）。URL は /v1/chat/completions の手前まで")],
    tenants: int = 8,
    prompt_tokens: int = 4000,
    rps: float = 4.0,
    duration: int = 300,
    max_tokens: int = 64,
    seed: int = 42,
    out_dir: Path = Path("out"),
    summary_json: Annotated[Path | None, typer.Option(help="終了時にサマリを JSON で書き出す（preflight 用）")] = None,
    no_live: bool = typer.Option(False, help="ライブ表示を無効化（CI / ログ用）"),
) -> None:
    """同じリクエスト列を全ターゲットへ同時に送り、TTFT と Pod の偏りを比較する。"""
    asyncio.run(
        _compare(parse_targets(target), tenants, prompt_tokens, rps, duration, max_tokens, seed, out_dir, summary_json, no_live)
    )


async def _compare(
    targets: list[tuple[str, str]],
    tenants: int,
    prompt_tokens: int,
    rps: float,
    duration: int,
    max_tokens: int,
    seed: int,
    out_dir: Path,
    summary_json: Path | None,
    no_live: bool,
) -> None:
    rng = random.Random(seed)
    prompts = [tenant_system_prompt(t, prompt_tokens) for t in range(tenants)]
    stats = {name: TargetStats(name) for name, _ in targets}
    tasks: set[asyncio.Task] = set()
    limits = httpx.Limits(max_connections=512, max_keepalive_connections=128)
    timeout = httpx.Timeout(120.0, connect=10.0)
    start = time.time()

    async def fire(client: httpx.AsyncClient, name: str, url: str, tenant: int, question: str, rid: str) -> None:
        st = stats[name]
        st.inflight += 1
        try:
            r = await send_one(client, url, name, tenant, prompts[tenant], question, max_tokens, rid)
        finally:
            st.inflight -= 1
        st.results.append(r)
        if r.status != "200":
            st.errors += 1

    def view():
        elapsed = time.time() - start
        header = Text.assemble(
            ("loadgen compare  ", "bold"),
            (f"tenants={tenants} prompt≈{prompt_tokens} tokens rps={rps}/target  ", "dim"),
            (f"{elapsed:,.0f}s / {duration}s", "bold cyan"),
        )
        grid = Table.grid(expand=True)
        for _ in targets:
            grid.add_column(ratio=1)
        grid.add_row(*[render_target(stats[n], tenants, elapsed) for n, _ in targets])
        return Group(header, grid)

    async with httpx.AsyncClient(http2=False, limits=limits, timeout=timeout) as client:

        async def generator() -> None:
            next_t = time.time()
            while time.time() - start < duration:
                next_t += rng.expovariate(rps)
                await asyncio.sleep(max(0.0, next_t - time.time()))
                tenant = rng.randrange(tenants)
                question = f"{rng.choice(_QUESTIONS)} (#{rng.randrange(1_000_000)})"
                rid = uuid.uuid4().hex[:12]
                # ミラーリング: 同じリクエストを全ターゲットへ同時に送る
                for name, url in targets:
                    t = asyncio.create_task(fire(client, name, url, tenant, question, rid))
                    tasks.add(t)
                    t.add_done_callback(tasks.discard)

        gen = asyncio.create_task(generator())
        try:
            if no_live:
                while not gen.done():
                    await asyncio.sleep(10)
                    el = time.time() - start
                    line = "  ".join(
                        f"{n}: p50={fmt_ms(s.ttft_quantiles(60)[0])} conc={(s.concentration(60) or 0):.0%} err={s.errors}"
                        for n, s in stats.items()
                    )
                    console.print(f"[{el:5.0f}s] {line}")
            else:
                with Live(view(), console=console, refresh_per_second=2, screen=False) as live:
                    while not gen.done():
                        await asyncio.sleep(0.5)
                        live.update(view())
                    live.update(view())
            await gen
        except (KeyboardInterrupt, asyncio.CancelledError):
            gen.cancel()
        if tasks:
            await asyncio.wait(tasks, timeout=60)

    _write_outputs(stats, out_dir, summary_json, tenants)


def _write_outputs(stats: dict[str, TargetStats], out_dir: Path, summary_json: Path | None, tenants: int) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"loadgen-{datetime.now():%Y%m%d-%H%M%S}.csv"
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp", "target", "tenant", "pod", "ttft_ms", "e2e_ms", "status", "request_id"])
        for st in stats.values():
            for r in st.results:
                w.writerow(
                    [
                        datetime.fromtimestamp(r.ts).isoformat(timespec="milliseconds"),
                        r.target,
                        r.tenant,
                        r.pod,
                        "" if r.ttft_ms is None else f"{r.ttft_ms:.1f}",
                        "" if r.e2e_ms is None else f"{r.e2e_ms:.1f}",
                        r.status,
                        r.request_id,
                    ]
                )
    console.print(f"CSV: {path}")

    summary = {}
    for name, st in stats.items():
        p50, p95 = st.ttft_quantiles(60)
        summary[name] = {
            "ok": len(st.ok()),
            "errors": st.errors,
            "ttft_p50_ms_last60s": p50,
            "ttft_p95_ms_last60s": p95,
            "tenant_concentration_last60s": st.concentration(60),
            "tenant_concentration_all": st.concentration(None),
            "pods": sorted({r.pod for r in st.ok()}),
        }
    console.print_json(json.dumps(summary, ensure_ascii=False))
    if summary_json:
        summary_json.parent.mkdir(parents=True, exist_ok=True)
        summary_json.write_text(json.dumps(summary, ensure_ascii=False, indent=2))


@app.command()
def single(
    target: Annotated[str, typer.Option(help="URL（/v1/chat/completions の手前まで）")],
    prompt_tokens: int = 3000,
    max_tokens: int = 16,
    tenant: int = 0,
    count: int = 1,
) -> None:
    """1 リクエストずつ送り、リクエスト ID・処理した Pod・TTFT を表示する（Step 3 用）。"""

    async def run() -> int:
        prompt = tenant_system_prompt(tenant, prompt_tokens)
        failed = 0
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=10.0)) as client:
            for i in range(count):
                rid = uuid.uuid4().hex[:12]
                q = f"{random.choice(_QUESTIONS)} (#{random.randrange(1_000_000)})"
                console.print(f"[bold]→ request-id[/bold] [cyan]{rid}[/cyan]  prompt≈{prompt_tokens} tokens")
                r = await send_one(client, target, "single", tenant, prompt, q, max_tokens, rid)
                style = "green" if r.status == "200" else "red"
                console.print(
                    f"[{style}]← status={r.status}[/{style}]  pod=[bold]{r.pod}[/bold]  "
                    f"TTFT={fmt_ms(r.ttft_ms)}  E2E={fmt_ms(r.e2e_ms)}"
                )
                failed += r.status != "200"
                if i + 1 < count:
                    await asyncio.sleep(1)
        return failed

    raise typer.Exit(code=1 if asyncio.run(run()) else 0)


if __name__ == "__main__":
    app()
