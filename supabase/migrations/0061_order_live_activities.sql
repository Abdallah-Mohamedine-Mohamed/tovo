create table public.order_live_activities (
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  activity_token text primary key,
  fcm_token text not null references public.push_tokens(token) on delete cascade,
  updated_at timestamptz not null default now()
);

create index order_live_activities_order_id_idx
  on public.order_live_activities(order_id);

alter table public.order_live_activities enable row level security;
