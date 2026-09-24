import { getMessaging } from 'firebase-admin/messaging';
import { serviceClient } from './supabase.js';
import { firebaseApp } from './notifications.js';

const terminal = new Set(['delivered', 'cancelled']);

export async function updateLiveActivities(orderId: string, status: string): Promise<void> {
  const db = serviceClient();
  const { data: activities, error } = await db
    .from('order_live_activities')
    .select('activity_token, fcm_token')
    .eq('order_id', orderId);
  if (error || !activities?.length) return;

  const app = firebaseApp();
  if (!app) return;

  const now = Math.floor(Date.now() / 1000);
  const ended = terminal.has(status);
  const responses = await getMessaging(app).sendEach(activities.map((activity) => ({
    token: activity.fcm_token as string,
    apns: {
      liveActivityToken: activity.activity_token as string,
      headers: { 'apns-priority': '10' },
      payload: {
        aps: {
          timestamp: now,
          event: ended ? 'end' : 'update',
          'content-state': { status },
          ...(ended ? { 'dismissal-date': now + 60 } : {}),
        },
      },
    },
  })));

  const expired = activities.filter((_, index) => {
    const response = responses.responses[index];
    return (ended && response?.success) ||
      response?.error?.code === 'messaging/registration-token-not-registered' ||
      response?.error?.code === 'messaging/invalid-registration-token';
  }).map((activity) => activity.activity_token as string);
  if (expired.length) {
    await db.from('order_live_activities').delete().in('activity_token', expired);
  }
}
