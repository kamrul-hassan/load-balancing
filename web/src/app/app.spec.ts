import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { App } from './app';

describe('App', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [App],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();
  });

  it('renders the dashboard heading', async () => {
    const fixture = TestBed.createComponent(App);
    await fixture.whenStable();
    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('h1')?.textContent).toContain('Load Balancing Lab');
  });

  it('groups responses by replica', async () => {
    const fixture = TestBed.createComponent(App);
    const app = fixture.componentInstance as unknown as {
      total: { set(v: number): void };
      concurrency: { set(v: number): void };
      run(): Promise<void>;
      pods(): { pod: string; count: number }[];
    };
    const http = TestBed.inject(HttpTestingController);

    app.total.set(4);
    app.concurrency.set(1);
    const done = app.run();

    for (const pod of ['api-a', 'api-b', 'api-a', 'api-b']) {
      await new Promise((r) => setTimeout(r));
      http.expectOne('/api/whoami').flush({ podName: pod, instanceId: pod, nodeName: 'n1', zone: '1' });
    }
    await done;

    expect(app.pods().map((p) => [p.pod, p.count])).toEqual([
      ['api-a', 2],
      ['api-b', 2],
    ]);
    http.verify();
  });
});
