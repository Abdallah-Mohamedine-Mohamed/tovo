import type { FastifyReply } from 'fastify';

export function chatStream(reply: FastifyReply, enabled: boolean) {
  let started = false;
  let heartbeat: NodeJS.Timeout | undefined;
  const stopHeartbeat = () => {
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = undefined;
  };
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
      // Gemini peut réfléchir plus de trente secondes avant son premier mot.
      // Sans octet intermédiaire, le téléphone conclut à tort que la réponse
      // est coupée. Ce battement maintient uniquement la connexion ouverte ;
      // l'interface l'ignore et n'affiche aucun spinner supplémentaire.
      heartbeat = setInterval(() => {
        if (reply.raw.destroyed || reply.raw.writableEnded) {
          stopHeartbeat();
          return;
        }
        reply.raw.write('{"type":"heartbeat"}\n');
      }, 10_000);
      reply.raw.once('close', stopHeartbeat);
    }
    reply.raw.write(`${JSON.stringify(event)}\n`);
  };
  return {
    emit,
    finish(body: Record<string, unknown>, status = 200) {
      if (!enabled) return reply.code(status).send(body);
      stopHeartbeat();
      emit({ type: status >= 400 ? 'error' : 'done', status, ...body });
      if (!reply.raw.destroyed && !reply.raw.writableEnded) reply.raw.end();
      return reply;
    },
  };
}
