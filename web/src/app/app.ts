import { DecimalPipe, DatePipe } from '@angular/common';
import { Component, computed, inject, OnDestroy, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Endpoint, Hit, LbService } from './lb.service';

interface PodStat {
  pod: string;
  node: string;
  zone: string;
  count: number;
  share: number;
  avgLatency: number;
  color: string;
}

const PALETTE = ['#4f8cff', '#22c39a', '#f5a524', '#e5484d', '#a78bfa', '#14b8c6', '#f472b6', '#84cc16'];
const LOG_SIZE = 60;

@Component({
  selector: 'app-root',
  imports: [FormsModule, DecimalPipe, DatePipe],
  templateUrl: './app.html',
})
export class App implements OnDestroy {
  private readonly lb = inject(LbService);

  // Controls
  protected readonly endpoint = signal<Endpoint>('whoami');
  protected readonly total = signal(200);
  protected readonly concurrency = signal(10);
  protected readonly ms = signal(200);
  protected readonly continuous = signal(false);

  // State
  protected readonly running = signal(false);
  protected readonly hits = signal<Hit[]>([]);
  protected readonly log = signal<Hit[]>([]);
  protected readonly elapsedMs = signal(0);

  private seq = 0;
  private colors = new Map<string, string>();
  private stopRequested = false;

  protected readonly okCount = computed(() => this.hits().filter((h) => h.ok).length);
  protected readonly errorCount = computed(() => this.hits().length - this.okCount());
  protected readonly rps = computed(() =>
    this.elapsedMs() > 0 ? (this.hits().length / this.elapsedMs()) * 1000 : 0,
  );
  protected readonly p95 = computed(() => {
    const l = this.hits().filter((h) => h.ok).map((h) => h.latencyMs).sort((a, b) => a - b);
    return l.length ? l[Math.min(l.length - 1, Math.floor(l.length * 0.95))] : 0;
  });

  protected readonly pods = computed<PodStat[]>(() => {
    const ok = this.hits().filter((h) => h.ok);
    const groups = new Map<string, Hit[]>();
    for (const h of ok) groups.set(h.pod, [...(groups.get(h.pod) ?? []), h]);
    return [...groups.entries()]
      .map(([pod, list]) => ({
        pod,
        node: list[0].node,
        zone: list[0].zone,
        count: list.length,
        share: ok.length ? list.length / ok.length : 0,
        avgLatency: list.reduce((s, h) => s + h.latencyMs, 0) / list.length,
        color: this.colorFor(pod),
      }))
      .sort((a, b) => a.pod.localeCompare(b.pod));
  });

  /** Coefficient of variation of per-pod counts: 0 = perfectly even spread. */
  protected readonly imbalance = computed(() => {
    const counts = this.pods().map((p) => p.count);
    if (counts.length < 2) return 0;
    const mean = counts.reduce((a, b) => a + b, 0) / counts.length;
    const variance = counts.reduce((s, c) => s + (c - mean) ** 2, 0) / counts.length;
    return Math.sqrt(variance) / mean;
  });

  protected readonly maxShare = computed(() => Math.max(0.0001, ...this.pods().map((p) => p.share)));

  colorFor(pod: string): string {
    if (!this.colors.has(pod)) this.colors.set(pod, PALETTE[this.colors.size % PALETTE.length]);
    return this.colors.get(pod)!;
  }

  async run(): Promise<void> {
    if (this.running()) return;
    this.running.set(true);
    this.stopRequested = false;
    const started = performance.now();
    const tick = setInterval(() => this.elapsedMs.set(performance.now() - started), 250);

    try {
      do {
        let remaining = this.total();
        const worker = async () => {
          while (remaining > 0 && !this.stopRequested) {
            remaining--;
            const hit = await this.lb.hit(this.endpoint(), this.ms(), ++this.seq);
            this.hits.update((h) => [...h, hit]);
            this.log.update((l) => [hit, ...l].slice(0, LOG_SIZE));
          }
        };
        const workers = Math.max(1, Math.min(this.concurrency(), this.total()));
        await Promise.all(Array.from({ length: workers }, worker));
      } while (this.continuous() && !this.stopRequested);
    } finally {
      clearInterval(tick);
      this.elapsedMs.set(performance.now() - started);
      this.running.set(false);
    }
  }

  stop(): void {
    this.stopRequested = true;
  }

  reset(): void {
    this.hits.set([]);
    this.log.set([]);
    this.elapsedMs.set(0);
    this.seq = 0;
    this.colors.clear();
  }

  ngOnDestroy(): void {
    this.stop();
  }
}
