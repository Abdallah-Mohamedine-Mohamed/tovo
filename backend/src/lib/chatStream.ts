import type { FastifyReply } from 'fastify';

export function chatStream(reply: FastifyReply, enabled: boolean) {
  let started = false;
  const emit = (event: Record<string, unknown>) => {
    if (!enabled || reply.raw.destroyed || reply.raw.writableEnded) return;
    if (!started) {
      started = true;
      reply.hijack();
      for (const [name, value] of Object.entries(reply.getHeaders())) {
        if (value !== undefined) reply.raw.setHeader(name, value);
      }
      reply.raw.setHeader('content-type', 'application/x-ndjson; charset=utf-8');
      reply.raw.setHeader('cache-control', 'no-store');
      reply.raw.setHeader('x-accel-buffering', 'no');
      reply.raw.flushHeaders();
    }
    reply.raw.write(`${JSON.stringify(event)}\n`);
  };
  return {
    emit,
    finish(body: Record<string, unknown>, status = 200) {
      if (!enabled) return reply.code(status).send(body);
      emit({ type: status >= 400 ? 'error' : 'done', status, ...body });
      if (!reply.raw.destroyed && !reply.raw.writableEnded) reply.raw.end();
      return reply;
    },
  };
}
