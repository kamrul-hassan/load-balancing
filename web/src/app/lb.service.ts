import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

export type Endpoint = 'whoami' | 'delay' | 'work';

export interface WhoAmI {
  instanceId: string;
  podName: string;
  nodeName: string;
  podIp: string;
  zone: string;
  region: string;
  version: string;
  requestNumber: number;
  uptimeSeconds: number;
  servedAtUtc: string;
  clientIp: string | null;
  forwardedFor: string | null;
}

export interface WorkResult {
  podName: string;
  instanceId: string;
  requestedMs: number;
  elapsedMs: number;
  iterations: number;
}

export interface Hit {
  seq: number;
  ok: boolean;
  pod: string;
  instanceId: string;
  node: string;
  zone: string;
  latencyMs: number;
  status: number;
  at: Date;
  error?: string;
}

@Injectable({ providedIn: 'root' })
export class LbService {
  private readonly http = inject(HttpClient);

  /** Relative URL: nginx (container) or the dev-server proxy forwards /api to the backend. */
  private readonly base = '/api';

  async hit(endpoint: Endpoint, ms: number, seq: number): Promise<Hit> {
    const started = performance.now();
    const url =
      endpoint === 'whoami' ? `${this.base}/whoami` : `${this.base}/${endpoint}?ms=${ms}`;
    try {
      const body = await firstValueFrom(
        this.http.get<WhoAmI | WorkResult>(url, { headers: { 'Cache-Control': 'no-cache' } }),
      );
      const who = body as Partial<WhoAmI>;
      return {
        seq,
        ok: true,
        pod: body.podName,
        instanceId: body.instanceId,
        node: who.nodeName ?? '—',
        zone: who.zone ?? '—',
        latencyMs: performance.now() - started,
        status: 200,
        at: new Date(),
      };
    } catch (e) {
      const err = e as HttpErrorResponse;
      return {
        seq,
        ok: false,
        pod: 'error',
        instanceId: '',
        node: '—',
        zone: '—',
        latencyMs: performance.now() - started,
        status: err.status ?? 0,
        at: new Date(),
        error: err.message,
      };
    }
  }
}
