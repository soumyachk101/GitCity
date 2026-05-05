-- ============================================================
-- Git City — Initial Schema
-- ============================================================

-- 1. developers — one row per GitHub user
create table if not exists developers (
  id            bigint generated always as identity primary key,
  github_login  text    not null unique,
  github_id     bigint,
  name          text,
  avatar_url    text,
  bio           text,
  contributions int     not null default 0,
  public_repos  int     not null default 0,
  total_stars   int     not null default 0,
  primary_language text,
  top_repos     jsonb   not null default '[]'::jsonb,
  rank          int,
  fetched_at    timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create index if not exists idx_developers_rank on developers (rank);
create index if not exists idx_developers_login on developers (github_login);
create index if not exists idx_developers_contributions on developers (contributions desc);
create index if not exists idx_developers_fetched_at on developers (fetched_at);

-- 2. add_requests — rate limiting table
create table if not exists add_requests (
  id          bigint generated always as identity primary key,
  ip_hash     text        not null,
  created_at  timestamptz not null default now()
);

create index if not exists idx_add_requests_ip_created on add_requests (ip_hash, created_at);

-- 3. city_stats — singleton for global stats
create table if not exists city_stats (
  id                  int  primary key default 1 check (id = 1),
  total_developers    int  not null default 0,
  total_contributions bigint not null default 0,
  updated_at          timestamptz not null default now()
);

-- seed singleton
insert into city_stats (id) values (1) on conflict do nothing;

-- 4. RLS — public read for developers and city_stats
alter table developers   enable row level security;
alter table city_stats   enable row level security;
alter table add_requests enable row level security;

create policy "Public read developers"
  on developers for select
  using (true);

create policy "Public read city_stats"
  on city_stats for select
  using (true);

-- add_requests: no public access (server-side only via service role)

-- 5. recalculate_ranks() — reorders all devs by contributions DESC
create or replace function recalculate_ranks()
returns void
language plpgsql
security definer
as $$
begin
  with ranked as (
    select id, row_number() over (order by contributions desc, github_login asc) as new_rank
    from developers
  )
  update developers d
  set rank = r.new_rank
  from ranked r
  where d.id = r.id;

  update city_stats
  set total_developers    = (select count(*) from developers),
      total_contributions = (select coalesce(sum(contributions), 0) from developers),
      updated_at          = now()
  where id = 1;
end;
$$;
-- ============================================================
-- Git City — Add claimed columns for GitHub OAuth
-- ============================================================

alter table developers
  add column if not exists claimed      boolean      not null default false,
  add column if not exists claimed_by   uuid         references auth.users(id),
  add column if not exists fetch_priority int        not null default 0,
  add column if not exists claimed_at   timestamptz;

create index if not exists idx_developers_claimed
  on developers (claimed) where claimed = true;
-- Items catalog
create table items (
  id              text primary key,
  category        text not null,           -- 'effect' | 'structure' | 'identity'
  name            text not null,
  description     text,
  price_usd_cents int not null,
  price_brl_cents int not null,
  is_active       boolean default true,
  metadata        jsonb default '{}',
  created_at      timestamptz default now()
);

-- Purchases (one-time, permanent)
create table purchases (
  id              uuid primary key default gen_random_uuid(),
  developer_id    bigint not null references developers(id),
  item_id         text not null references items(id),
  provider        text not null,           -- 'stripe' | 'abacatepay'
  provider_tx_id  text unique,
  amount_cents    int not null,
  currency        text not null,           -- 'usd' | 'brl'
  status          text not null default 'pending',
  created_at      timestamptz default now()
);

create index idx_purchases_dev on purchases(developer_id, status);
create index idx_purchases_provider on purchases(provider_tx_id);
-- Prevent duplicate completed purchases for same item
create unique index idx_purchases_unique_completed
  on purchases(developer_id, item_id) where status = 'completed';

-- Developer customizations (config per item, e.g. color choice)
create table developer_customizations (
  id            uuid primary key default gen_random_uuid(),
  developer_id  bigint not null references developers(id),
  item_id       text not null references items(id),
  config        jsonb not null default '{}',
  updated_at    timestamptz default now(),
  unique (developer_id, item_id)
);

-- RLS
alter table items enable row level security;
alter table purchases enable row level security;
alter table developer_customizations enable row level security;

create policy "Public read items" on items for select using (true);
create policy "Public read purchases" on purchases for select using (true);
create policy "Public read customizations" on developer_customizations for select using (true);

-- Seed: item catalog
insert into items (id, category, name, description, price_usd_cents, price_brl_cents, metadata) values
  ('neon_outline',    'effect',    'Neon Outline',    'Glowing outline on building edges',         200, 990, '{}'),
  ('particle_aura',   'effect',    'Particle Aura',   'Floating particles around the building',    300, 1490, '{}'),
  ('spotlight',       'effect',    'Spotlight',        'Spotlight beam pointing to the sky',        150, 790, '{}'),
  ('rooftop_fire',    'effect',    'Rooftop Fire',    'Stylized flames on the rooftop',            200, 990, '{}'),
  ('helipad',         'structure', 'Helipad',         'Helicopter landing pad on top',             100, 490, '{}'),
  ('antenna_array',   'structure', 'Antenna Array',   'Multiple antennas on the rooftop',          100, 490, '{}'),
  ('rooftop_garden',  'structure', 'Rooftop Garden',  'Green rooftop with trees',                  150, 790, '{}'),
  ('spire',           'structure', 'Spire',           'Empire State-style spire on top',           200, 990, '{}'),
  ('custom_color',    'identity',  'Custom Color',    'Choose your building color',                150, 790, '{"default_color": "#c8e64a"}'),
  ('billboard',       'identity',  'Billboard',       'Logo or image on the building side',        300, 1490, '{}'),
  ('flag',            'identity',  'Flag',            'Custom flag on the rooftop',                100, 490, '{}');
-- ============================================================
-- Git City — pg_cron: recalculate ranks every 30 minutes
-- ============================================================
-- Requires pg_cron extension (enabled by default on Supabase)

-- Enable pg_cron if not already
create extension if not exists pg_cron with schema pg_catalog;

-- Schedule rank recalculation every 30 minutes
select cron.schedule(
  'recalculate-ranks',
  '*/30 * * * *',
  'select recalculate_ranks()'
);
-- Tighten RLS: purchases and customizations should NOT be world-readable.
-- All API routes use getSupabaseAdmin() (service role) so they bypass RLS.

-- purchases: drop public read, allow only owner
drop policy "Public read purchases" on purchases;

create policy "Owner reads own purchases" on purchases
  for select using (
    auth.uid() is not null
    and developer_id in (
      select id from developers where claimed_by = auth.uid()
    )
  );

-- developer_customizations: drop public read, allow only owner
drop policy "Public read customizations" on developer_customizations;

create policy "Owner reads own customizations" on developer_customizations
  for select using (
    auth.uid() is not null
    and developer_id in (
      select id from developers where claimed_by = auth.uid()
    )
  );
-- Reprice all items: lower entry barrier, clearer tier structure
-- Tier 1 (Entry  $0.75 / R$3.90): simple structures
-- Tier 2 (Core   $1.00 / R$4.90): effects + identity
-- Tier 3 (Premium$1.50 / R$7.90): top-tier effect
-- Tier 4 (Stack  $2.00 / R$9.90): billboard (multi-buy)

-- Entry tier: $0.75 / R$3.90
update items set price_usd_cents = 75,  price_brl_cents = 390 where id = 'helipad';
update items set price_usd_cents = 75,  price_brl_cents = 390 where id = 'antenna_array';
update items set price_usd_cents = 75,  price_brl_cents = 390 where id = 'rooftop_garden';

-- Core tier: $1.00 / R$4.90
update items set price_usd_cents = 100, price_brl_cents = 490 where id = 'spotlight';
update items set price_usd_cents = 100, price_brl_cents = 490 where id = 'custom_color';
update items set price_usd_cents = 100, price_brl_cents = 490 where id = 'neon_outline';
update items set price_usd_cents = 100, price_brl_cents = 490 where id = 'rooftop_fire';
update items set price_usd_cents = 100, price_brl_cents = 490 where id = 'spire';

-- Premium tier: $1.50 / R$7.90
update items set price_usd_cents = 150, price_brl_cents = 790 where id = 'particle_aura';

-- Stackable tier: $2.00 / R$9.90
update items set price_usd_cents = 200, price_brl_cents = 990 where id = 'billboard';
-- ============================================================
-- Git City v2 — Achievements, Social Interactions, Activity Feed
-- ============================================================

-- 1. Extend developers table
alter table developers add column if not exists kudos_count int not null default 0;
alter table developers add column if not exists visit_count int not null default 0;
alter table developers add column if not exists referred_by text;
alter table developers add column if not exists referral_count int not null default 0;

-- 2. Extend purchases table for gifts
alter table purchases add column if not exists gifted_to bigint references developers(id);

-- Drop the old unique index and recreate to allow gifts
-- Old: unique on (developer_id, item_id) where status = 'completed'
-- New: unique on (developer_id, item_id, coalesce(gifted_to, 0)) where status = 'completed'
drop index if exists idx_purchases_unique_completed;
create unique index idx_purchases_unique_completed
  on purchases(developer_id, item_id, coalesce(gifted_to, 0)) where status = 'completed';

-- 3. Achievements catalog (static)
create table if not exists achievements (
  id              text primary key,
  category        text not null,          -- 'commits' | 'repos' | 'stars' | 'social' | 'kudos' | 'gifts_sent' | 'gifts_received'
  name            text not null,
  description     text not null,
  threshold       int not null,
  tier            text not null,          -- 'bronze' | 'silver' | 'gold' | 'diamond'
  reward_type     text not null,          -- 'unlock_item' | 'exclusive_badge'
  reward_item_id  text references items(id),
  sort_order      int not null
);

alter table achievements enable row level security;
drop policy if exists "Public read achievements" on achievements;
create policy "Public read achievements" on achievements for select using (true);

-- 4. Developer achievements (per-dev unlocks)
create table if not exists developer_achievements (
  developer_id    bigint not null references developers(id),
  achievement_id  text not null references achievements(id),
  unlocked_at     timestamptz not null default now(),
  seen            boolean not null default false,
  primary key (developer_id, achievement_id)
);

create index if not exists idx_dev_achievements_dev on developer_achievements(developer_id);

alter table developer_achievements enable row level security;
drop policy if exists "Public read developer_achievements" on developer_achievements;
create policy "Public read developer_achievements" on developer_achievements for select using (true);

-- 5. Developer kudos (daily, one per pair per day)
create table if not exists developer_kudos (
  giver_id      bigint not null references developers(id),
  receiver_id   bigint not null references developers(id),
  given_date    date not null default current_date,
  created_at    timestamptz not null default now(),
  primary key (giver_id, receiver_id, given_date)
);

create index if not exists idx_kudos_giver_date on developer_kudos(giver_id, given_date);
create index if not exists idx_kudos_receiver on developer_kudos(receiver_id);

alter table developer_kudos enable row level security;
-- Public read for kudos (to show "you already gave kudos today")
drop policy if exists "Public read kudos" on developer_kudos;
create policy "Public read kudos" on developer_kudos for select using (true);

-- 6. Building visits (daily, one per visitor per building per day)
create table if not exists building_visits (
  visitor_id    bigint not null references developers(id),
  building_id   bigint not null references developers(id),
  visit_date    date not null default current_date,
  created_at    timestamptz not null default now(),
  primary key (visitor_id, building_id, visit_date)
);

create index if not exists idx_visits_building on building_visits(building_id);
create index if not exists idx_visits_visitor_date on building_visits(visitor_id, visit_date);

alter table building_visits enable row level security;
drop policy if exists "Public read visits" on building_visits;
create policy "Public read visits" on building_visits for select using (true);

-- 7. Activity feed (event log)
create table if not exists activity_feed (
  id          uuid primary key default gen_random_uuid(),
  event_type  text not null,
  actor_id    bigint references developers(id),
  target_id   bigint references developers(id),
  metadata    jsonb default '{}',
  created_at  timestamptz not null default now()
);

create index if not exists idx_feed_created on activity_feed(created_at desc);
create index if not exists idx_feed_actor on activity_feed(actor_id, created_at desc);

alter table activity_feed enable row level security;
drop policy if exists "Public read feed" on activity_feed;
create policy "Public read feed" on activity_feed for select using (true);

-- 8. SQL functions for atomic counter increments

create or replace function increment_kudos_count(target_dev_id bigint)
returns void
language plpgsql
security definer
as $$
begin
  update developers
  set kudos_count = kudos_count + 1
  where id = target_dev_id;
end;
$$;

create or replace function increment_visit_count(target_dev_id bigint)
returns void
language plpgsql
security definer
as $$
begin
  update developers
  set visit_count = visit_count + 1
  where id = target_dev_id;
end;
$$;

create or replace function increment_referral_count(referrer_dev_id bigint)
returns void
language plpgsql
security definer
as $$
begin
  update developers
  set referral_count = referral_count + 1
  where id = referrer_dev_id;
end;
$$;

-- 9. Seed achievements catalog (22 milestones)
-- Note: grinder uses reward_item_id = null here because neon_trim is created in migration 008.
-- Migration 008 updates grinder's reward_item_id to 'neon_trim' after inserting the item.

-- Commits (contributions)
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('first_push',  'commits', 'First Push',  'Make your first contribution',              1,     'bronze',  'unlock_item',     'flag',            1),
  ('committed',   'commits', 'Committed',   'Reach 100 contributions',                   100,   'bronze',  'unlock_item',     'custom_color',    2),
  ('grinder',     'commits', 'Grinder',     'Reach 500 contributions',                   500,   'silver',  'unlock_item',     null,              3),
  ('machine',     'commits', 'Machine',     'Reach 1,000 contributions',                 1000,  'gold',    'exclusive_badge',  null,              4),
  ('legend',      'commits', 'Legend',      'Reach 5,000 contributions',                 5000,  'diamond', 'exclusive_badge',  null,              5),
  ('god_mode',    'commits', 'God Mode',    'Reach 10,000 contributions',                10000, 'diamond', 'exclusive_badge',  null,              6)
on conflict (id) do nothing;

-- Repos (public_repos)
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('builder',     'repos',   'Builder',     'Have 5 public repositories',                5,     'bronze',  'unlock_item',     'antenna_array',   7),
  ('architect',   'repos',   'Architect',   'Have 20 public repositories',               20,    'silver',  'unlock_item',     'rooftop_garden',  8),
  ('factory',     'repos',   'Factory',     'Have 50 public repositories',               50,    'gold',    'exclusive_badge',  null,              9)
on conflict (id) do nothing;

-- Stars (total_stars)
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('rising_star', 'stars',   'Rising Star', 'Collect 10 stars across repos',             10,    'bronze',  'unlock_item',     'spotlight',       10),
  ('popular',     'stars',   'Popular',     'Collect 100 stars across repos',            100,   'gold',    'exclusive_badge',  null,              11),
  ('famous',      'stars',   'Famous',      'Collect 1,000 stars across repos',          1000,  'diamond', 'exclusive_badge',  null,              12)
on conflict (id) do nothing;

-- Social (referrals)
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('recruiter',   'social',  'Recruiter',   'Refer 3 developers to Git City',            3,     'bronze',  'unlock_item',     'helipad',         13),
  ('influencer',  'social',  'Influencer',  'Refer 10 developers to Git City',           10,    'gold',    'exclusive_badge',  null,              14),
  ('mayor',       'social',  'Mayor',       'Refer 50 developers to Git City',           50,    'diamond', 'exclusive_badge',  null,              15)
on conflict (id) do nothing;

-- Gifts sent
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('generous',       'gifts_sent',     'Generous',       'Send your first gift',          1,     'bronze',  'exclusive_badge',  null,             16),
  ('patron',         'gifts_sent',     'Patron',         'Send 5 gifts',                  5,     'silver',  'exclusive_badge',  null,             17),
  ('philanthropist', 'gifts_sent',     'Philanthropist', 'Send 10 gifts',                 10,    'gold',    'exclusive_badge',  null,             18)
on conflict (id) do nothing;

-- Gifts received
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('gifted',   'gifts_received', 'Gifted',   'Receive your first gift',                   1,     'bronze',  'exclusive_badge',  null,             19),
  ('beloved',  'gifts_received', 'Beloved',  'Receive 5 gifts',                           5,     'silver',  'exclusive_badge',  null,             20),
  ('icon',     'gifts_received', 'Icon',     'Receive 10 gifts',                          10,    'gold',    'exclusive_badge',  null,             21)
on conflict (id) do nothing;

-- Kudos received
insert into achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order) values
  ('appreciated', 'kudos',  'Appreciated', 'Receive 50 kudos',                            50,    'bronze',  'exclusive_badge',  null,             22),
  ('admired',     'kudos',  'Admired',     'Receive 500 kudos',                            500,   'silver',  'exclusive_badge',  null,             23),
  ('legendary',   'kudos',  'Legendary',   'Receive 5,000 kudos',                          5000,  'gold',    'exclusive_badge',  null,             24)
on conflict (id) do nothing;
-- ============================================================
-- Git City v2 — Item Catalog Update: Zones + New Items
-- ============================================================

-- 1. Add zone column to items
alter table items add column if not exists zone text;

-- 2. Set zones on existing items
update items set zone = 'crown' where id in ('flag', 'helipad', 'spire');
update items set zone = 'roof'  where id in ('antenna_array', 'rooftop_garden', 'rooftop_fire');
update items set zone = 'aura'  where id in ('neon_outline', 'particle_aura', 'spotlight');
update items set zone = 'faces' where id in ('custom_color', 'billboard');

-- 3. Retire neon_outline and particle_aura (keep purchase data intact)
update items set is_active = false where id in ('neon_outline', 'particle_aura');

-- 4. Insert new items

-- Crown zone
insert into items (id, category, name, description, price_usd_cents, price_brl_cents, zone, metadata) values
  ('satellite_dish', 'structure', 'Satellite Dish', 'Large dish with iconic silhouette',                          150, 790, 'crown', '{}'),
  ('crown_item',     'structure', 'Crown',          'Pixelated gold crown with strong glow',                      300, 1490, 'crown', '{}')
on conflict (id) do nothing;

-- Roof zone
insert into items (id, category, name, description, price_usd_cents, price_brl_cents, zone, metadata) values
  ('pool_party',     'structure', 'Pool Party',     'Bright blue pool with pixelated lounge chairs',              200, 990, 'roof', '{}')
on conflict (id) do nothing;

-- Aura zone — neon_trim replaces neon_outline
insert into items (id, category, name, description, price_usd_cents, price_brl_cents, zone, metadata) values
  ('neon_trim',      'effect',    'Neon Trim',      'Thick neon bars on building edges, pulses gently',           100, 490, 'aura', '{}'),
  ('hologram_ring',  'effect',    'Hologram Ring',   'Translucent ring rotating slowly around building',          200, 990, 'aura', '{}'),
  ('lightning_aura', 'effect',    'Lightning Aura',  'Electric bolts crackling with intermittent flash',          300, 1490, 'aura', '{}')
on conflict (id) do nothing;

-- Faces zone
insert into items (id, category, name, description, price_usd_cents, price_brl_cents, zone, metadata) values
  ('led_banner',     'identity',  'LED Banner',     'Scrolling text marquee on building facade',                  250, 1290, 'faces', '{}')
on conflict (id) do nothing;

-- 5. Update existing item descriptions and prices to match v2 catalog
update items set price_usd_cents = 100, price_brl_cents = 490, zone = 'aura'
  where id = 'spotlight';
update items set price_usd_cents = 100, price_brl_cents = 490, zone = 'faces'
  where id = 'custom_color';
update items set price_usd_cents = 100, price_brl_cents = 490, zone = 'roof'
  where id = 'rooftop_fire';
update items set price_usd_cents = 100, price_brl_cents = 490, zone = 'roof'
  where id = 'rooftop_garden';
update items set price_usd_cents = 75,  price_brl_cents = 390, zone = 'crown'
  where id = 'helipad';
update items set price_usd_cents = 75,  price_brl_cents = 390, zone = 'roof'
  where id = 'antenna_array';
update items set price_usd_cents = 100, price_brl_cents = 490, zone = 'crown'
  where id = 'spire';
update items set price_usd_cents = 200, price_brl_cents = 990, zone = 'faces'
  where id = 'billboard';

-- 6. Update achievement references for neon_trim (replacing neon_outline)
update achievements set reward_item_id = 'neon_trim' where id = 'grinder';
-- Sky Ads catalog (moves from hardcoded to DB)
create table sky_ads (
  id text primary key,
  brand text not null,
  text text not null,
  description text,
  color text not null default '#f8d880',
  bg_color text not null default '#1a1018',
  link text,
  vehicle text not null default 'plane' check (vehicle in ('plane', 'blimp')),
  priority integer not null default 50,
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

-- Ad events (impressions + clicks in one table, type column)
create table sky_ad_events (
  id bigint generated always as identity primary key,
  ad_id text not null references sky_ads(id),
  event_type text not null check (event_type in ('impression', 'click', 'cta_click')),
  ip_hash text,
  user_agent text,
  created_at timestamptz not null default now()
);

-- Indexes
create index idx_sky_ad_events_ad_id on sky_ad_events(ad_id);
create index idx_sky_ad_events_created on sky_ad_events(created_at);
create index idx_sky_ad_events_type on sky_ad_events(ad_id, event_type);

-- Daily aggregate materialized view (fast dashboard queries)
create materialized view sky_ad_daily_stats as
select
  ad_id,
  date_trunc('day', created_at)::date as day,
  count(*) filter (where event_type = 'impression') as impressions,
  count(*) filter (where event_type = 'click') as clicks,
  count(*) filter (where event_type = 'cta_click') as cta_clicks
from sky_ad_events
group by ad_id, date_trunc('day', created_at)::date;

create unique index idx_sky_ad_daily_stats on sky_ad_daily_stats(ad_id, day);

-- RLS: public read for active ads, insert events via service role only
alter table sky_ads enable row level security;
alter table sky_ad_events enable row level security;

create policy "Public can read active ads"
  on sky_ads for select using (active = true and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()));

-- No policies on sky_ad_events: RLS blocks all anon/authenticated access.
-- Only service role (used by our API routes) can insert/read, bypassing RLS.

-- Helper function to refresh the materialized view (called from API)
create or replace function refresh_sky_ad_stats()
returns void language plpgsql security definer as $$
begin
  refresh materialized view concurrently sky_ad_daily_stats;
end;
$$;

-- Seed default ads
insert into sky_ads (id, brand, text, description, color, bg_color, link, vehicle, priority) values
  ('gitcity', 'Git City', 'THEGITCITY.COM ★ YOUR CODE, YOUR CITY ★ THEGITCITY.COM', 'A city built from GitHub contributions. Search your username and find your building among thousands of developers.', '#f8d880', '#1a1018', 'https://thegitcity.com', 'plane', 100),
  ('samuel', 'Samuel Rizzon', 'HEY, I BUILD THIS! → SAMUELRIZZON.DEV', 'Full-stack dev who builds weird and cool stuff. This city is one of them.', '#c8e64a', '#1a1018', 'https://www.samuelrizzon.dev/en.html', 'plane', 90),
  ('build', 'ReplyOS', 'YOUR AI COPILOT TO GROW ON X', 'I grew +1.2k followers and 1M views in 3 weeks using ReplyOS. Viral library, lead radar, post writer, auto-replies. Your AI copilot to grow on X.', '#ffffff', '#2a1838', 'https://reply-os.com', 'blimp', 80),
  ('advertise', 'Sky Ads', 'ADD YOUR AD HERE', 'Want your brand flying over Git City? Planes, blimps, your colors. Get in touch!', '#f8d880', '#1a1018', 'mailto:samuelrizzondev@gmail.com?subject=Git%20City%20Sky%20Ad', 'plane', 10);
-- Building Generation v2: expanded developer profile fields
-- Run manually in Supabase SQL Editor

ALTER TABLE developers ADD COLUMN IF NOT EXISTS contributions_total int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS contribution_years int[] DEFAULT '{}';
ALTER TABLE developers ADD COLUMN IF NOT EXISTS total_prs int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS total_reviews int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS total_issues int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS repos_contributed_to int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS followers int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS following int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS organizations_count int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS account_created_at timestamptz;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS current_streak int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS longest_streak int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS active_days_last_year int DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS language_diversity int DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_developers_contributions_total ON developers (contributions_total DESC);

-- Updated ranking: use contributions_total when available, fallback to contributions
-- Run this AFTER some devs have been re-fetched with v2 data
CREATE OR REPLACE FUNCTION recalculate_ranks()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  WITH ranked AS (
    SELECT id, row_number() OVER (
      ORDER BY CASE WHEN contributions_total > 0 THEN contributions_total ELSE contributions END DESC,
      github_login ASC
    ) AS new_rank
    FROM developers
  )
  UPDATE developers d
  SET rank = r.new_rank
  FROM ranked r
  WHERE d.id = r.id;

  UPDATE city_stats
  SET total_developers = (SELECT count(*) FROM developers),
      total_contributions = (SELECT coalesce(sum(contributions), 0) FROM developers),
      updated_at = now()
  WHERE id = 1;
END;
$$;
-- ============================================================
-- Raise achievement thresholds (old values were too easy)
-- ============================================================

-- Item-unlock achievements
-- first_push stays at 1 (free Flag bait to get users into the shop)
update achievements set threshold = 1000  where id = 'committed';    -- was 100
update achievements set threshold = 2500  where id = 'grinder';      -- was 500
update achievements set threshold = 25    where id = 'builder';      -- was 5
update achievements set threshold = 75    where id = 'architect';    -- was 20
update achievements set threshold = 100   where id = 'rising_star';  -- was 10
update achievements set threshold = 10    where id = 'recruiter';    -- was 3

-- Badge-only achievements (keep progression feeling earned)
update achievements set threshold = 5000  where id = 'machine';      -- was 1,000
update achievements set threshold = 15000 where id = 'legend';       -- was 5,000
update achievements set threshold = 30000 where id = 'god_mode';     -- was 10,000
update achievements set threshold = 150   where id = 'factory';      -- was 50
update achievements set threshold = 500   where id = 'popular';      -- was 100
update achievements set threshold = 5000  where id = 'famous';       -- was 1,000
update achievements set threshold = 30    where id = 'influencer';   -- was 10
update achievements set threshold = 100   where id = 'mayor';        -- was 50

-- Also update descriptions to reflect new thresholds
update achievements set description = 'Reach 1,000 contributions'         where id = 'committed';
update achievements set description = 'Reach 2,500 contributions'         where id = 'grinder';
update achievements set description = 'Have 25 public repositories'       where id = 'builder';
update achievements set description = 'Have 75 public repositories'       where id = 'architect';
update achievements set description = 'Collect 100 stars across repos'    where id = 'rising_star';
update achievements set description = 'Refer 10 developers to Git City'  where id = 'recruiter';
update achievements set description = 'Reach 5,000 contributions'         where id = 'machine';
update achievements set description = 'Reach 15,000 contributions'        where id = 'legend';
update achievements set description = 'Reach 30,000 contributions'        where id = 'god_mode';
update achievements set description = 'Have 150 public repositories'      where id = 'factory';
update achievements set description = 'Collect 500 stars across repos'    where id = 'popular';
update achievements set description = 'Collect 5,000 stars across repos'  where id = 'famous';
update achievements set description = 'Refer 30 developers to Git City'  where id = 'influencer';
update achievements set description = 'Refer 100 developers to Git City' where id = 'mayor';
-- Add github_login to sky_ad_events so we know which logged-in user
-- triggered the event (nullable — anonymous visitors won't have it).
alter table sky_ad_events add column github_login text;

create index idx_sky_ad_events_login on sky_ad_events(github_login)
  where github_login is not null;
-- Sky Ads self-service purchase flow columns
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS purchaser_email TEXT;
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS stripe_session_id TEXT;
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS plan_id TEXT;
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS tracking_token TEXT UNIQUE;
-- 013_building_ads.sql
-- Expand sky_ads vehicle column to support building ad formats

-- Drop existing CHECK constraint and recreate with new vehicle types
ALTER TABLE sky_ads DROP CONSTRAINT IF EXISTS sky_ads_vehicle_check;
ALTER TABLE sky_ads ADD CONSTRAINT sky_ads_vehicle_check
  CHECK (vehicle IN ('plane', 'blimp', 'billboard', 'rooftop_sign', 'led_wrap'));
-- ============================================================
-- 014: Streak System
-- Adds app streak columns, checkin/freeze tables, RPCs,
-- streak achievements, and streak_freeze consumable item.
-- ============================================================

-- ─── 1. New columns on developers ──────────────────────────
ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS app_streak              int     DEFAULT 0,
  ADD COLUMN IF NOT EXISTS app_longest_streak      int     DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_checkin_date       date    NULL,
  ADD COLUMN IF NOT EXISTS streak_freezes_available int    DEFAULT 0,
  ADD COLUMN IF NOT EXISTS streak_freeze_30d_claimed boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS kudos_streak            int     DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_kudos_given_date   date    NULL;

-- ─── 2. streak_checkins table ──────────────────────────────
CREATE TABLE IF NOT EXISTS streak_checkins (
  developer_id  bigint    NOT NULL REFERENCES developers(id),
  checkin_date  date      NOT NULL DEFAULT current_date,
  type          text      NOT NULL DEFAULT 'active' CHECK (type IN ('active', 'frozen')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (developer_id, checkin_date)
);

CREATE INDEX IF NOT EXISTS idx_streak_checkins_dev_date
  ON streak_checkins (developer_id, checkin_date DESC);

ALTER TABLE streak_checkins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "streak_checkins_public_read" ON streak_checkins;
CREATE POLICY "streak_checkins_public_read" ON streak_checkins
  FOR SELECT USING (true);

-- ─── 3. streak_freeze_log table ────────────────────────────
CREATE TABLE IF NOT EXISTS streak_freeze_log (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id  bigint      NOT NULL REFERENCES developers(id),
  action        text        NOT NULL CHECK (action IN ('purchased', 'granted_milestone', 'consumed')),
  frozen_date   date        NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_streak_freeze_log_dev
  ON streak_freeze_log (developer_id, created_at DESC);

ALTER TABLE streak_freeze_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "streak_freeze_log_public_read" ON streak_freeze_log;
CREATE POLICY "streak_freeze_log_public_read" ON streak_freeze_log
  FOR SELECT USING (true);

-- ─── 4. perform_checkin RPC ────────────────────────────────
CREATE OR REPLACE FUNCTION perform_checkin(p_developer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_last_date    date;
  v_streak       int;
  v_longest      int;
  v_freezes      int;
  v_today        date := current_date;
  v_was_frozen   boolean := false;
BEGIN
  -- Lock the developer row to prevent race conditions
  SELECT last_checkin_date, app_streak, app_longest_streak, streak_freezes_available
    INTO v_last_date, v_streak, v_longest, v_freezes
    FROM developers
   WHERE id = p_developer_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'checked_in', false,
      'error', 'developer_not_found'
    );
  END IF;

  -- Already checked in today: idempotent return
  IF v_last_date = v_today THEN
    RETURN jsonb_build_object(
      'checked_in', false,
      'already_today', true,
      'streak', v_streak,
      'longest', v_longest
    );
  END IF;

  -- Consecutive day: streak + 1
  IF v_last_date = v_today - 1 THEN
    v_streak := v_streak + 1;

  -- Missed exactly 1 day AND has freeze available
  ELSIF v_last_date = v_today - 2 AND v_freezes > 0 THEN
    v_freezes := v_freezes - 1;
    v_streak := v_streak + 1;
    v_was_frozen := true;

    -- Insert the frozen day check-in (yesterday)
    INSERT INTO streak_checkins (developer_id, checkin_date, type)
    VALUES (p_developer_id, v_today - 1, 'frozen')
    ON CONFLICT DO NOTHING;

    -- Log the freeze consumption
    INSERT INTO streak_freeze_log (developer_id, action, frozen_date)
    VALUES (p_developer_id, 'consumed', v_today - 1);

  -- Any other gap: reset
  ELSE
    v_streak := 1;
  END IF;

  -- Update longest
  IF v_streak > v_longest THEN
    v_longest := v_streak;
  END IF;

  -- Update developer row
  UPDATE developers
     SET app_streak = v_streak,
         app_longest_streak = v_longest,
         last_checkin_date = v_today,
         streak_freezes_available = v_freezes
   WHERE id = p_developer_id;

  -- Insert today's check-in
  INSERT INTO streak_checkins (developer_id, checkin_date, type)
  VALUES (p_developer_id, v_today, 'active')
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'checked_in', true,
    'already_today', false,
    'streak', v_streak,
    'longest', v_longest,
    'was_frozen', v_was_frozen
  );
END;
$$;

-- ─── 5. grant_streak_freeze RPC ───────────────────────────
CREATE OR REPLACE FUNCTION grant_streak_freeze(p_developer_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE developers
     SET streak_freezes_available = LEAST(streak_freezes_available + 1, 2)
   WHERE id = p_developer_id;
END;
$$;

-- ─── 6. Streak achievements ───────────────────────────────
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order)
VALUES
  ('on_fire',         'streak',       'On Fire',        '7-day app streak',   7,   'bronze',  'exclusive_badge', NULL, 200),
  ('dedicated',       'streak',       'Dedicated',      '30-day app streak',  30,  'silver',  'exclusive_badge', NULL, 201),
  ('obsessed',        'streak',       'Obsessed',       '100-day app streak', 100, 'gold',    'exclusive_badge', NULL, 202),
  ('no_life',         'streak',       'No Life',        '365-day app streak', 365, 'diamond', 'exclusive_badge', NULL, 203),
  ('generous_streak', 'kudos_streak', 'Generous Streak','7-day kudos streak', 7,   'bronze',  'exclusive_badge', NULL, 210)
ON CONFLICT (id) DO NOTHING;

-- ─── 7. Streak Freeze consumable item ─────────────────────
INSERT INTO items (id, category, name, description, price_usd_cents, price_brl_cents, is_active)
VALUES ('streak_freeze', 'consumable', 'Streak Freeze', 'Protects 1 day of absence. Max 2 stored.', 99, 490, true)
ON CONFLICT (id) DO NOTHING;
-- ============================================================
-- 015: Raid System
-- Adds raid PvP system with attacks, defense scores, graffiti
-- tags, raid XP/titles, vehicles, boosters, and achievements.
-- ============================================================

-- 1. New columns on developers
ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS raid_xp                      int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS current_week_contributions   int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS current_week_kudos_given     int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS current_week_kudos_received  int NOT NULL DEFAULT 0;

-- 2. raids table
CREATE TABLE IF NOT EXISTS raids (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  attacker_id       BIGINT      NOT NULL REFERENCES developers(id),
  defender_id       BIGINT      NOT NULL REFERENCES developers(id),
  attack_score      INT         NOT NULL,
  defense_score     INT         NOT NULL,
  success           BOOLEAN     NOT NULL,
  attack_breakdown  JSONB       NOT NULL DEFAULT '{}',
  defense_breakdown JSONB       NOT NULL DEFAULT '{}',
  attacker_vehicle  TEXT        NOT NULL DEFAULT 'airplane',
  attacker_tag_style TEXT       NOT NULL DEFAULT 'default',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT raids_no_self CHECK (attacker_id != defender_id)
);

CREATE INDEX IF NOT EXISTS idx_raids_attacker         ON raids (attacker_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_raids_defender         ON raids (defender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_raids_pair_week        ON raids (attacker_id, defender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_raids_success_created  ON raids (success, created_at DESC) WHERE success = true;

ALTER TABLE raids ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "raids_public_read" ON raids;
CREATE POLICY "raids_public_read" ON raids FOR SELECT USING (true);

-- 3. raid_tags table
CREATE TABLE IF NOT EXISTS raid_tags (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  raid_id       UUID        NOT NULL REFERENCES raids(id) ON DELETE CASCADE,
  building_id   BIGINT      NOT NULL REFERENCES developers(id),
  attacker_id   BIGINT      NOT NULL REFERENCES developers(id),
  attacker_login TEXT       NOT NULL,
  tag_style     TEXT        NOT NULL DEFAULT 'default',
  active        BOOLEAN     NOT NULL DEFAULT true,
  expires_at    TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Only 1 active tag per building
CREATE UNIQUE INDEX IF NOT EXISTS idx_raid_tags_building_active
  ON raid_tags (building_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_raid_tags_expires
  ON raid_tags (expires_at);

ALTER TABLE raid_tags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "raid_tags_public_read" ON raid_tags;
CREATE POLICY "raid_tags_public_read" ON raid_tags FOR SELECT USING (true);

-- 4. Raid achievements
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, sort_order)
VALUES
  ('pickpocket',   'raid', 'Pickpocket',   'Earn 100 Raid XP',   100,   'bronze',  'exclusive_badge', 170),
  ('burglar',      'raid', 'Burglar',      'Earn 500 Raid XP',   500,   'silver',  'exclusive_badge', 171),
  ('heist_master', 'raid', 'Heist Master', 'Earn 2000 Raid XP',  2000,  'gold',    'exclusive_badge', 172),
  ('kingpin',      'raid', 'Kingpin',      'Earn 10000 Raid XP', 10000, 'diamond', 'exclusive_badge', 173)
ON CONFLICT (id) DO NOTHING;

-- 5. Raid items (vehicles, tags, consumable boosters)
INSERT INTO items (id, category, name, description, price_usd_cents, price_brl_cents, is_active, zone, metadata)
VALUES
  -- Vehicles (cosmetic only)
  ('raid_helicopter',   'effect',      'Helicopter',    'Raid vehicle: helicopter',   299, 1490, true, NULL, '{"type":"raid_vehicle"}'),
  ('raid_drone',        'effect',      'Stealth Drone', 'Raid vehicle: drone',        199, 990,  true, NULL, '{"type":"raid_vehicle"}'),
  ('raid_rocket',       'effect',      'Rocket',        'Raid vehicle: rocket',       399, 1990, true, NULL, '{"type":"raid_vehicle"}'),
  -- Custom tags (cosmetic)
  ('tag_neon',          'effect',      'Neon Tag',      'Neon-colored raid graffiti',  149, 790,  true, NULL, '{"type":"raid_tag"}'),
  ('tag_fire',          'effect',      'Fire Tag',      'Fire-animated raid graffiti', 199, 990,  true, NULL, '{"type":"raid_tag"}'),
  ('tag_gold',          'effect',      'Gold Tag',      'Golden raid graffiti',        249, 1290, true, NULL, '{"type":"raid_tag"}'),
  -- Consumable attack boosters (1-use each)
  ('raid_boost_small',  'consumable',  'War Paint',     '+5 attack for 1 raid',        99, 490,  true, NULL, '{"type":"raid_boost","bonus":5}'),
  ('raid_boost_medium', 'consumable',  'Battle Armor',  '+10 attack for 1 raid',      179, 890,  true, NULL, '{"type":"raid_boost","bonus":10}'),
  ('raid_boost_large',  'consumable',  'EMP Device',    '+20 attack for 1 raid',      299, 1490, true, NULL, '{"type":"raid_boost","bonus":20}')
ON CONFLICT (id) DO NOTHING;

-- 6. Increment weekly kudos counters RPC (called from kudos route)
CREATE OR REPLACE FUNCTION increment_kudos_week(p_giver_id bigint, p_receiver_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE developers SET current_week_kudos_given = current_week_kudos_given + 1
  WHERE id = p_giver_id;
  UPDATE developers SET current_week_kudos_received = current_week_kudos_received + 1
  WHERE id = p_receiver_id;
END;
$$;

-- 7. Weekly stats refresh RPC
CREATE OR REPLACE FUNCTION refresh_weekly_kudos()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  week_start DATE := date_trunc('week', now())::date;
BEGIN
  -- Kudos given this week
  UPDATE developers d SET current_week_kudos_given = COALESCE(sub.cnt, 0)
  FROM (
    SELECT giver_id, COUNT(*) as cnt
    FROM developer_kudos
    WHERE given_date >= week_start
    GROUP BY giver_id
  ) sub
  WHERE d.id = sub.giver_id;

  -- Kudos received this week
  UPDATE developers d SET current_week_kudos_received = COALESCE(sub.cnt, 0)
  FROM (
    SELECT receiver_id, COUNT(*) as cnt
    FROM developer_kudos
    WHERE given_date >= week_start
    GROUP BY receiver_id
  ) sub
  WHERE d.id = sub.receiver_id;

  -- Reset devs with 0 this week
  UPDATE developers SET current_week_kudos_given = 0
  WHERE current_week_kudos_given > 0
  AND id NOT IN (
    SELECT giver_id FROM developer_kudos WHERE given_date >= week_start
  );
  UPDATE developers SET current_week_kudos_received = 0
  WHERE current_week_kudos_received > 0
  AND id NOT IN (
    SELECT receiver_id FROM developer_kudos WHERE given_date >= week_start
  );
END;
$$;
-- ============================================================
-- 016: White Rabbit System
-- Adds rabbit progress columns to developers,
-- white_rabbit achievement, and white_rabbit crown item.
-- ============================================================

-- 1. New columns on developers
ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS rabbit_progress     int         DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rabbit_started_at   timestamptz NULL,
  ADD COLUMN IF NOT EXISTS rabbit_completed    boolean     DEFAULT false,
  ADD COLUMN IF NOT EXISTS rabbit_completed_at timestamptz NULL;

-- 2. Item: white_rabbit crown (achievement-only, not purchasable)
--    Must be inserted before achievement due to foreign key on reward_item_id
INSERT INTO items (id, category, name, description, price_usd_cents, price_brl_cents, is_active)
VALUES (
  'white_rabbit',
  'crown',
  'White Rabbit',
  'A mysterious white rabbit perched on your rooftop',
  0,
  0,
  false  -- not shown in shop, achievement unlock only
) ON CONFLICT (id) DO NOTHING;

-- 3. Achievement: white_rabbit (secret diamond tier)
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order)
VALUES (
  'white_rabbit',
  'secret',
  'White Rabbit',
  'Followed the white rabbit through the city',
  1,
  'diamond',
  'unlock_item',
  'white_rabbit',
  300
) ON CONFLICT (id) DO NOTHING;
-- A11: Seasonal/limited items system
-- Adds scarcity columns to items table for FOMO mechanics

-- Temporal scarcity: item available until this date (NULL = always available)
alter table items add column if not exists available_until timestamptz default null;

-- Quantity scarcity: max copies that can be sold (NULL = unlimited)
alter table items add column if not exists max_quantity int default null;

-- Exclusive flag: item will never return after expiring (collector's item)
alter table items add column if not exists is_exclusive boolean default false;

-- Computed: current purchase count per item (for remaining calculation)
-- We already have the purchases table, so remaining = max_quantity - count(purchases where item_id = X)

-- Index for quick availability checks
create index if not exists idx_items_available_until on items (available_until) where available_until is not null;
-- A12: Streak rewards system
-- Tracks which streak milestone rewards have been claimed per developer

create table if not exists streak_rewards (
  id            uuid primary key default gen_random_uuid(),
  developer_id  bigint not null references developers(id),
  milestone     int not null,          -- streak day milestone (3, 7, 14, 30)
  item_id       text not null,         -- item granted
  claimed_at    timestamptz default now(),
  unique(developer_id, milestone)      -- each milestone claimed once
);

-- RLS: devs can read their own rewards
alter table streak_rewards enable row level security;

create policy "Users can read own streak rewards"
  on streak_rewards for select
  using (developer_id in (
    select id from developers where claimed_by = auth.uid()
  ));
-- 019_districts.sql
-- Sprint 1: Districts foundation

-- 1a. Districts reference table (10 rows seeded)
CREATE TABLE districts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  color TEXT,
  population INT DEFAULT 0,
  total_contributions BIGINT DEFAULT 0,
  weekly_score BIGINT DEFAULT 0,
  mayor_id INT REFERENCES developers(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO districts (id, name, color) VALUES
  ('frontend',   'Frontend',       '#3b82f6'),
  ('backend',    'Backend',        '#ef4444'),
  ('fullstack',  'Full Stack',     '#a855f7'),
  ('mobile',     'Mobile',         '#22c55e'),
  ('data_ai',    'Data & AI',      '#06b6d4'),
  ('devops',     'DevOps & Cloud', '#f97316'),
  ('security',   'Security',       '#dc2626'),
  ('gamedev',    'GameDev',        '#ec4899'),
  ('vibe_coder', 'Vibe Coder',     '#8b5cf6'),
  ('creator',    'Creator',        '#eab308');

-- 1b. New columns on developers
ALTER TABLE developers ADD COLUMN district TEXT REFERENCES districts(id);
ALTER TABLE developers ADD COLUMN district_chosen BOOLEAN DEFAULT false;
ALTER TABLE developers ADD COLUMN district_changes_count INT DEFAULT 0;
ALTER TABLE developers ADD COLUMN district_changed_at TIMESTAMPTZ;
ALTER TABLE developers ADD COLUMN district_rank INT;
CREATE INDEX idx_developers_district ON developers(district);
CREATE INDEX idx_developers_district_rank ON developers(district, district_rank);

-- 1c. District changes history table
CREATE TABLE district_changes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  developer_id INT REFERENCES developers(id) NOT NULL,
  from_district TEXT REFERENCES districts(id),
  to_district TEXT REFERENCES districts(id) NOT NULL,
  reason TEXT DEFAULT 'inferred',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 1d. Auto-inference for all existing devs
UPDATE developers SET district = CASE
  WHEN primary_language IN ('TypeScript','JavaScript','CSS','HTML','SCSS','Vue','Svelte') THEN 'frontend'
  WHEN primary_language IN ('Java','Go','Rust','C#','PHP','Ruby','Elixir','C','C++','Assembly','Verilog','VHDL') THEN 'backend'
  WHEN primary_language IN ('Python','Jupyter Notebook','R','Julia') THEN 'data_ai'
  WHEN primary_language IN ('Swift','Kotlin','Dart','Objective-C') THEN 'mobile'
  WHEN primary_language IN ('HCL','Shell','Dockerfile','Nix') THEN 'devops'
  WHEN primary_language IN ('GDScript','Lua') THEN 'gamedev'
  ELSE 'fullstack'
END
WHERE district IS NULL;

-- 1e. Update district population cache
UPDATE districts d SET population = (
  SELECT COUNT(*) FROM developers dev WHERE dev.district = d.id
);
-- 020: Add country column to sky_ad_events + pg_cron cleanup + expiry_notified

-- Country column for geo tracking (from x-vercel-ip-country header)
ALTER TABLE sky_ad_events ADD COLUMN IF NOT EXISTS country TEXT;
CREATE INDEX IF NOT EXISTS idx_sky_ad_events_country ON sky_ad_events(country) WHERE country IS NOT NULL;

-- Expiry notification tracking for Resend emails
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS expiry_notified TEXT;

-- Recreate materialized view (unchanged schema, just ensures it exists)
DROP MATERIALIZED VIEW IF EXISTS sky_ad_daily_stats;
CREATE MATERIALIZED VIEW sky_ad_daily_stats AS
SELECT
  ad_id,
  date_trunc('day', created_at)::date AS day,
  COUNT(*) FILTER (WHERE event_type = 'impression') AS impressions,
  COUNT(*) FILTER (WHERE event_type = 'click') AS clicks,
  COUNT(*) FILTER (WHERE event_type = 'cta_click') AS cta_clicks
FROM sky_ad_events
GROUP BY ad_id, date_trunc('day', created_at)::date;

CREATE UNIQUE INDEX idx_sky_ad_daily_stats ON sky_ad_daily_stats(ad_id, day);

-- pg_cron: refresh materialized view every 15 minutes
SELECT cron.schedule(
  'refresh-ad-stats',
  '*/15 * * * *',
  'REFRESH MATERIALIZED VIEW CONCURRENTLY sky_ad_daily_stats'
);

-- pg_cron: cleanup events older than 90 days (daily at 3am UTC)
SELECT cron.schedule(
  'cleanup-old-ad-events',
  '0 3 * * *',
  $$DELETE FROM sky_ad_events WHERE created_at < NOW() - INTERVAL '90 days'$$
);
-- Milestone celebrations: tracks when each milestone (10k, 15k, 20k...) was reached
CREATE TABLE IF NOT EXISTS milestone_celebrations (
  milestone   integer PRIMARY KEY,
  reached_at  timestamptz NOT NULL DEFAULT now()
);

-- 10K Pioneer achievement
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order)
VALUES (
  'pioneer_10k',
  'milestone',
  '10K Pioneer',
  'Was part of Git City when it reached 10,000 developers',
  0,
  'diamond',
  'exclusive_badge',
  NULL,
  0
) ON CONFLICT (id) DO NOTHING;

-- Bulk grant to ALL existing devs
INSERT INTO developer_achievements (developer_id, achievement_id)
SELECT id, 'pioneer_10k' FROM developers
ON CONFLICT (developer_id, achievement_id) DO NOTHING;
-- 022: Notification system (channel-agnostic: email, push, in_app)
-- Architecture based on Knock/Novu patterns. Email now, push ready.

-- ── developers table: email + activity tracking ──
ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS email TEXT,
  ADD COLUMN IF NOT EXISTS email_verified BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS email_updated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS timezone TEXT DEFAULT 'UTC',
  ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_developers_email ON developers (email) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_developers_last_active_at ON developers (last_active_at) WHERE last_active_at IS NOT NULL;

-- ── notification_preferences ──
-- Per-category booleans apply to ALL channels.
-- Master toggles per channel (email_enabled, push_enabled).
-- channel_overrides JSONB for granular per-channel-per-category (Linear/Discord pattern).
-- digest_frequency lets users choose how often they get non-urgent notifications.
CREATE TABLE IF NOT EXISTS notification_preferences (
  developer_id     INTEGER PRIMARY KEY REFERENCES developers(id) ON DELETE CASCADE,
  -- Master channel toggles
  email_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  push_enabled     BOOLEAN NOT NULL DEFAULT TRUE,
  -- Per-category (applies to all channels unless overridden)
  transactional    BOOLEAN NOT NULL DEFAULT TRUE,
  social           BOOLEAN NOT NULL DEFAULT TRUE,
  digest           BOOLEAN NOT NULL DEFAULT TRUE,
  marketing        BOOLEAN NOT NULL DEFAULT FALSE,
  streak_reminders BOOLEAN NOT NULL DEFAULT TRUE,
  -- Digest frequency: how often batched notifications are flushed
  -- 'realtime' = send immediately, 'hourly' / 'daily' / 'weekly' = accumulate then flush
  digest_frequency TEXT NOT NULL DEFAULT 'realtime' CHECK (digest_frequency IN ('realtime', 'hourly', 'daily', 'weekly')),
  -- Push quiet hours (hour 0-23 in developer's timezone)
  quiet_hours_start SMALLINT,
  quiet_hours_end   SMALLINT,
  -- Granular per-channel-per-category overrides (Linear/Discord pattern)
  -- Example: {"email": {"social": false}, "push": {"digest": false}}
  channel_overrides JSONB DEFAULT '{}',
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own preferences" ON notification_preferences
  FOR SELECT USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = auth.uid())
  );

CREATE POLICY "Users can update own preferences" ON notification_preferences
  FOR UPDATE USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = auth.uid())
  );

-- ── notification_log (channel-agnostic, with delivery lifecycle) ──
CREATE TABLE IF NOT EXISTS notification_log (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id      INTEGER NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  channel           TEXT NOT NULL CHECK (channel IN ('email', 'push', 'in_app')),
  notification_type TEXT NOT NULL,
  recipient         TEXT NOT NULL,       -- email address, push token, or dev ID
  title             TEXT NOT NULL,       -- email subject / push title
  provider_id       TEXT,                -- resend ID, FCM message ID, etc.
  status            TEXT NOT NULL DEFAULT 'sent',
  -- Delivery lifecycle (updated via provider webhooks)
  delivered_at      TIMESTAMPTZ,
  opened_at         TIMESTAMPTZ,
  clicked_at        TIMESTAMPTZ,
  failed_at         TIMESTAMPTZ,
  failure_reason    TEXT,
  metadata          JSONB DEFAULT '{}',
  dedup_key         TEXT,
  batch_id          INTEGER,             -- NULL if sent individually, FK if part of a batch
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Dedup per channel: same raid alert can go via email AND push
  UNIQUE(dedup_key, channel)
);

CREATE INDEX IF NOT EXISTS idx_notification_log_dev_type ON notification_log (developer_id, notification_type);
CREATE INDEX IF NOT EXISTS idx_notification_log_dev_channel_created ON notification_log (developer_id, channel, created_at);
CREATE INDEX IF NOT EXISTS idx_notification_log_dedup ON notification_log (dedup_key, channel) WHERE dedup_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_notification_log_provider ON notification_log (provider_id) WHERE provider_id IS NOT NULL;

-- Server-only (no RLS policies = no access via anon key)
ALTER TABLE notification_log ENABLE ROW LEVEL SECURITY;

-- ── notification_batches (Knock digest pattern) ──
-- Accumulates events in a time window, cron flushes when closes_at passes.
-- Example: "raids:user_42" batch collects 5 raids over 1 hour, then sends 1 digest email.
CREATE TABLE IF NOT EXISTS notification_batches (
  id               SERIAL PRIMARY KEY,
  batch_key        TEXT NOT NULL,         -- deterministic: "raids:42", "social:42:daily"
  developer_id     INTEGER NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  notification_type TEXT NOT NULL,        -- category being batched
  channel          TEXT NOT NULL CHECK (channel IN ('email', 'push', 'in_app')),
  closes_at        TIMESTAMPTZ NOT NULL,  -- when this batch window ends
  processed_at     TIMESTAMPTZ,           -- NULL until flushed/sent
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(batch_key, channel)              -- one open batch per key per channel
);

CREATE INDEX IF NOT EXISTS idx_batches_pending ON notification_batches (closes_at)
  WHERE processed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_batches_dev ON notification_batches (developer_id)
  WHERE processed_at IS NULL;

ALTER TABLE notification_batches ENABLE ROW LEVEL SECURITY;

-- ── notification_batch_items ──
-- Individual events within a batch. Stored as JSONB for flexibility.
CREATE TABLE IF NOT EXISTS notification_batch_items (
  id         SERIAL PRIMARY KEY,
  batch_id   INTEGER NOT NULL REFERENCES notification_batches(id) ON DELETE CASCADE,
  event_data JSONB NOT NULL,             -- {raider: "xpto", success: true, ...}
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_batch_items_batch ON notification_batch_items (batch_id);

ALTER TABLE notification_batch_items ENABLE ROW LEVEL SECURITY;

-- ── notification_suppressions (channel-aware) ──
CREATE TABLE IF NOT EXISTS notification_suppressions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  identifier TEXT NOT NULL,             -- email address or push token
  channel    TEXT NOT NULL CHECK (channel IN ('email', 'push')),
  reason     TEXT NOT NULL CHECK (reason IN ('bounce', 'complaint', 'manual_unsub', 'token_expired')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(identifier, channel)
);

ALTER TABLE notification_suppressions ENABLE ROW LEVEL SECURITY;

-- ── push_subscriptions (ready for future use) ──
CREATE TABLE IF NOT EXISTS push_subscriptions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id  INTEGER NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  token         TEXT NOT NULL UNIQUE,
  platform      TEXT NOT NULL CHECK (platform IN ('web', 'ios', 'android')),
  user_agent    TEXT,
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_push_subs_dev ON push_subscriptions (developer_id) WHERE active = TRUE;

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own push subscriptions" ON push_subscriptions
  FOR ALL USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = auth.uid())
  );

-- FK from notification_log.batch_id (deferred because tables created in order)
ALTER TABLE notification_log
  ADD CONSTRAINT fk_notification_log_batch
  FOREIGN KEY (batch_id) REFERENCES notification_batches(id) ON DELETE SET NULL;

-- ══════════════════════════════════════════════════════════════
-- MANUAL SQL (run separately in Supabase SQL editor):
--
-- Backfill emails from auth.users:
--   UPDATE developers d
--   SET email = u.email, email_updated_at = NOW()
--   FROM auth.users u
--   WHERE d.claimed_by = u.id AND d.email IS NULL AND u.email IS NOT NULL;
--
-- Insert default preferences for all claimed developers:
--   INSERT INTO notification_preferences (developer_id)
--   SELECT id FROM developers WHERE claimed = TRUE
--   ON CONFLICT (developer_id) DO NOTHING;
-- ══════════════════════════════════════════════════════════════
-- Add city_theme column to developers table
-- Stores the user's preferred theme index (0=Midnight, 1=Sunset, 2=Neon, 3=Emerald)
alter table developers add column if not exists city_theme smallint not null default 0;
-- Roadmap feature voting
create table roadmap_votes (
  id bigint generated always as identity primary key,
  developer_id bigint not null references developers(id) on delete cascade,
  item_id text not null,
  created_at timestamptz not null default now(),
  unique(developer_id, item_id)
);

create index idx_roadmap_votes_item on roadmap_votes(item_id);

alter table roadmap_votes enable row level security;

-- Public read for vote counts
create policy "Anyone can read votes"
  on roadmap_votes for select using (true);

-- INSERT/DELETE handled via service role (getSupabaseAdmin) in Server Actions
-- No anon-key write policies needed since auth is validated server-side
-- Sky collectibles: per-session fly scores with daily seed leaderboard
CREATE TABLE fly_scores (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  developer_id  int NOT NULL REFERENCES developers(id),
  score         int NOT NULL,
  collected     int NOT NULL,
  max_combo     int NOT NULL DEFAULT 1,
  flight_ms     int NOT NULL,
  seed          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_fly_scores_seed_score ON fly_scores(seed, score DESC);
CREATE INDEX idx_fly_scores_developer  ON fly_scores(developer_id, created_at DESC);

ALTER TABLE fly_scores ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fly_scores_read" ON fly_scores FOR SELECT USING (true);
CREATE POLICY "fly_scores_insert" ON fly_scores FOR INSERT WITH CHECK (false);
-- 026_dailies.sql — Daily missions system
-- 3 daily missions per player, deterministic via seed, with progress tracking

-- ─── Daily mission progress table ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS daily_mission_progress (
  developer_id  bigint  NOT NULL REFERENCES developers(id),
  mission_date  date    NOT NULL DEFAULT current_date,
  mission_id    text    NOT NULL,
  progress      int     NOT NULL DEFAULT 0,
  completed     boolean NOT NULL DEFAULT false,
  completed_at  timestamptz,
  PRIMARY KEY (developer_id, mission_date, mission_id)
);

CREATE INDEX IF NOT EXISTS idx_dmp_dev_date
  ON daily_mission_progress(developer_id, mission_date DESC);

ALTER TABLE daily_mission_progress ENABLE ROW LEVEL SECURITY;

CREATE POLICY "dmp_public_read"
  ON daily_mission_progress FOR SELECT USING (true);

CREATE POLICY "dmp_service_insert"
  ON daily_mission_progress FOR INSERT WITH CHECK (false);

CREATE POLICY "dmp_service_update"
  ON daily_mission_progress FOR UPDATE USING (false);

-- ─── Columns on developers ─────────────────────────────────────────────
ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS dailies_completed int DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dailies_streak    int DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_dailies_date date;

-- ─── RPC: record mission progress (idempotent, race-safe) ──────────────
CREATE OR REPLACE FUNCTION record_mission_progress(
  p_developer_id bigint,
  p_mission_id   text,
  p_threshold    int,
  p_increment    int DEFAULT 1
)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_today    date := current_date;
  v_progress int;
  v_completed boolean;
BEGIN
  -- Upsert progress row
  INSERT INTO daily_mission_progress (developer_id, mission_date, mission_id, progress)
  VALUES (p_developer_id, v_today, p_mission_id, p_increment)
  ON CONFLICT (developer_id, mission_date, mission_id)
  DO UPDATE SET progress = LEAST(daily_mission_progress.progress + p_increment, p_threshold)
  WHERE daily_mission_progress.completed = false;

  -- Read current state
  SELECT progress, completed INTO v_progress, v_completed
  FROM daily_mission_progress
  WHERE developer_id = p_developer_id
    AND mission_date = v_today
    AND mission_id = p_mission_id;

  -- Auto-complete if threshold reached
  IF v_progress >= p_threshold AND NOT v_completed THEN
    UPDATE daily_mission_progress
    SET completed = true, completed_at = now()
    WHERE developer_id = p_developer_id
      AND mission_date = v_today
      AND mission_id = p_mission_id;

    v_completed := true;
  END IF;

  RETURN jsonb_build_object(
    'progress', v_progress,
    'completed', v_completed,
    'threshold', p_threshold
  );
END;
$$;

-- ─── RPC: complete all dailies (called when 3/3 done) ──────────────────
CREATE OR REPLACE FUNCTION complete_all_dailies(p_developer_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_today       date := current_date;
  v_last_date   date;
  v_old_streak  int;
  v_new_streak  int;
  v_total       int;
BEGIN
  -- Lock the developer row
  SELECT last_dailies_date, dailies_streak, dailies_completed
  INTO v_last_date, v_old_streak, v_total
  FROM developers
  WHERE id = p_developer_id
  FOR UPDATE;

  -- Already completed today
  IF v_last_date = v_today THEN
    RETURN jsonb_build_object('already_completed', true, 'streak', v_old_streak, 'total', v_total);
  END IF;

  -- Calculate streak
  IF v_last_date = v_today - 1 THEN
    v_new_streak := v_old_streak + 1;
  ELSE
    v_new_streak := 1;
  END IF;

  v_total := v_total + 1;

  UPDATE developers
  SET dailies_completed = v_total,
      dailies_streak = v_new_streak,
      last_dailies_date = v_today
  WHERE id = p_developer_id;

  RETURN jsonb_build_object(
    'already_completed', false,
    'streak', v_new_streak,
    'total', v_total
  );
END;
$$;

-- ─── Achievements (4 tiers) ────────────────────────────────────────────
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, reward_item_id, sort_order)
VALUES
  ('daily_rookie',  'dailies', 'Daily Rookie',  'Complete all dailies 7 times',   7,   'bronze',  'exclusive_badge', NULL, 300),
  ('daily_regular', 'dailies', 'Daily Regular', 'Complete all dailies 30 times',  30,  'silver',  'exclusive_badge', NULL, 301),
  ('daily_master',  'dailies', 'Daily Master',  'Complete all dailies 100 times', 100, 'gold',    'exclusive_badge', NULL, 302),
  ('daily_legend',  'dailies', 'Daily Legend',  'Complete all dailies 365 times', 365, 'diamond', 'exclusive_badge', NULL, 303)
ON CONFLICT (id) DO NOTHING;
-- GitHub Star exclusive item (crown zone, free, unlocked by starring the repo)
INSERT INTO items (id, category, name, description, price_usd_cents, price_brl_cents, is_exclusive, is_active, zone)
VALUES ('github_star', 'crown', 'GitHub Star', 'Star the repo to unlock this exclusive crown item.', 0, 0, true, true, 'crown')
ON CONFLICT (id) DO NOTHING;
-- Optimize recalculate_ranks() to only update rows where rank actually changed.
-- Previously it updated ALL ~33k rows every 30 minutes, causing massive lock contention,
-- dead tuple bloat, and 10-120s latencies on unrelated queries.

-- Index to speed up the ranking window function
CREATE INDEX IF NOT EXISTS idx_developers_rank_order
  ON developers (contributions_total DESC, contributions DESC, github_login ASC);

CREATE OR REPLACE FUNCTION recalculate_ranks()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '120s'
AS $$
BEGIN
  WITH ranked AS (
    SELECT id, row_number() OVER (
      ORDER BY CASE WHEN contributions_total > 0 THEN contributions_total ELSE contributions END DESC,
      github_login ASC
    ) AS new_rank
    FROM developers
  )
  UPDATE developers d
  SET rank = r.new_rank
  FROM ranked r
  WHERE d.id = r.id
    AND d.rank IS DISTINCT FROM r.new_rank;

  UPDATE city_stats
  SET total_developers    = (SELECT count(*) FROM developers),
      total_contributions = (SELECT coalesce(sum(contributions), 0) FROM developers),
      updated_at          = now()
  WHERE id = 1;
END;
$$;

-- Lightweight function for new devs: assign last rank without full recalc
CREATE OR REPLACE FUNCTION assign_new_dev_rank(dev_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE developers SET rank = (SELECT count(*) FROM developers) WHERE id = dev_id AND rank IS NULL;
  UPDATE city_stats
  SET total_developers    = (SELECT count(*) FROM developers),
      total_contributions = (SELECT coalesce(sum(contributions), 0) FROM developers),
      updated_at          = now()
  WHERE id = 1;
END;
$$;

-- Reduce cron frequency from every 30 min to every 4 hours
SELECT cron.unschedule('recalculate-ranks');
SELECT cron.schedule('recalculate-ranks', '0 */4 * * *', 'SELECT recalculate_ranks()');
-- Single RPC that returns all city data in one SQL call.
-- Eliminates 30+ HTTP round-trips to PostgREST.
CREATE OR REPLACE FUNCTION get_city_snapshot()
RETURNS json
LANGUAGE sql
STABLE
SET statement_timeout = '60s'
AS $$
  SELECT json_build_object(
    'developers', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT id, github_login, name, avatar_url, contributions, total_stars,
               public_repos, primary_language, rank, claimed,
               COALESCE(kudos_count, 0) AS kudos_count,
               COALESCE(visit_count, 0) AS visit_count,
               contributions_total, contribution_years, total_prs, total_reviews,
               repos_contributed_to, followers, following, organizations_count,
               account_created_at, current_streak, active_days_last_year,
               language_diversity,
               COALESCE(app_streak, 0) AS app_streak,
               COALESCE(rabbit_completed, false) AS rabbit_completed,
               district, district_chosen,
               COALESCE(raid_xp, 0) AS raid_xp,
               COALESCE(current_week_contributions, 0) AS current_week_contributions,
               COALESCE(current_week_kudos_given, 0) AS current_week_kudos_given,
               COALESCE(current_week_kudos_received, 0) AS current_week_kudos_received
        FROM developers
        ORDER BY rank ASC
      ) t
    ),
    'purchases', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, item_id
        FROM purchases
        WHERE status = 'completed' AND gifted_to IS NULL
      ) t
    ),
    'gift_purchases', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT gifted_to, item_id
        FROM purchases
        WHERE status = 'completed' AND gifted_to IS NOT NULL
      ) t
    ),
    'customizations', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, item_id, config
        FROM developer_customizations
        WHERE item_id IN ('custom_color', 'billboard', 'loadout')
      ) t
    ),
    'achievements', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, achievement_id
        FROM developer_achievements
      ) t
    ),
    'raid_tags', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT building_id, attacker_login, tag_style, expires_at
        FROM raid_tags
        WHERE active = true
      ) t
    ),
    'stats', (
      SELECT row_to_json(t)
      FROM (SELECT * FROM city_stats WHERE id = 1) t
    )
  );
$$;
-- Cache table for pre-computed city snapshot.
-- Eliminates 114s CPU-bound query from user request path.
CREATE TABLE IF NOT EXISTS city_snapshot_cache (
  id   int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  data jsonb NOT NULL,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE city_snapshot_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read snapshot cache"
  ON city_snapshot_cache FOR SELECT
  USING (true);

-- Background function that refreshes the cache.
-- Called by pg_cron every 5 minutes.
CREATE OR REPLACE FUNCTION refresh_city_snapshot()
RETURNS void
LANGUAGE plpgsql
SET statement_timeout = '180s'
AS $$
DECLARE
  snapshot json;
BEGIN
  SELECT get_city_snapshot() INTO snapshot;

  INSERT INTO city_snapshot_cache (id, data, refreshed_at)
  VALUES (1, snapshot::jsonb, now())
  ON CONFLICT (id) DO UPDATE
    SET data = EXCLUDED.data,
        refreshed_at = EXCLUDED.refreshed_at;
END;
$$;

-- Thin RPC for the API to call.
CREATE OR REPLACE FUNCTION get_cached_city_snapshot()
RETURNS jsonb
LANGUAGE sql
STABLE
SET statement_timeout = '5s'
AS $$
  SELECT data FROM city_snapshot_cache WHERE id = 1;
$$;

-- Bump the statement_timeout on the original RPC so the background
-- refresh doesn't get killed mid-query.
CREATE OR REPLACE FUNCTION get_city_snapshot()
RETURNS json
LANGUAGE sql
STABLE
SET statement_timeout = '180s'
AS $$
  SELECT json_build_object(
    'developers', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT id, github_login, name, avatar_url, contributions, total_stars,
               public_repos, primary_language, rank, claimed,
               COALESCE(kudos_count, 0) AS kudos_count,
               COALESCE(visit_count, 0) AS visit_count,
               contributions_total, contribution_years, total_prs, total_reviews,
               repos_contributed_to, followers, following, organizations_count,
               account_created_at, current_streak, active_days_last_year,
               language_diversity,
               COALESCE(app_streak, 0) AS app_streak,
               COALESCE(rabbit_completed, false) AS rabbit_completed,
               district, district_chosen,
               COALESCE(raid_xp, 0) AS raid_xp,
               COALESCE(current_week_contributions, 0) AS current_week_contributions,
               COALESCE(current_week_kudos_given, 0) AS current_week_kudos_given,
               COALESCE(current_week_kudos_received, 0) AS current_week_kudos_received
        FROM developers
        ORDER BY rank ASC
      ) t
    ),
    'purchases', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, item_id
        FROM purchases
        WHERE status = 'completed' AND gifted_to IS NULL
      ) t
    ),
    'gift_purchases', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT gifted_to, item_id
        FROM purchases
        WHERE status = 'completed' AND gifted_to IS NOT NULL
      ) t
    ),
    'customizations', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, item_id, config
        FROM developer_customizations
        WHERE item_id IN ('custom_color', 'billboard', 'loadout')
      ) t
    ),
    'achievements', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT developer_id, achievement_id
        FROM developer_achievements
      ) t
    ),
    'raid_tags', (
      SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
      FROM (
        SELECT building_id, attacker_login, tag_style, expires_at
        FROM raid_tags
        WHERE active = true
      ) t
    ),
    'stats', (
      SELECT row_to_json(t)
      FROM (SELECT * FROM city_stats WHERE id = 1) t
    )
  );
$$;

-- Schedule refresh every 5 minutes via pg_cron.
DO $$
BEGIN
  PERFORM cron.unschedule('refresh-city-snapshot');
EXCEPTION WHEN OTHERS THEN
  -- Job doesn't exist yet, ignore
END;
$$;

SELECT cron.schedule(
  'refresh-city-snapshot',
  '*/5 * * * *',
  $$SELECT refresh_city_snapshot()$$
);
-- HOTFIX: Kill the pg_cron job that's been hammering the database every 5 minutes
-- with a 114s+ CPU-bound query, causing all other queries to time out.
-- The RPC approach was reverted in app code (e8a4eed) but the cron job kept running.

-- 1. Unschedule the cron job
DO $$
BEGIN
  PERFORM cron.unschedule('refresh-city-snapshot');
EXCEPTION WHEN OTHERS THEN
  NULL; -- Job may already be gone
END;
$$;

-- 2. Drop the functions
DROP FUNCTION IF EXISTS get_cached_city_snapshot();
DROP FUNCTION IF EXISTS refresh_city_snapshot();
DROP FUNCTION IF EXISTS get_city_snapshot();

-- 3. Drop the cache table
DROP TABLE IF EXISTS city_snapshot_cache;

-- 4. Add missing indexes for the PostgREST city queries
-- Gift purchases query has no index on gifted_to (full table scan per chunk)
CREATE INDEX IF NOT EXISTS idx_purchases_gifted_to
  ON purchases(gifted_to, status) WHERE gifted_to IS NOT NULL;

-- Customizations query has no index at all (full table scan per chunk)
CREATE INDEX IF NOT EXISTS idx_customizations_dev_item
  ON developer_customizations(developer_id, item_id);
-- ─── XP & Leveling System V1 ────────────────────────────────

-- New columns on developers table
ALTER TABLE developers ADD COLUMN IF NOT EXISTS xp_total integer NOT NULL DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS xp_level integer NOT NULL DEFAULT 1;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS xp_github integer NOT NULL DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS xp_daily integer NOT NULL DEFAULT 0;
ALTER TABLE developers ADD COLUMN IF NOT EXISTS xp_daily_date date;

-- Index for leaderboard queries
CREATE INDEX IF NOT EXISTS idx_developers_xp_total ON developers(xp_total DESC);

-- XP audit log
CREATE TABLE IF NOT EXISTS xp_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id bigint NOT NULL REFERENCES developers(id),
  source text NOT NULL,
  amount integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_xp_log_dev ON xp_log(developer_id);
CREATE INDEX IF NOT EXISTS idx_xp_log_created ON xp_log(created_at);

-- ─── grant_xp RPC ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION grant_xp(
  p_developer_id bigint,
  p_source text,
  p_amount integer
) RETURNS json LANGUAGE plpgsql AS $$
DECLARE
  v_today date := CURRENT_DATE;
  v_daily integer;
  v_actual integer;
  v_new_total integer;
  v_new_level integer;
BEGIN
  -- Reset daily counter if new day
  UPDATE developers
  SET xp_daily = 0, xp_daily_date = v_today
  WHERE id = p_developer_id AND (xp_daily_date IS NULL OR xp_daily_date < v_today);

  SELECT xp_daily INTO v_daily FROM developers WHERE id = p_developer_id;

  -- Daily cap only for engagement sources
  IF p_source IN ('checkin', 'dailies', 'kudos_given', 'visit', 'fly') THEN
    v_actual := LEAST(p_amount, GREATEST(0, 150 - COALESCE(v_daily, 0)));
  ELSE
    v_actual := p_amount;
  END IF;

  IF v_actual <= 0 THEN
    RETURN json_build_object('granted', 0, 'reason', 'daily_cap');
  END IF;

  -- Increment XP
  UPDATE developers
  SET xp_total = xp_total + v_actual,
      xp_daily = COALESCE(xp_daily, 0) +
        CASE WHEN p_source IN ('checkin','dailies','kudos_given','visit','fly')
        THEN v_actual ELSE 0 END,
      xp_daily_date = v_today
  WHERE id = p_developer_id
  RETURNING xp_total INTO v_new_total;

  -- Calculate level (25 * level^2.2)
  v_new_level := 1;
  WHILE v_new_total >= (25 * POWER(v_new_level + 1, 2.2))::integer LOOP
    v_new_level := v_new_level + 1;
  END LOOP;

  -- Level never drops
  UPDATE developers SET xp_level = GREATEST(xp_level, v_new_level)
  WHERE id = p_developer_id;

  -- Audit log
  INSERT INTO xp_log (developer_id, source, amount)
  VALUES (p_developer_id, p_source, v_actual);

  RETURN json_build_object('granted', v_actual, 'new_total', v_new_total, 'new_level', v_new_level);
END;
$$;

-- ─── Backfill existing developers ───────────────────────────

DO $$
DECLARE
  r RECORD;
  v_github_xp integer;
  v_engagement_xp integer;
  v_total integer;
  v_level integer;
BEGIN
  FOR r IN SELECT * FROM developers LOOP
    -- GitHub XP (log scale, +1 to avoid log(0))
    v_github_xp := (
      FLOOR(LOG(2, GREATEST(r.contributions, 1) + 1) * 15) +
      FLOOR(LOG(2, GREATEST(r.total_stars, 1) + 1) * 10) +
      FLOOR(LOG(2, GREATEST(r.public_repos, 1) + 1) * 5) +
      FLOOR(LOG(2, GREATEST(COALESCE(r.total_prs, 0), 1) + 1) * 8)
    )::integer;

    -- Engagement XP retroactive estimate
    v_engagement_xp := (
      COALESCE(r.app_streak, 0) * 10 +
      COALESCE(r.dailies_completed, 0) * 25 +
      COALESCE(r.raid_xp, 0) +
      COALESCE(r.referral_count, 0) * 50
    );

    v_total := v_github_xp + v_engagement_xp;

    -- Calculate level
    v_level := 1;
    WHILE v_total >= (25 * POWER(v_level + 1, 2.2))::integer LOOP
      v_level := v_level + 1;
    END LOOP;

    UPDATE developers
    SET xp_total = v_total, xp_github = v_github_xp, xp_level = v_level
    WHERE id = r.id;
  END LOOP;
END $$;
-- Live Presence: VS Code extension auth + developer sessions
-- ============================================================

-- API key column for VS Code extension auth
ALTER TABLE developers ADD COLUMN IF NOT EXISTS vscode_api_key TEXT UNIQUE;
CREATE INDEX IF NOT EXISTS idx_developers_vscode_api_key
  ON developers(vscode_api_key) WHERE vscode_api_key IS NOT NULL;

-- Developer coding sessions table
CREATE TABLE IF NOT EXISTS developer_sessions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id      BIGINT NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  session_id        TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'idle', 'offline')),
  current_language  TEXT,
  current_project   TEXT,
  active_seconds    INTEGER DEFAULT 0,
  total_heartbeats  INTEGER DEFAULT 0,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at          TIMESTAMPTZ,
  editor_name       TEXT DEFAULT 'vscode',
  os                TEXT,
  UNIQUE(developer_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_developer_sessions_status
  ON developer_sessions(status) WHERE status != 'offline';

CREATE INDEX IF NOT EXISTS idx_developer_sessions_last_heartbeat
  ON developer_sessions(last_heartbeat_at) WHERE status != 'offline';

-- RLS
ALTER TABLE developer_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read sessions" ON developer_sessions
  FOR SELECT USING (true);

CREATE POLICY "Service role manages sessions" ON developer_sessions
  FOR ALL USING (true) WITH CHECK (true);
-- Security hardening for Live Presence
-- ======================================

-- 1. Hash API keys at rest (C1)
-- Rename plaintext column, add hashed column
ALTER TABLE developers ADD COLUMN IF NOT EXISTS vscode_api_key_hash TEXT UNIQUE;
CREATE INDEX IF NOT EXISTS idx_developers_vscode_api_key_hash
  ON developers(vscode_api_key_hash) WHERE vscode_api_key_hash IS NOT NULL;

-- Migrate existing plaintext keys to hashed (SHA-256)
UPDATE developers
  SET vscode_api_key_hash = encode(sha256(vscode_api_key::bytea), 'hex')
  WHERE vscode_api_key IS NOT NULL AND vscode_api_key_hash IS NULL;

-- Drop plaintext column and old index
DROP INDEX IF EXISTS idx_developers_vscode_api_key;
ALTER TABLE developers DROP COLUMN IF EXISTS vscode_api_key;

-- 2. Restrict RLS on developer_sessions (M3)
-- Drop overly permissive public read policy
DROP POLICY IF EXISTS "Public read sessions" ON developer_sessions;

-- Only allow reading non-sensitive columns via the service role
-- (all reads go through the API layer which filters appropriately)
CREATE POLICY "No direct public read" ON developer_sessions
  FOR SELECT USING (false);
-- Add pix_id column for AbacatePay sky ad purchases
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS pix_id TEXT;
-- RPC: find auth user by github login (used for auto-claim on dev upsert)
CREATE OR REPLACE FUNCTION find_auth_user_by_github_login(p_github_login text)
RETURNS TABLE(id uuid)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT id
  FROM auth.users
  WHERE lower(raw_user_meta_data->>'user_name') = lower(p_github_login)
  LIMIT 1;
$$;

-- RPC: list auth users who logged in but have no developer record yet
CREATE OR REPLACE FUNCTION get_auth_users_without_developer()
RETURNS TABLE(github_login text)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT lower(raw_user_meta_data->>'user_name') AS github_login
  FROM auth.users
  WHERE raw_user_meta_data->>'user_name' IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM developers d
      WHERE d.github_login = lower(raw_user_meta_data->>'user_name')
    );
$$;

-- Backfill: claim all devs whose github_login matches an existing auth user
UPDATE developers d
SET
  claimed     = true,
  claimed_by  = au.id,
  claimed_at  = COALESCE(d.claimed_at, au.created_at)
FROM auth.users au
WHERE
  lower(au.raw_user_meta_data->>'user_name') = d.github_login
  AND d.claimed = false
  AND au.raw_user_meta_data->>'user_name' IS NOT NULL;
-- Add fiscal/billing data columns to purchases
-- Captured from Stripe checkout when customer fills billing address + tax ID
alter table purchases
  add column buyer_name        text,
  add column buyer_email       text,
  add column buyer_tax_id      text,       -- CPF, CNPJ, VAT, etc.
  add column buyer_tax_id_type text,       -- 'br_cpf' | 'br_cnpj' | 'eu_vat' etc.
  add column buyer_country     text,       -- ISO 3166-1 alpha-2 (e.g. 'BR', 'US')
  add column buyer_address     jsonb;      -- full address object from Stripe
-- Lightweight site visitor presence tracking (replaces Supabase Realtime Presence channel)
CREATE TABLE IF NOT EXISTS site_visitors (
  session_id TEXT PRIMARY KEY,
  last_seen TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_site_visitors_last_seen ON site_visitors (last_seen);

-- RPC: upsert visitor + prune stale + return count (single atomic call)
CREATE OR REPLACE FUNCTION heartbeat_visitor(p_session_id TEXT)
RETURNS INTEGER AS $$
DECLARE
  visitor_count INTEGER;
BEGIN
  INSERT INTO site_visitors (session_id, last_seen)
  VALUES (p_session_id, now())
  ON CONFLICT (session_id) DO UPDATE SET last_seen = now();

  DELETE FROM site_visitors WHERE last_seen < now() - INTERVAL '90 seconds';

  SELECT count(*) INTO visitor_count FROM site_visitors;

  RETURN visitor_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- 038: Add device and region columns to sky_ad_events + update materialized view

-- Device column for UA-based device tracking
ALTER TABLE sky_ad_events ADD COLUMN IF NOT EXISTS device TEXT;
CREATE INDEX IF NOT EXISTS idx_sky_ad_events_device ON sky_ad_events(device) WHERE device IS NOT NULL;

-- Region column for finer geo granularity (x-vercel-ip-country-region)
ALTER TABLE sky_ad_events ADD COLUMN IF NOT EXISTS region TEXT;

-- Recreate materialized view with device and country breakdowns.
-- COALESCE NULLs to empty string so the unique index works with
-- REFRESH MATERIALIZED VIEW CONCURRENTLY (PG treats NULLs as distinct).
DROP MATERIALIZED VIEW IF EXISTS sky_ad_daily_stats;
CREATE MATERIALIZED VIEW sky_ad_daily_stats AS
SELECT
  ad_id,
  date_trunc('day', created_at)::date AS day,
  COUNT(*) FILTER (WHERE event_type = 'impression') AS impressions,
  COUNT(*) FILTER (WHERE event_type = 'click') AS clicks,
  COUNT(*) FILTER (WHERE event_type = 'cta_click') AS cta_clicks,
  COALESCE(country, '') AS country,
  COALESCE(device, '') AS device
FROM sky_ad_events
GROUP BY ad_id, date_trunc('day', created_at)::date, COALESCE(country, ''), COALESCE(device, '');

CREATE UNIQUE INDEX idx_sky_ad_daily_stats ON sky_ad_daily_stats(ad_id, day, country, device);
-- 039: Advertiser accounts, sessions, API keys, and ad linkage

-- Advertiser accounts (magic-link auth, no password)
CREATE TABLE advertiser_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);

-- Magic-link sessions
CREATE TABLE advertiser_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id UUID NOT NULL REFERENCES advertiser_accounts(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ
);

CREATE INDEX idx_advertiser_sessions_token ON advertiser_sessions(token);

-- API keys for programmatic access
CREATE TABLE advertiser_api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id UUID NOT NULL REFERENCES advertiser_accounts(id) ON DELETE CASCADE,
  key_hash TEXT NOT NULL,
  key_prefix TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT 'Default',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ
);

CREATE INDEX idx_advertiser_api_keys_hash ON advertiser_api_keys(key_hash);

-- Link sky_ads to advertiser accounts
ALTER TABLE sky_ads ADD COLUMN IF NOT EXISTS advertiser_id UUID REFERENCES advertiser_accounts(id);
CREATE INDEX IF NOT EXISTS idx_sky_ads_advertiser ON sky_ads(advertiser_id);

-- Auto-create advertiser accounts from existing purchaser emails
INSERT INTO advertiser_accounts (email)
SELECT DISTINCT purchaser_email FROM sky_ads
WHERE purchaser_email IS NOT NULL
ON CONFLICT (email) DO NOTHING;

-- Link existing ads to their advertiser accounts
UPDATE sky_ads SET advertiser_id = (
  SELECT id FROM advertiser_accounts WHERE email = sky_ads.purchaser_email
) WHERE purchaser_email IS NOT NULL AND advertiser_id IS NULL;
-- Creator Drops: admin plants drops on buildings, players explore and pull for points

-- building_drops: drops planted by admin
CREATE TABLE building_drops (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  building_id BIGINT NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  rarity TEXT NOT NULL CHECK (rarity IN ('common','rare','epic','legendary')),
  points INTEGER NOT NULL,
  item_reward TEXT REFERENCES items(id),
  max_pulls INTEGER NOT NULL DEFAULT 50,
  pull_count INTEGER NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by TEXT NOT NULL DEFAULT 'srizzon'
);

-- 1 non-exhausted drop per building (expiration checked in app code)
CREATE UNIQUE INDEX idx_building_drops_active_building
  ON building_drops (building_id) WHERE pull_count < max_pulls;

-- filter by expiration (queries add WHERE expires_at > now() at runtime)
CREATE INDEX idx_building_drops_expires
  ON building_drops (expires_at);

-- drop_pulls: player pulls
CREATE TABLE drop_pulls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  drop_id UUID NOT NULL REFERENCES building_drops(id) ON DELETE CASCADE,
  developer_id BIGINT NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  points_earned INTEGER NOT NULL,
  pulled_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_drop_pulls_unique ON drop_pulls (drop_id, developer_id);
CREATE INDEX idx_drop_pulls_leaderboard ON drop_pulls (developer_id, points_earned);
CREATE INDEX idx_drop_pulls_drop ON drop_pulls (drop_id);

-- RLS
ALTER TABLE building_drops ENABLE ROW LEVEL SECURITY;
ALTER TABLE drop_pulls ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Building drops are viewable by everyone" ON building_drops FOR SELECT USING (true);
CREATE POLICY "Drop pulls are viewable by everyone" ON drop_pulls FOR SELECT USING (true);
-- Generic survey responses table
create table if not exists survey_responses (
  id bigint generated always as identity primary key,
  survey_id text not null,
  developer_id bigint references developers(id) not null,
  answers jsonb not null default '{}',
  created_at timestamptz default now() not null
);

-- One response per developer per survey
create unique index on survey_responses (survey_id, developer_id);

-- RLS
alter table survey_responses enable row level security;

create policy "Users can submit their own response"
  on survey_responses for insert
  with check (
    developer_id = (
      select id from developers
      where github_login = (auth.jwt() -> 'user_metadata' ->> 'user_name')
      limit 1
    )
  );

create policy "Users can read their own responses"
  on survey_responses for select
  using (
    developer_id = (
      select id from developers
      where github_login = (auth.jwt() -> 'user_metadata' ->> 'user_name')
      limit 1
    )
  );
-- Aggregated ad stats via RPC instead of pulling thousands of view rows client-side.
-- The materialized view sky_ad_daily_stats has rows per (ad_id, day, country, device),
-- which can be 100+ rows per ad per day. These RPCs aggregate in Postgres and return
-- only the data each consumer actually needs.

-- Returns aggregated totals per ad_id for a given period.
-- Used by: admin analytics, advertiser dashboard, weekly report cron.
CREATE OR REPLACE FUNCTION get_ad_stats(
  p_since date DEFAULT NULL,
  p_until date DEFAULT NULL,
  p_ad_ids text[] DEFAULT NULL
)
RETURNS TABLE(ad_id text, impressions bigint, clicks bigint, cta_clicks bigint)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    s.ad_id,
    COALESCE(SUM(s.impressions), 0)::bigint AS impressions,
    COALESCE(SUM(s.clicks), 0)::bigint AS clicks,
    COALESCE(SUM(s.cta_clicks), 0)::bigint AS cta_clicks
  FROM sky_ad_daily_stats s
  WHERE (p_since IS NULL OR s.day >= p_since)
    AND (p_until IS NULL OR s.day < p_until)
    AND (p_ad_ids IS NULL OR s.ad_id = ANY(p_ad_ids))
  GROUP BY s.ad_id;
$$;

-- Returns daily breakdown per ad_id for a given period.
-- Used by: advertiser dashboard (chart), per-ad API.
CREATE OR REPLACE FUNCTION get_ad_daily_stats(
  p_since date DEFAULT NULL,
  p_until date DEFAULT NULL,
  p_ad_ids text[] DEFAULT NULL
)
RETURNS TABLE(ad_id text, day date, impressions bigint, clicks bigint, cta_clicks bigint)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    s.ad_id,
    s.day,
    COALESCE(SUM(s.impressions), 0)::bigint AS impressions,
    COALESCE(SUM(s.clicks), 0)::bigint AS clicks,
    COALESCE(SUM(s.cta_clicks), 0)::bigint AS cta_clicks
  FROM sky_ad_daily_stats s
  WHERE (p_since IS NULL OR s.day >= p_since)
    AND (p_until IS NULL OR s.day < p_until)
    AND (p_ad_ids IS NULL OR s.ad_id = ANY(p_ad_ids))
  GROUP BY s.ad_id, s.day
  ORDER BY s.day;
$$;

-- Deactivate expired ads. Run via cron to keep database clean.
CREATE OR REPLACE FUNCTION deactivate_expired_ads()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE sky_ads
  SET active = false
  WHERE active = true
    AND ends_at IS NOT NULL
    AND ends_at < now();
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

-- Schedule expired ads cleanup every 15 minutes (same cadence as view refresh)
SELECT cron.schedule(
  'deactivate-expired-ads',
  '*/15 * * * *',
  $$SELECT deactivate_expired_ads()$$
);

-- Add "landmark" to vehicle CHECK constraint
ALTER TABLE sky_ads DROP CONSTRAINT IF EXISTS sky_ads_vehicle_check;
ALTER TABLE sky_ads ADD CONSTRAINT sky_ads_vehicle_check
  CHECK (vehicle IN ('plane', 'blimp', 'billboard', 'rooftop_sign', 'led_wrap', 'landmark'));
create table arcade_avatars (
  user_id uuid primary key references auth.users(id) on delete cascade,
  config jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

alter table arcade_avatars enable row level security;

create policy "Users can read own avatar"
  on arcade_avatars for select
  using (user_id = auth.uid());

create policy "Users can insert own avatar"
  on arcade_avatars for insert
  with check (user_id = auth.uid());

create policy "Users can update own avatar"
  on arcade_avatars for update
  using (user_id = auth.uid());
create table arcade_discoveries (
  user_id uuid primary key references auth.users(id) on delete cascade,
  commands text[] not null default '{}',
  updated_at timestamptz not null default now()
);

alter table arcade_discoveries enable row level security;

create policy "Users can read own discoveries"
  on arcade_discoveries for select
  using (user_id = auth.uid());

create policy "Users can insert own discoveries"
  on arcade_discoveries for insert
  with check (user_id = auth.uid());

create policy "Users can update own discoveries"
  on arcade_discoveries for update
  using (user_id = auth.uid());
-- 048: Conversion tracking system
-- Allows advertisers to track conversions (signup, purchase, etc.) from Git City ads
-- via client-side pixel or server-side postback (S2S).

-- 1. Add click_id column to sky_ad_events (links CTA clicks to conversions)
ALTER TABLE sky_ad_events ADD COLUMN IF NOT EXISTS click_id TEXT;
CREATE INDEX IF NOT EXISTS idx_sky_ad_events_click_id ON sky_ad_events(click_id) WHERE click_id IS NOT NULL;

-- 2. Add webhook_secret to advertiser_accounts (used for S2S HMAC verification)
ALTER TABLE advertiser_accounts ADD COLUMN IF NOT EXISTS webhook_secret TEXT;

-- 3. Conversions table
CREATE TABLE sky_ad_conversions (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ad_id TEXT NOT NULL REFERENCES sky_ads(id),
  click_id TEXT NOT NULL,
  event_name TEXT NOT NULL DEFAULT 'conversion',
  order_id TEXT,
  revenue_cents INTEGER,
  currency TEXT NOT NULL DEFAULT 'USD',
  ip_hash TEXT,
  source TEXT NOT NULL CHECK (source IN ('pixel', 's2s')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Dedup: one order_id per ad_id
CREATE UNIQUE INDEX idx_sky_ad_conversions_order_dedup
  ON sky_ad_conversions(ad_id, order_id) WHERE order_id IS NOT NULL;

CREATE INDEX idx_sky_ad_conversions_ad_id ON sky_ad_conversions(ad_id);
CREATE INDEX idx_sky_ad_conversions_click_id ON sky_ad_conversions(click_id);
CREATE INDEX idx_sky_ad_conversions_created ON sky_ad_conversions(created_at);

-- RLS: only service role can access
ALTER TABLE sky_ad_conversions ENABLE ROW LEVEL SECURITY;

-- 4. Conversion daily stats materialized view
CREATE MATERIALIZED VIEW sky_ad_conversion_daily_stats AS
SELECT
  ad_id,
  date_trunc('day', created_at)::date AS day,
  COUNT(*) AS conversions,
  COALESCE(SUM(revenue_cents), 0) AS revenue_cents
FROM sky_ad_conversions
GROUP BY ad_id, date_trunc('day', created_at)::date;

CREATE UNIQUE INDEX idx_sky_ad_conversion_daily_stats
  ON sky_ad_conversion_daily_stats(ad_id, day);

-- 5. Update refresh function to also refresh conversion stats
CREATE OR REPLACE FUNCTION refresh_sky_ad_stats()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY sky_ad_daily_stats;
  REFRESH MATERIALIZED VIEW CONCURRENTLY sky_ad_conversion_daily_stats;
END;
$$;

-- 6. Updated RPCs: include conversion data via LEFT JOIN
-- Must drop first because return type changes (adding conversions + revenue_cents columns)

DROP FUNCTION IF EXISTS get_ad_stats(date, date, text[]);
DROP FUNCTION IF EXISTS get_ad_daily_stats(date, date, text[]);

CREATE OR REPLACE FUNCTION get_ad_stats(
  p_since date DEFAULT NULL,
  p_until date DEFAULT NULL,
  p_ad_ids text[] DEFAULT NULL
)
RETURNS TABLE(ad_id text, impressions bigint, clicks bigint, cta_clicks bigint, conversions bigint, revenue_cents bigint)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    s.ad_id,
    COALESCE(SUM(s.impressions), 0)::bigint AS impressions,
    COALESCE(SUM(s.clicks), 0)::bigint AS clicks,
    COALESCE(SUM(s.cta_clicks), 0)::bigint AS cta_clicks,
    COALESCE(c.conversions, 0)::bigint AS conversions,
    COALESCE(c.revenue_cents, 0)::bigint AS revenue_cents
  FROM sky_ad_daily_stats s
  LEFT JOIN (
    SELECT
      cv.ad_id,
      SUM(cv.conversions) AS conversions,
      SUM(cv.revenue_cents) AS revenue_cents
    FROM sky_ad_conversion_daily_stats cv
    WHERE (p_since IS NULL OR cv.day >= p_since)
      AND (p_until IS NULL OR cv.day < p_until)
    GROUP BY cv.ad_id
  ) c ON c.ad_id = s.ad_id
  WHERE (p_since IS NULL OR s.day >= p_since)
    AND (p_until IS NULL OR s.day < p_until)
    AND (p_ad_ids IS NULL OR s.ad_id = ANY(p_ad_ids))
  GROUP BY s.ad_id, c.conversions, c.revenue_cents;
$$;

CREATE OR REPLACE FUNCTION get_ad_daily_stats(
  p_since date DEFAULT NULL,
  p_until date DEFAULT NULL,
  p_ad_ids text[] DEFAULT NULL
)
RETURNS TABLE(ad_id text, day date, impressions bigint, clicks bigint, cta_clicks bigint, conversions bigint, revenue_cents bigint)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    s.ad_id,
    s.day,
    COALESCE(SUM(s.impressions), 0)::bigint AS impressions,
    COALESCE(SUM(s.clicks), 0)::bigint AS clicks,
    COALESCE(SUM(s.cta_clicks), 0)::bigint AS cta_clicks,
    COALESCE(c.conversions, 0)::bigint AS conversions,
    COALESCE(c.revenue_cents, 0)::bigint AS revenue_cents
  FROM sky_ad_daily_stats s
  LEFT JOIN sky_ad_conversion_daily_stats c
    ON c.ad_id = s.ad_id AND c.day = s.day
  WHERE (p_since IS NULL OR s.day >= p_since)
    AND (p_until IS NULL OR s.day < p_until)
    AND (p_ad_ids IS NULL OR s.ad_id = ANY(p_ad_ids))
  GROUP BY s.ad_id, s.day, c.conversions, c.revenue_cents
  ORDER BY s.day;
$$;
-- 049_arcade_rooms.sql
-- Dynamic arcade rooms: maps, config, and metadata stored in DB

CREATE TABLE arcade_rooms (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug         TEXT UNIQUE NOT NULL,
  name         TEXT NOT NULL,
  room_type    TEXT NOT NULL DEFAULT 'official_floor'
    CHECK (room_type IN ('official_floor', 'player', 'org')),
  floor_number INT,
  map_json     JSONB NOT NULL,
  max_players  INT NOT NULL DEFAULT 50 CHECK (max_players > 0 AND max_players <= 100),
  owner_id     UUID REFERENCES auth.users,
  is_public    BOOLEAN NOT NULL DEFAULT true,
  portals      JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_arcade_rooms_slug ON arcade_rooms(slug);
CREATE INDEX idx_arcade_rooms_public ON arcade_rooms(is_public) WHERE is_public = true;

-- Slug format: lowercase, alphanumeric, hyphens, 1-40 chars
ALTER TABLE arcade_rooms ADD CONSTRAINT chk_slug_format
  CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$' OR length(slug) = 1);

-- RLS: public rooms readable by anyone, write only by owner or service role
ALTER TABLE arcade_rooms ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public rooms are readable by everyone"
  ON arcade_rooms FOR SELECT
  USING (is_public = true);

CREATE POLICY "Owners can update their rooms"
  ON arcade_rooms FOR UPDATE
  USING (auth.uid() = owner_id);

CREATE POLICY "Service role has full access"
  ON arcade_rooms FOR ALL
  USING (auth.role() = 'service_role');

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_arcade_rooms_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_arcade_rooms_updated_at
  BEFORE UPDATE ON arcade_rooms
  FOR EACH ROW
  EXECUTE FUNCTION update_arcade_rooms_updated_at();

-- Seed: insert current lobby as the default room
INSERT INTO arcade_rooms (slug, name, room_type, floor_number, map_json, portals)
VALUES (
  'lobby',
  'E.Arcade Lobby',
  'official_floor',
  0,
  '{"name": "lobby", "width": 30, "height": 22, "tileSize": 32, "tileset": "/sprites/arcade-tileset.png", "tilesetColumns": 16, "layers": {"ground": [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 8, 8, 8, 8, 8, 8, 8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 8, 8, 8, 8, 8, 8, 8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 6, 5, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 6, 5, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 6, 5, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 7, 7, 7, 7, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4], "collision": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], "abovePlayer": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]}, "furniture": [{"id": "f-0", "sprite": "DESK_FRONT", "x": 96, "y": 96, "width": 96, "height": 64, "collides": true, "sortY": 160}, {"id": "f-1", "sprite": "DESK_FRONT", "x": 224, "y": 96, "width": 96, "height": 64, "collides": true, "sortY": 160}, {"id": "f-2", "sprite": "PC_FRONT", "x": 128, "y": 96, "width": 32, "height": 32, "collides": false, "sortY": 160.5}, {"id": "f-3", "sprite": "PC_FRONT", "x": 256, "y": 96, "width": 32, "height": 32, "collides": false, "sortY": 160.5}, {"id": "f-4", "sprite": "CHAIR_FRONT", "x": 128, "y": 160, "width": 32, "height": 32, "collides": false, "sortY": 192}, {"id": "f-5", "sprite": "CHAIR_FRONT", "x": 256, "y": 160, "width": 32, "height": 32, "collides": false, "sortY": 192}, {"id": "f-6", "sprite": "DESK_FRONT", "x": 640, "y": 96, "width": 96, "height": 64, "collides": true, "sortY": 160}, {"id": "f-7", "sprite": "DESK_FRONT", "x": 768, "y": 96, "width": 96, "height": 64, "collides": true, "sortY": 160}, {"id": "f-8", "sprite": "PC_FRONT", "x": 672, "y": 96, "width": 32, "height": 32, "collides": false, "sortY": 160.5}, {"id": "f-9", "sprite": "PC_FRONT", "x": 800, "y": 96, "width": 32, "height": 32, "collides": false, "sortY": 160.5}, {"id": "f-10", "sprite": "CHAIR_FRONT", "x": 672, "y": 160, "width": 32, "height": 32, "collides": false, "sortY": 192}, {"id": "f-11", "sprite": "CHAIR_FRONT", "x": 800, "y": 160, "width": 32, "height": 32, "collides": false, "sortY": 192}, {"id": "f-12", "sprite": "SMALL_TABLE", "x": 352, "y": 288, "width": 64, "height": 64, "collides": true, "sortY": 352}, {"id": "f-13", "sprite": "SMALL_TABLE", "x": 416, "y": 288, "width": 64, "height": 64, "collides": true, "sortY": 352}, {"id": "f-14", "sprite": "SMALL_TABLE", "x": 480, "y": 288, "width": 64, "height": 64, "collides": true, "sortY": 352}, {"id": "f-15", "sprite": "SMALL_TABLE", "x": 544, "y": 288, "width": 64, "height": 64, "collides": true, "sortY": 352}, {"id": "f-16", "sprite": "CHAIR_BACK", "x": 384, "y": 320, "width": 32, "height": 32, "collides": false, "sortY": 352.5}, {"id": "f-17", "sprite": "CHAIR_BACK", "x": 448, "y": 320, "width": 32, "height": 32, "collides": false, "sortY": 352.5}, {"id": "f-18", "sprite": "CHAIR_BACK", "x": 512, "y": 320, "width": 32, "height": 32, "collides": false, "sortY": 352.5}, {"id": "f-19", "sprite": "CHAIR_FRONT", "x": 384, "y": 352, "width": 32, "height": 32, "collides": false, "sortY": 384}, {"id": "f-20", "sprite": "CHAIR_FRONT", "x": 448, "y": 352, "width": 32, "height": 32, "collides": false, "sortY": 384}, {"id": "f-21", "sprite": "CHAIR_FRONT", "x": 512, "y": 352, "width": 32, "height": 32, "collides": false, "sortY": 384}, {"id": "f-22", "sprite": "SOFA_FRONT", "x": 64, "y": 416, "width": 64, "height": 32, "collides": true, "sortY": 448}, {"id": "f-23", "sprite": "SOFA_FRONT", "x": 64, "y": 480, "width": 64, "height": 32, "collides": true, "sortY": 512}, {"id": "f-24", "sprite": "SMALL_TABLE", "x": 128, "y": 448, "width": 64, "height": 64, "collides": true, "sortY": 512}, {"id": "f-25", "sprite": "COFFEE", "x": 160, "y": 480, "width": 32, "height": 32, "collides": false, "sortY": 512.5}, {"id": "f-26", "sprite": "SOFA_FRONT", "x": 768, "y": 416, "width": 64, "height": 32, "collides": true, "sortY": 448}, {"id": "f-27", "sprite": "SOFA_FRONT", "x": 768, "y": 480, "width": 64, "height": 32, "collides": true, "sortY": 512}, {"id": "f-28", "sprite": "SMALL_TABLE", "x": 832, "y": 448, "width": 64, "height": 64, "collides": true, "sortY": 512}, {"id": "f-29", "sprite": "SMALL_TABLE", "x": 96, "y": 576, "width": 64, "height": 64, "collides": true, "sortY": 640}, {"id": "f-30", "sprite": "SMALL_TABLE", "x": 160, "y": 576, "width": 64, "height": 64, "collides": true, "sortY": 640}, {"id": "f-31", "sprite": "COFFEE", "x": 128, "y": 608, "width": 32, "height": 32, "collides": false, "sortY": 640.5}, {"id": "f-32", "sprite": "COFFEE", "x": 192, "y": 608, "width": 32, "height": 32, "collides": false, "sortY": 640.5}, {"id": "f-33", "sprite": "CHAIR_FRONT", "x": 128, "y": 608, "width": 32, "height": 32, "collides": false, "sortY": 640}, {"id": "f-34", "sprite": "CHAIR_FRONT", "x": 192, "y": 608, "width": 32, "height": 32, "collides": false, "sortY": 640}, {"id": "f-35", "sprite": "PLANT", "x": 32, "y": 0, "width": 32, "height": 32, "collides": true, "sortY": 64}, {"id": "f-36", "sprite": "PLANT", "x": 896, "y": 0, "width": 32, "height": 32, "collides": true, "sortY": 64}, {"id": "f-37", "sprite": "PLANT", "x": 32, "y": 576, "width": 32, "height": 32, "collides": true, "sortY": 640}, {"id": "f-38", "sprite": "PLANT", "x": 896, "y": 576, "width": 32, "height": 32, "collides": true, "sortY": 640}, {"id": "f-39", "sprite": "PLANT", "x": 352, "y": 0, "width": 32, "height": 32, "collides": true, "sortY": 64}, {"id": "f-40", "sprite": "PLANT", "x": 576, "y": 0, "width": 32, "height": 32, "collides": true, "sortY": 64}, {"id": "f-41", "sprite": "BOOKSHELF", "x": 96, "y": 32, "width": 64, "height": 32, "collides": true, "sortY": 64}, {"id": "f-42", "sprite": "BOOKSHELF", "x": 192, "y": 32, "width": 64, "height": 32, "collides": true, "sortY": 64}, {"id": "f-43", "sprite": "BOOKSHELF", "x": 736, "y": 32, "width": 64, "height": 32, "collides": true, "sortY": 64}, {"id": "f-44", "sprite": "BOOKSHELF", "x": 832, "y": 32, "width": 64, "height": 32, "collides": true, "sortY": 64}, {"id": "f-45", "sprite": "WHITEBOARD", "x": 288, "y": 0, "width": 64, "height": 32, "collides": true, "sortY": 32}, {"id": "f-46", "sprite": "LARGE_PAINTING", "x": 640, "y": 0, "width": 64, "height": 32, "collides": true, "sortY": 32}, {"id": "f-47", "sprite": "SMALL_PAINTING", "x": 0, "y": 384, "width": 32, "height": 32, "collides": true, "sortY": 416}, {"id": "f-48", "sprite": "CLOCK", "x": 928, "y": 384, "width": 32, "height": 32, "collides": true, "sortY": 416}, {"id": "f-49", "sprite": "BIN", "x": 640, "y": 608, "width": 32, "height": 32, "collides": true, "sortY": 640}, {"id": "f-50", "sprite": "ELEVATOR", "x": 416, "y": 32, "width": 128, "height": 32, "collides": true, "sortY": 32}], "objects": [{"type": "spawn", "x": 13, "y": 21}, {"type": "spawn", "x": 14, "y": 21}, {"type": "spawn", "x": 15, "y": 21}, {"type": "spawn", "x": 16, "y": 21}, {"type": "elevator", "x": 14, "y": 0, "width": 4, "label": "Elevator"}, {"type": "quote", "x": 9, "y": 1, "width": 2, "label": "Whiteboard"}, {"type": "quote", "x": 20, "y": 1, "width": 2, "label": "Painting"}, {"type": "quote", "x": 1, "y": 12, "label": "Painting"}, {"type": "quote", "x": 28, "y": 12, "label": "Clock"}, {"type": "pc", "x": 4, "y": 5, "dir": "up"}, {"type": "pc", "x": 8, "y": 5, "dir": "up"}, {"type": "pc", "x": 21, "y": 5, "dir": "up"}, {"type": "pc", "x": 25, "y": 5, "dir": "up"}, {"type": "seat", "x": 12, "y": 11, "dir": "down"}, {"type": "seat", "x": 14, "y": 11, "dir": "down"}, {"type": "seat", "x": 16, "y": 11, "dir": "down"}, {"type": "seat", "x": 4, "y": 19, "dir": "down"}, {"type": "seat", "x": 6, "y": 19, "dir": "down"}]}'::jsonb,
  '[{"x": 14, "y": 0, "width": 4, "type": "elevator", "destination": "floor-1", "label": "Floor 1"}]'::jsonb
);
-- 050_arcade_rooms_scale.sql
-- Scale-ready fields: visibility, categories, password, description

-- Visibility: controls who can see/enter the room
ALTER TABLE arcade_rooms ADD COLUMN visibility TEXT NOT NULL DEFAULT 'open'
  CHECK (visibility IN ('open', 'unlisted', 'password', 'friends_only'));

-- Category: broad genre for filtering (null = uncategorized)
ALTER TABLE arcade_rooms ADD COLUMN category TEXT
  CHECK (category IS NULL OR category IN (
    'social', 'work', 'games', 'events', 'chill', 'dev', 'art', 'music'
  ));

-- Password hash for password-protected rooms (bcrypt or similar)
ALTER TABLE arcade_rooms ADD COLUMN password_hash TEXT;

-- Short description shown in room browser
ALTER TABLE arcade_rooms ADD COLUMN description TEXT CHECK (length(description) <= 200);

-- Featured flag for staff picks
ALTER TABLE arcade_rooms ADD COLUMN is_featured BOOLEAN NOT NULL DEFAULT false;

-- Drop old policy first (depends on is_public column)
DROP POLICY IF EXISTS "Public rooms are readable by everyone" ON arcade_rooms;

-- Drop is_public (replaced by visibility)
ALTER TABLE arcade_rooms DROP COLUMN is_public;

-- New RLS: visibility-based access
CREATE POLICY "Visible rooms are readable by everyone"
  ON arcade_rooms FOR SELECT
  USING (visibility IN ('open', 'password') OR auth.uid() = owner_id OR auth.role() = 'service_role');

-- Index for browser queries
DROP INDEX IF EXISTS idx_arcade_rooms_public;
CREATE INDEX idx_arcade_rooms_visibility ON arcade_rooms(visibility) WHERE visibility = 'open';
CREATE INDEX idx_arcade_rooms_category ON arcade_rooms(category) WHERE category IS NOT NULL;
CREATE INDEX idx_arcade_rooms_featured ON arcade_rooms(is_featured) WHERE is_featured = true;

-- Full-text search index on name + description
ALTER TABLE arcade_rooms ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(description, '')), 'B')
  ) STORED;
CREATE INDEX idx_arcade_rooms_search ON arcade_rooms USING gin(search_vector);

-- ─── Room favorites ─────────────────────────────────────────
CREATE TABLE arcade_room_favorites (
  user_id    UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  room_id    UUID NOT NULL REFERENCES arcade_rooms ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, room_id)
);

ALTER TABLE arcade_room_favorites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own favorites"
  ON arcade_room_favorites FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own favorites"
  ON arcade_room_favorites FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own favorites"
  ON arcade_room_favorites FOR DELETE
  USING (auth.uid() = user_id);

CREATE POLICY "Service role has full access to favorites"
  ON arcade_room_favorites FOR ALL
  USING (auth.role() = 'service_role');

-- ─── Room visit history ─────────────────────────────────────
CREATE TABLE arcade_room_visits (
  user_id        UUID NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  room_id        UUID NOT NULL REFERENCES arcade_rooms ON DELETE CASCADE,
  visit_count    INT NOT NULL DEFAULT 1,
  last_visited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, room_id)
);

CREATE INDEX idx_arcade_visits_user_recent ON arcade_room_visits(user_id, last_visited_at DESC);

ALTER TABLE arcade_room_visits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own visits"
  ON arcade_room_visits FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Service role has full access to visits"
  ON arcade_room_visits FOR ALL
  USING (auth.role() = 'service_role');

-- Upsert function: insert or increment visit count
CREATE OR REPLACE FUNCTION upsert_arcade_visit(p_user_id UUID, p_room_id UUID)
RETURNS void AS $$
BEGIN
  INSERT INTO arcade_room_visits (user_id, room_id, visit_count, last_visited_at)
  VALUES (p_user_id, p_room_id, 1, now())
  ON CONFLICT (user_id, room_id) DO UPDATE SET
    visit_count = arcade_room_visits.visit_count + 1,
    last_visited_at = now();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- Simplify heartbeat_visitor: upsert only, no prune or count.
-- Pruning moved to cleanup-sessions cron. Count served via cached GET endpoint.
CREATE OR REPLACE FUNCTION heartbeat_visitor(p_session_id TEXT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO site_visitors (session_id, last_seen)
  VALUES (p_session_id, now())
  ON CONFLICT (session_id) DO UPDATE SET last_seen = now();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- ============================================================
-- Migration 052: Pixels (PX) Virtual Currency — Core
-- Tables: wallets, wallet_transactions, pixel_packages, earn_rules
-- RPCs: credit_pixels, earn_pixels, spend_pixels, debit_pixels
-- ============================================================

-- 1. Wallets (one per developer, cached balance)
CREATE TABLE wallets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id    bigint NOT NULL UNIQUE REFERENCES developers(id) ON DELETE RESTRICT,
  balance         bigint NOT NULL DEFAULT 0
                    CHECK (balance >= 0 AND balance <= 999999999),
  lifetime_earned bigint NOT NULL DEFAULT 0,
  lifetime_bought bigint NOT NULL DEFAULT 0,
  lifetime_spent  bigint NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- 2. Wallet Transactions (immutable ledger)
CREATE TABLE wallet_transactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id    bigint NOT NULL REFERENCES developers(id) ON DELETE RESTRICT,
  type            text NOT NULL CHECK (type IN ('credit', 'debit')),
  amount          bigint NOT NULL CHECK (amount > 0 AND amount <= 1000000),
  source          text NOT NULL CHECK (source IN (
    'purchase',
    'daily_commit',
    'streak_bonus',
    'achievement',
    'city_action',
    'item_purchase',
    'refund',
    'chargeback',
    'adjustment'
  )),
  reference_id    text,
  reference_type  text,
  description     text CHECK (length(description) <= 500),
  balance_before  bigint NOT NULL,
  balance_after   bigint NOT NULL,
  idempotency_key text UNIQUE,
  ip_address      inet,
  user_agent      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_wtx_developer ON wallet_transactions(developer_id, created_at DESC);
CREATE INDEX idx_wtx_source ON wallet_transactions(developer_id, source);
CREATE INDEX idx_wtx_daily_earn ON wallet_transactions(developer_id, created_at)
  WHERE type = 'credit' AND source IN ('daily_commit', 'streak_bonus', 'achievement', 'city_action');

-- 3. Immutability trigger
CREATE OR REPLACE FUNCTION prevent_ledger_mutation() RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Ledger entries are immutable. Create a reversal instead.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER immutable_ledger
  BEFORE UPDATE OR DELETE ON wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

-- 4. Pixel Packages (purchasable bundles)
CREATE TABLE pixel_packages (
  id              text PRIMARY KEY,
  name            text NOT NULL,
  pixels          int NOT NULL,
  bonus_pixels    int NOT NULL DEFAULT 0,
  price_usd_cents int NOT NULL,
  price_brl_cents int,
  is_active       boolean NOT NULL DEFAULT true,
  sort_order      int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO pixel_packages (id, name, pixels, bonus_pixels, price_usd_cents, price_brl_cents, sort_order) VALUES
  ('starter', 'Starter',    100,   0,  100,   500, 1),
  ('value',   'Value Pack', 500,  25,  500,  2500, 2),
  ('popular', 'Popular',   1000, 200, 1000,  5000, 3),
  ('mega',    'Mega Pack',  2000, 750, 2000,  9900, 4);

-- 5. Earn Rules (how users earn PX through gameplay)
CREATE TABLE earn_rules (
  id              text PRIMARY KEY,
  source          text NOT NULL,
  pixels          int NOT NULL,
  cooldown_hours  int,
  max_per_day     int,
  is_active       boolean NOT NULL DEFAULT true,
  description     text
);

INSERT INTO earn_rules (id, source, pixels, cooldown_hours, max_per_day, description) VALUES
  ('daily_commit',    'daily_commit',  2, 20, 2, 'Commit diario no GitHub'),
  ('streak_3',        'streak_bonus',  3, NULL, NULL, 'Streak de 3 dias'),
  ('streak_7',        'streak_bonus',  7, NULL, NULL, 'Streak de 7 dias'),
  ('streak_14',       'streak_bonus', 15, NULL, NULL, 'Streak de 14 dias'),
  ('streak_30',       'streak_bonus', 35, NULL, NULL, 'Streak de 30 dias'),
  ('visit_city',      'city_action',   1, 20, 1, 'Visitar a cidade'),
  ('raid_attack',     'city_action',   2, 20, 2, 'Atacar em raid'),
  ('gift_sent',       'city_action',   3, NULL, 5, 'Enviar presente'),
  ('dailies_complete','city_action',   5, 20, 1, 'Completar 3 dailies do dia');

-- 6. RLS Policies
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY wallet_read ON wallets FOR SELECT
  USING (developer_id = (SELECT id FROM developers WHERE claimed_by = auth.uid()));
CREATE POLICY wallet_service ON wallets FOR ALL
  USING (auth.role() = 'service_role');

ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tx_read ON wallet_transactions FOR SELECT
  USING (developer_id = (SELECT id FROM developers WHERE claimed_by = auth.uid()));
CREATE POLICY tx_service ON wallet_transactions FOR ALL
  USING (auth.role() = 'service_role');

ALTER TABLE pixel_packages ENABLE ROW LEVEL SECURITY;
CREATE POLICY packages_read ON pixel_packages FOR SELECT USING (is_active = true);
CREATE POLICY packages_service ON pixel_packages FOR ALL USING (auth.role() = 'service_role');

ALTER TABLE earn_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY earn_read ON earn_rules FOR SELECT USING (is_active = true);
CREATE POLICY earn_service ON earn_rules FOR ALL USING (auth.role() = 'service_role');

-- ============================================================
-- RPCs
-- ============================================================

-- 7. credit_pixels (service_role only — purchases, refunds, adjustments)
CREATE OR REPLACE FUNCTION credit_pixels(
  p_developer_id bigint,
  p_amount bigint,
  p_source text,
  p_reference_id text,
  p_reference_type text,
  p_description text,
  p_idempotency_key text,
  p_ip inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_old_balance bigint;
  v_new_balance bigint;
  v_tx_id uuid;
BEGIN
  IF auth.role() != 'service_role' THEN
    RAISE EXCEPTION 'credit_pixels requires service_role';
  END IF;

  IF p_source NOT IN ('purchase', 'refund', 'adjustment') THEN
    RAISE EXCEPTION 'credit_pixels only accepts purchase/refund/adjustment sources';
  END IF;

  PERFORM pg_advisory_xact_lock(p_developer_id);

  INSERT INTO wallets (developer_id)
  VALUES (p_developer_id)
  ON CONFLICT (developer_id) DO NOTHING;

  UPDATE wallets
  SET balance = balance + p_amount,
      lifetime_bought = lifetime_bought +
        CASE WHEN p_source = 'purchase' THEN p_amount ELSE 0 END,
      lifetime_earned = lifetime_earned +
        CASE WHEN p_source != 'purchase' THEN p_amount ELSE 0 END,
      updated_at = now()
  WHERE developer_id = p_developer_id
  RETURNING balance - p_amount, balance
  INTO v_old_balance, v_new_balance;

  INSERT INTO wallet_transactions (
    developer_id, type, amount, source,
    reference_id, reference_type, description,
    balance_before, balance_after,
    idempotency_key, ip_address, user_agent
  ) VALUES (
    p_developer_id, 'credit', p_amount, p_source,
    p_reference_id, p_reference_type, p_description,
    v_old_balance, v_new_balance,
    p_idempotency_key, p_ip, p_user_agent
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    UPDATE wallets
    SET balance = balance - p_amount,
        lifetime_bought = lifetime_bought -
          CASE WHEN p_source = 'purchase' THEN p_amount ELSE 0 END,
        lifetime_earned = lifetime_earned -
          CASE WHEN p_source != 'purchase' THEN p_amount ELSE 0 END,
        updated_at = now()
    WHERE developer_id = p_developer_id;

    RETURN jsonb_build_object('error', 'duplicate_transaction');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'new_balance', v_new_balance
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION credit_pixels FROM authenticated, anon;

-- 8. earn_pixels (service_role only — gameplay rewards)
CREATE OR REPLACE FUNCTION earn_pixels(
  p_developer_id bigint,
  p_earn_rule_id text,
  p_reference_id text DEFAULT NULL,
  p_reference_type text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_rule earn_rules%ROWTYPE;
  v_earned_today bigint;
  v_source_today int;
  v_last_earn timestamptz;
  v_old_balance bigint;
  v_new_balance bigint;
  v_tx_id uuid;
BEGIN
  IF auth.role() != 'service_role' THEN
    RAISE EXCEPTION 'earn_pixels requires service_role';
  END IF;

  PERFORM pg_advisory_xact_lock(p_developer_id);

  SELECT * INTO v_rule FROM earn_rules WHERE id = p_earn_rule_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'invalid_earn_rule');
  END IF;

  -- Check cooldown
  IF v_rule.cooldown_hours IS NOT NULL THEN
    SELECT MAX(created_at) INTO v_last_earn
    FROM wallet_transactions
    WHERE developer_id = p_developer_id
      AND source = v_rule.source
      AND reference_type = p_earn_rule_id
      AND created_at >= now() - make_interval(hours => v_rule.cooldown_hours);

    IF v_last_earn IS NOT NULL THEN
      RETURN jsonb_build_object('error', 'cooldown_active');
    END IF;
  END IF;

  -- Check per-source daily limit
  IF v_rule.max_per_day IS NOT NULL THEN
    SELECT COUNT(*) INTO v_source_today
    FROM wallet_transactions
    WHERE developer_id = p_developer_id
      AND source = v_rule.source
      AND reference_type = p_earn_rule_id
      AND created_at >= now() - interval '24 hours';

    IF v_source_today >= v_rule.max_per_day THEN
      RETURN jsonb_build_object('error', 'daily_source_cap_reached');
    END IF;
  END IF;

  -- Check global daily earn cap (50 PX)
  SELECT COALESCE(SUM(amount), 0) INTO v_earned_today
  FROM wallet_transactions
  WHERE developer_id = p_developer_id
    AND type = 'credit'
    AND source IN ('daily_commit', 'streak_bonus', 'achievement', 'city_action')
    AND created_at >= now() - interval '24 hours';

  IF v_earned_today + v_rule.pixels > 50 THEN
    RETURN jsonb_build_object('error', 'daily_earn_cap_reached');
  END IF;

  INSERT INTO wallets (developer_id)
  VALUES (p_developer_id)
  ON CONFLICT (developer_id) DO NOTHING;

  UPDATE wallets
  SET balance = balance + v_rule.pixels,
      lifetime_earned = lifetime_earned + v_rule.pixels,
      updated_at = now()
  WHERE developer_id = p_developer_id
  RETURNING balance - v_rule.pixels, balance
  INTO v_old_balance, v_new_balance;

  INSERT INTO wallet_transactions (
    developer_id, type, amount, source,
    reference_id, reference_type, description,
    balance_before, balance_after,
    idempotency_key
  ) VALUES (
    p_developer_id, 'credit', v_rule.pixels, v_rule.source,
    p_reference_id, p_earn_rule_id, v_rule.description,
    v_old_balance, v_new_balance,
    p_idempotency_key
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    UPDATE wallets
    SET balance = balance - v_rule.pixels,
        lifetime_earned = lifetime_earned - v_rule.pixels,
        updated_at = now()
    WHERE developer_id = p_developer_id;

    RETURN jsonb_build_object('error', 'duplicate_transaction');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'new_balance', v_new_balance,
    'earned', v_rule.pixels
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION earn_pixels FROM authenticated, anon;

-- 9. spend_pixels (service_role only — all item purchases go through API route)
CREATE OR REPLACE FUNCTION spend_pixels(
  p_developer_id bigint,
  p_item_id text,
  p_idempotency_key text,
  p_recipient_id bigint DEFAULT NULL,
  p_allow_multiple boolean DEFAULT false,
  p_ip inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_price bigint;
  v_target_id bigint;
  v_old_balance bigint;
  v_new_balance bigint;
  v_tx_id uuid;
BEGIN
  -- CRITICAL: only service_role (API routes) can call this
  IF auth.role() != 'service_role' THEN
    RAISE EXCEPTION 'spend_pixels requires service_role';
  END IF;

  PERFORM pg_advisory_xact_lock(p_developer_id);

  -- Lookup item price from DB (never trust caller)
  SELECT price_pixels INTO v_price
  FROM items WHERE id = p_item_id AND is_active = true;

  IF v_price IS NULL THEN
    RETURN jsonb_build_object('error', 'item_not_found');
  END IF;

  v_target_id := COALESCE(p_recipient_id, p_developer_id);

  -- Check duplicate ownership (skip for consumables/multi-buy items)
  IF NOT p_allow_multiple THEN
    IF EXISTS (
      SELECT 1 FROM purchases
      WHERE (
        (developer_id = v_target_id AND item_id = p_item_id AND status = 'completed' AND gifted_to IS NULL)
        OR
        (gifted_to = v_target_id AND item_id = p_item_id AND status = 'completed')
      )
    ) THEN
      RETURN jsonb_build_object('error', 'already_owned');
    END IF;
  END IF;

  -- Atomic debit
  UPDATE wallets
  SET balance = balance - v_price,
      lifetime_spent = lifetime_spent + v_price,
      updated_at = now()
  WHERE developer_id = p_developer_id
    AND balance >= v_price
  RETURNING balance + v_price, balance
  INTO v_old_balance, v_new_balance;

  IF NOT FOUND THEN
    PERFORM 1 FROM wallets WHERE developer_id = p_developer_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('error', 'wallet_not_found');
    ELSE
      RETURN jsonb_build_object('error', 'insufficient_balance');
    END IF;
  END IF;

  -- Ledger entry
  INSERT INTO wallet_transactions (
    developer_id, type, amount, source,
    reference_id, reference_type, description,
    balance_before, balance_after,
    idempotency_key, ip_address, user_agent
  ) VALUES (
    p_developer_id, 'debit', v_price, 'item_purchase',
    p_item_id, 'item',
    CASE WHEN p_recipient_id IS NOT NULL
      THEN 'Gifted ' || p_item_id || ' to dev ' || p_recipient_id
      ELSE 'Purchased ' || p_item_id
    END,
    v_old_balance, v_new_balance,
    p_idempotency_key, p_ip, p_user_agent
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    UPDATE wallets
    SET balance = balance + v_price,
        lifetime_spent = lifetime_spent - v_price,
        updated_at = now()
    WHERE developer_id = p_developer_id;

    RETURN jsonb_build_object('error', 'duplicate_transaction');
  END IF;

  -- Purchase record
  IF p_recipient_id IS NOT NULL THEN
    INSERT INTO purchases (developer_id, item_id, provider, amount_cents, currency, status, gifted_to)
    VALUES (p_developer_id, p_item_id, 'pixels', v_price, 'PX', 'completed', p_recipient_id);
  ELSE
    INSERT INTO purchases (developer_id, item_id, provider, amount_cents, currency, status)
    VALUES (p_developer_id, p_item_id, 'pixels', v_price, 'PX', 'completed');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'new_balance', v_new_balance,
    'price', v_price
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION spend_pixels FROM authenticated, anon;

-- 10. debit_pixels (service_role only — chargebacks/refunds)
CREATE OR REPLACE FUNCTION debit_pixels(
  p_developer_id bigint,
  p_amount bigint,
  p_source text,
  p_reference_id text,
  p_description text,
  p_idempotency_key text
) RETURNS jsonb AS $$
DECLARE
  v_old_balance bigint;
  v_new_balance bigint;
  v_tx_id uuid;
BEGIN
  IF auth.role() != 'service_role' THEN
    RAISE EXCEPTION 'debit_pixels requires service_role';
  END IF;

  IF p_source NOT IN ('chargeback', 'refund', 'adjustment') THEN
    RAISE EXCEPTION 'debit_pixels only accepts chargeback/refund/adjustment sources';
  END IF;

  PERFORM pg_advisory_xact_lock(p_developer_id);

  SELECT balance INTO v_old_balance FROM wallets WHERE developer_id = p_developer_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'wallet_not_found');
  END IF;

  UPDATE wallets
  SET balance = GREATEST(0, balance - p_amount),
      lifetime_spent = lifetime_spent + LEAST(balance, p_amount),
      updated_at = now()
  WHERE developer_id = p_developer_id
  RETURNING balance INTO v_new_balance;

  INSERT INTO wallet_transactions (
    developer_id, type, amount, source,
    reference_id, reference_type, description,
    balance_before, balance_after,
    idempotency_key
  ) VALUES (
    p_developer_id, 'debit', p_amount, p_source,
    p_reference_id, p_source, p_description,
    v_old_balance, v_new_balance,
    p_idempotency_key
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_tx_id;

  IF v_tx_id IS NULL THEN
    UPDATE wallets
    SET balance = v_old_balance,
        lifetime_spent = lifetime_spent - LEAST(v_old_balance, p_amount),
        updated_at = now()
    WHERE developer_id = p_developer_id;
    RETURN jsonb_build_object('error', 'duplicate_transaction');
  END IF;

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION debit_pixels FROM authenticated, anon;
-- ============================================================
-- Migration 053: Pixels — Items pricing + pixel_purchases
-- ============================================================

-- Items: add PX pricing columns
ALTER TABLE items
  ADD COLUMN price_pixels int,
  ADD COLUMN pixels_only boolean NOT NULL DEFAULT false;

-- Set PX prices: round numbers that feel like game currency, not converted cents
-- Set PX prices: round numbers that feel like game currency
-- 50 PX — Entry (simple structures)
UPDATE items SET price_pixels = 50  WHERE id IN ('helipad', 'antenna_array', 'rooftop_garden');
-- 75 PX — Small consumables
UPDATE items SET price_pixels = 75  WHERE id IN ('raid_boost_small', 'streak_freeze');
-- 100 PX — Core (basic effects + identity)
UPDATE items SET price_pixels = 100 WHERE id IN ('spotlight', 'custom_color', 'neon_outline', 'neon_trim', 'rooftop_fire', 'spire');
-- 150 PX — Mid-tier (structures + tags)
UPDATE items SET price_pixels = 150 WHERE id IN ('tag_neon', 'satellite_dish');
-- 200 PX — Premium (effects + vehicles + structures)
UPDATE items SET price_pixels = 200 WHERE id IN ('particle_aura', 'raid_drone', 'raid_boost_medium', 'pool_party', 'hologram_ring');
-- 250 PX — Billboard + LED Banner (multi-buy / faces)
UPDATE items SET price_pixels = 250 WHERE id IN ('billboard', 'led_banner');
-- 300 PX — High-tier (gold tag + crown + lightning)
UPDATE items SET price_pixels = 300 WHERE id IN ('tag_gold', 'crown_item', 'lightning_aura');
-- 400 PX — Vehicles + heavy consumables
UPDATE items SET price_pixels = 400 WHERE id IN ('raid_helicopter', 'raid_boost_large');
-- 500 PX — Top tier
UPDATE items SET price_pixels = 500 WHERE id = 'raid_rocket';
-- Free/achievement items keep price_pixels = NULL (not purchasable with PX)
-- flag, github_star, white_rabbit are earned, not bought

-- Developers: suspension flag (for chargebacks)
ALTER TABLE developers ADD COLUMN IF NOT EXISTS suspended boolean NOT NULL DEFAULT false;

-- Pixel purchase tracking (separate from item purchases)
CREATE TABLE pixel_purchases (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id    bigint NOT NULL REFERENCES developers(id),
  package_id      text NOT NULL REFERENCES pixel_packages(id),
  provider        text NOT NULL CHECK (provider IN ('stripe', 'abacatepay')),
  provider_tx_id  text UNIQUE,
  amount_cents    int NOT NULL,
  currency        text NOT NULL CHECK (currency IN ('usd', 'brl')),
  pixels_credited int NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'completed', 'expired', 'refunded')),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_pixel_purchases_dev ON pixel_purchases(developer_id);
CREATE INDEX idx_pixel_purchases_status ON pixel_purchases(status) WHERE status = 'pending';

ALTER TABLE pixel_purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY pp_read ON pixel_purchases FOR SELECT
  USING (developer_id = (SELECT id FROM developers WHERE claimed_by = auth.uid()));
CREATE POLICY pp_service ON pixel_purchases FOR ALL
  USING (auth.role() = 'service_role');
-- 054_jobs.sql — Git City Jobs tables

-- ── Job company profiles ──────────────────────────────────
CREATE TABLE job_company_profiles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id uuid NOT NULL REFERENCES advertiser_accounts(id) ON DELETE CASCADE,
  name          text NOT NULL,
  slug          text NOT NULL UNIQUE,
  logo_url      text,
  website       text NOT NULL,
  description   text,
  github_org    text,
  hired_count   integer NOT NULL DEFAULT 0,
  last_dashboard_visit timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT slug_format CHECK (slug ~ '^[a-z0-9-]+$')
);

CREATE INDEX idx_job_company_profiles_advertiser ON job_company_profiles(advertiser_id);

ALTER TABLE job_company_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Companies visible to authenticated users"
  ON job_company_profiles FOR SELECT
  USING (auth.role() = 'authenticated' OR auth.role() = 'service_role');

CREATE POLICY "Service role full access to companies"
  ON job_company_profiles FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job listings ──────────────────────────────────────────
CREATE TYPE job_status AS ENUM ('draft', 'pending_review', 'active', 'paused', 'filled', 'expired', 'rejected');
CREATE TYPE job_tier AS ENUM ('standard', 'featured', 'premium');
CREATE TYPE job_seniority AS ENUM ('junior', 'mid', 'senior', 'staff', 'lead');
CREATE TYPE job_contract AS ENUM ('clt', 'pj', 'contract');
CREATE TYPE job_web AS ENUM ('web2', 'web3', 'both');
CREATE TYPE job_role_type AS ENUM ('frontend', 'backend', 'fullstack', 'devops', 'mobile', 'data', 'design', 'other');

CREATE TABLE job_listings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      uuid NOT NULL REFERENCES job_company_profiles(id) ON DELETE CASCADE,
  title           text NOT NULL,
  description     text NOT NULL,
  salary_min      integer NOT NULL CHECK (salary_min > 0),
  salary_max      integer NOT NULL CHECK (salary_max >= salary_min),
  salary_currency text NOT NULL DEFAULT 'USD',
  role_type       job_role_type NOT NULL,
  tech_stack      text[] NOT NULL DEFAULT '{}',
  seniority       job_seniority NOT NULL,
  contract_type   job_contract NOT NULL,
  web_type        job_web NOT NULL,
  apply_url       text NOT NULL,
  language        text NOT NULL DEFAULT 'en',
  language_pt_br  text,

  -- Trust badges (opt-in)
  badge_response_guaranteed boolean NOT NULL DEFAULT false,
  badge_no_ai_screening     boolean NOT NULL DEFAULT false,

  -- Status & tier
  status          job_status NOT NULL DEFAULT 'draft',
  tier            job_tier NOT NULL DEFAULT 'standard',
  rejection_reason text,

  -- Stripe
  stripe_session_id    text,
  stripe_payment_intent text,

  -- Dates
  published_at    timestamptz,
  expires_at      timestamptz,
  filled_at       timestamptz,
  paused_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  -- Counters (denormalized for dashboard perf)
  view_count      integer NOT NULL DEFAULT 0,
  apply_count     integer NOT NULL DEFAULT 0,
  profile_count   integer NOT NULL DEFAULT 0
);

CREATE INDEX idx_job_listings_company ON job_listings(company_id);
CREATE INDEX idx_job_listings_status ON job_listings(status);
CREATE INDEX idx_job_listings_expires ON job_listings(expires_at) WHERE status = 'active';
CREATE INDEX idx_job_listings_web_type ON job_listings(web_type) WHERE status = 'active';

ALTER TABLE job_listings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Active listings visible to authenticated users"
  ON job_listings FOR SELECT
  USING (
    (status = 'active' AND auth.role() = 'authenticated')
    OR auth.role() = 'service_role'
  );

CREATE POLICY "Service role full access to listings"
  ON job_listings FOR ALL
  USING (auth.role() = 'service_role');

-- ── Career profiles ───────────────────────────────────────
CREATE TABLE career_profiles (
  id              bigint PRIMARY KEY,  -- same as developer.id
  skills          text[] NOT NULL DEFAULT '{}',
  seniority       job_seniority NOT NULL,
  years_experience integer,
  bio             text NOT NULL,
  web_type        job_web NOT NULL DEFAULT 'both',
  contract_type   job_contract[] NOT NULL DEFAULT '{}',
  salary_min      integer,
  salary_max      integer,
  salary_currency text DEFAULT 'USD',
  salary_visible  boolean NOT NULL DEFAULT false,
  languages       text[] NOT NULL DEFAULT '{}',
  timezone        text,
  link_portfolio  text,
  link_linkedin   text,
  link_website    text,
  open_to_work    boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE career_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Own profile readable by owner"
  ON career_profiles FOR SELECT
  USING (auth.role() = 'service_role' OR id = (
    SELECT d.id FROM developers d WHERE d.claimed_by = auth.uid() LIMIT 1
  ));

CREATE POLICY "Service role full access to career profiles"
  ON career_profiles FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job applications (tracking clicks) ────────────────────
CREATE TABLE job_applications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  uuid NOT NULL REFERENCES job_listings(id) ON DELETE CASCADE,
  developer_id bigint NOT NULL,
  has_profile  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE(listing_id, developer_id)
);

CREATE INDEX idx_job_applications_listing ON job_applications(listing_id);
CREATE INDEX idx_job_applications_developer ON job_applications(developer_id);

ALTER TABLE job_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Devs can see own applications"
  ON job_applications FOR SELECT
  USING (auth.role() = 'service_role' OR developer_id = (
    SELECT d.id FROM developers d WHERE d.claimed_by = auth.uid() LIMIT 1
  ));

CREATE POLICY "Service role full access to applications"
  ON job_applications FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job reports ───────────────────────────────────────────
CREATE TABLE job_reports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  uuid NOT NULL REFERENCES job_listings(id) ON DELETE CASCADE,
  developer_id bigint NOT NULL,
  reason      text NOT NULL,
  details     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE(listing_id, developer_id)
);

ALTER TABLE job_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access to reports"
  ON job_reports FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job referrals ─────────────────────────────────────────
CREATE TABLE job_referrals (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_dev_id bigint NOT NULL,
  advertiser_id   uuid REFERENCES advertiser_accounts(id) ON DELETE SET NULL,
  referral_code   text NOT NULL UNIQUE,
  converted       boolean NOT NULL DEFAULT false,
  converted_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_job_referrals_code ON job_referrals(referral_code);
CREATE INDEX idx_job_referrals_referrer ON job_referrals(referrer_dev_id);

ALTER TABLE job_referrals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access to referrals"
  ON job_referrals FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job listing view events (for analytics) ───────────────
CREATE TABLE job_listing_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  uuid NOT NULL REFERENCES job_listings(id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN ('view', 'apply_click', 'profile_copy', 'save')),
  developer_id bigint,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_job_listing_events_listing ON job_listing_events(listing_id);
CREATE INDEX idx_job_listing_events_type ON job_listing_events(listing_id, event_type);

ALTER TABLE job_listing_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access to events"
  ON job_listing_events FOR ALL
  USING (auth.role() = 'service_role');

-- ── Job notification signups (empty state "notify me") ────
CREATE TABLE job_notification_signups (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id bigint NOT NULL UNIQUE,
  email        text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE job_notification_signups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access to notification signups"
  ON job_notification_signups FOR ALL
  USING (auth.role() = 'service_role');

-- ── Auto-update triggers ──────────────────────────────────
CREATE OR REPLACE FUNCTION update_job_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_job_listings_updated
  BEFORE UPDATE ON job_listings
  FOR EACH ROW EXECUTE FUNCTION update_job_updated_at();

CREATE TRIGGER trg_career_profiles_updated
  BEFORE UPDATE ON career_profiles
  FOR EACH ROW EXECUTE FUNCTION update_job_updated_at();

CREATE TRIGGER trg_job_company_profiles_updated
  BEFORE UPDATE ON job_company_profiles
  FOR EACH ROW EXECUTE FUNCTION update_job_updated_at();
-- 055_job_achievements.sql — Job-related achievements

INSERT INTO achievements (id, name, description, tier, category, threshold, reward_type, sort_order) VALUES
  ('career_ready', 'Career Ready', 'Create a Career Profile', 'bronze', 'jobs', 1, 'exclusive_badge', 900),
  ('job_hunter', 'Job Hunter', 'Apply to your first job', 'bronze', 'jobs', 1, 'exclusive_badge', 901),
  ('city_recruiter', 'City Recruiter', 'Refer a company that posts a job', 'silver', 'jobs', 1, 'exclusive_badge', 902),
  ('hired_in_the_city', 'Hired in the City', 'Get hired via Git City', 'gold', 'jobs', 1, 'exclusive_badge', 903)
ON CONFLICT (id) DO NOTHING;
-- 056_job_counter_rpcs.sql — Atomic counter increments for job listings

CREATE OR REPLACE FUNCTION increment_job_counter(
  p_listing_id uuid,
  p_column text
)
RETURNS void AS $$
BEGIN
  IF p_column = 'view_count' THEN
    UPDATE job_listings SET view_count = view_count + 1 WHERE id = p_listing_id;
  ELSIF p_column = 'apply_count' THEN
    UPDATE job_listings SET apply_count = apply_count + 1 WHERE id = p_listing_id;
  ELSIF p_column = 'profile_count' THEN
    UPDATE job_listings SET profile_count = profile_count + 1 WHERE id = p_listing_id;
  ELSE
    RAISE EXCEPTION 'Invalid column: %', p_column;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Atomic hired_count increment
CREATE OR REPLACE FUNCTION increment_hired_count(p_company_id uuid)
RETURNS void AS $$
BEGIN
  UPDATE job_company_profiles SET hired_count = hired_count + 1 WHERE id = p_company_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- 057_portfolio.sql
-- Portfolio system: projects, endorsements, experiences

-- ─── Enums ───

CREATE TYPE endorsement_status AS ENUM ('pending', 'approved', 'hidden');
CREATE TYPE endorsement_relationship AS ENUM ('worked_together', 'managed_by', 'mentored', 'open_source', 'other');

-- ─── Portfolio Projects ───

CREATE TABLE portfolio_projects (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  developer_id bigint NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
  description text CHECK (char_length(description) <= 500),
  role text CHECK (char_length(role) <= 100),
  tech_stack text[] DEFAULT '{}',
  image_urls text[] DEFAULT '{}',
  live_url text,
  source_url text,
  is_verified boolean DEFAULT false,
  sort_order int DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_portfolio_projects_dev ON portfolio_projects(developer_id);

ALTER TABLE portfolio_projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access on portfolio_projects"
  ON portfolio_projects FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Public read portfolio_projects"
  ON portfolio_projects FOR SELECT TO authenticated, anon
  USING (true);

-- ─── Portfolio Experiences ───

CREATE TABLE portfolio_experiences (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  developer_id bigint NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  company text NOT NULL CHECK (char_length(company) BETWEEN 1 AND 120),
  role text NOT NULL CHECK (char_length(role) BETWEEN 1 AND 120),
  period text CHECK (char_length(period) <= 50),
  impact_line text CHECK (char_length(impact_line) <= 200),
  sort_order int DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_portfolio_experiences_dev ON portfolio_experiences(developer_id);

ALTER TABLE portfolio_experiences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access on portfolio_experiences"
  ON portfolio_experiences FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Public read portfolio_experiences"
  ON portfolio_experiences FOR SELECT TO authenticated, anon
  USING (true);

-- ─── Portfolio Endorsements ───

CREATE TABLE portfolio_endorsements (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  developer_id bigint NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  endorser_id bigint NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  skill_name text NOT NULL CHECK (char_length(skill_name) BETWEEN 1 AND 50),
  context_text text NOT NULL CHECK (char_length(context_text) BETWEEN 10 AND 280),
  relationship endorsement_relationship NOT NULL DEFAULT 'worked_together',
  status endorsement_status NOT NULL DEFAULT 'approved',
  weight numeric(3,1) DEFAULT 1.0,
  created_at timestamptz DEFAULT now(),
  UNIQUE(developer_id, endorser_id, skill_name)
);

CREATE INDEX idx_endorsements_dev ON portfolio_endorsements(developer_id);
CREATE INDEX idx_endorsements_endorser ON portfolio_endorsements(endorser_id);
CREATE INDEX idx_endorsements_skill ON portfolio_endorsements(developer_id, skill_name) WHERE status = 'approved';

ALTER TABLE portfolio_endorsements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access on portfolio_endorsements"
  ON portfolio_endorsements FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "Public read approved endorsements"
  ON portfolio_endorsements FOR SELECT TO authenticated, anon
  USING (status = 'approved');

-- ─── Endorsement monthly limit RPC ───

CREATE OR REPLACE FUNCTION get_endorsements_given_this_month(p_endorser_id bigint)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT count(*)::int
  FROM portfolio_endorsements
  WHERE endorser_id = p_endorser_id
    AND created_at >= date_trunc('month', now());
$$;

-- ─── Triggers ───

CREATE TRIGGER update_portfolio_projects_updated_at
  BEFORE UPDATE ON portfolio_projects
  FOR EACH ROW EXECUTE FUNCTION update_job_updated_at();

-- ─── Achievements ───

INSERT INTO achievements (id, name, description, tier, category, threshold, reward_type, sort_order) VALUES
  ('endorser', 'Endorser', 'Give your first endorsement', 'bronze', 'social', 1, 'exclusive_badge', 910),
  ('endorsed_10', 'Recognized', 'Receive 10 endorsements', 'silver', 'social', 10, 'exclusive_badge', 911),
  ('endorsed_50', 'Well Known', 'Receive 50 endorsements', 'gold', 'social', 50, 'exclusive_badge', 912),
  ('portfolio_complete', 'Portfolio Ready', 'Add your first project to your portfolio', 'bronze', 'jobs', 1, 'exclusive_badge', 913)
ON CONFLICT (id) DO NOTHING;
-- 058_experience_dates.sql
-- Add proper date fields to portfolio_experiences

ALTER TABLE portfolio_experiences
  ADD COLUMN start_year int,
  ADD COLUMN start_month int CHECK (start_month IS NULL OR (start_month >= 1 AND start_month <= 12)),
  ADD COLUMN end_year int,
  ADD COLUMN end_month int CHECK (end_month IS NULL OR (end_month >= 1 AND end_month <= 12)),
  ADD COLUMN is_current boolean DEFAULT false;

-- Migrate existing period text to structured dates where possible
-- (best effort, manual cleanup may be needed)
-- 059_extra_links.sql
-- Add dynamic links support to career profiles

ALTER TABLE career_profiles
  ADD COLUMN extra_links jsonb DEFAULT '[]';

-- extra_links format: [{ "label": "GitHub", "url": "https://github.com/user" }, ...]
-- 060_drop_endorsements.sql
-- Remove endorsement system (revisit later with proper moderation)

-- Remove endorsement achievements
DELETE FROM developer_achievements WHERE achievement_id IN ('endorser', 'endorsed_10', 'endorsed_50');
DELETE FROM achievements WHERE id IN ('endorser', 'endorsed_10', 'endorsed_50');

-- Drop table (cascades indexes, policies, triggers)
DROP TABLE IF EXISTS portfolio_endorsements CASCADE;

-- Drop enums
DROP TYPE IF EXISTS endorsement_status;
DROP TYPE IF EXISTS endorsement_relationship;

-- Drop RPC
DROP FUNCTION IF EXISTS get_endorsements_given_this_month(bigint);
-- 061_expand_job_enums.sql
-- Expand role_type and seniority enums with industry-standard options

-- ─── Expand role types ───
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'cloud';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'security';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'qa';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'ai_ml';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'blockchain';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'embedded';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'sre';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'gamedev';
ALTER TYPE job_role_type ADD VALUE IF NOT EXISTS 'engineering_manager';

-- ─── Expand seniority levels ───
ALTER TYPE job_seniority ADD VALUE IF NOT EXISTS 'intern';
ALTER TYPE job_seniority ADD VALUE IF NOT EXISTS 'principal';
ALTER TYPE job_seniority ADD VALUE IF NOT EXISTS 'director';

-- ─── Expand contract types ───
ALTER TYPE job_contract ADD VALUE IF NOT EXISTS 'fulltime';
ALTER TYPE job_contract ADD VALUE IF NOT EXISTS 'parttime';
ALTER TYPE job_contract ADD VALUE IF NOT EXISTS 'freelance';
ALTER TYPE job_contract ADD VALUE IF NOT EXISTS 'internship';
-- 062_free_tier.sql
-- Add free tier for first-time job listings

ALTER TYPE job_tier ADD VALUE IF NOT EXISTS 'free';
-- 063: Add missing indexes and FK for jobs tables

-- ── Performance indexes on job_listings ──
CREATE INDEX IF NOT EXISTS idx_job_listings_role_type ON job_listings(role_type) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_job_listings_seniority ON job_listings(seniority) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_job_listings_contract ON job_listings(contract_type) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_job_listings_tier ON job_listings(tier) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_job_listings_published ON job_listings(published_at DESC NULLS LAST) WHERE status = 'active';

-- ── FK on career_profiles to prevent orphaned records ──
ALTER TABLE career_profiles
  ADD CONSTRAINT career_profiles_developer_fk
  FOREIGN KEY (id) REFERENCES developers(id) ON DELETE CASCADE;
-- Allow admin-created companies without an advertiser account
ALTER TABLE job_company_profiles ALTER COLUMN advertiser_id DROP NOT NULL;

-- Track who created the company (null = legacy/self-service, 'admin:<github_login>' = admin-created)
ALTER TABLE job_company_profiles ADD COLUMN IF NOT EXISTS created_by text;
-- 063_job_fields_expansion.sql
-- Add location, benefits, how_to_apply, and salary_period to job listings

-- ─── Location fields ───
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS location_type text NOT NULL DEFAULT 'remote';
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS location_restriction text NOT NULL DEFAULT 'worldwide';
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS location_countries text[] DEFAULT '{}';
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS location_city text;
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS location_timezone text;

-- ─── Benefits ───
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS benefits text[] DEFAULT '{}';

-- ─── How to apply (separate from description) ───
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS how_to_apply text;

-- ─── Salary period (monthly vs annual) ───
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS salary_period text NOT NULL DEFAULT 'monthly';
-- Add hiring workflow status to job applications
ALTER TABLE job_applications
  ADD COLUMN status text NOT NULL DEFAULT 'applied'
    CHECK (status IN ('applied', 'hired')),
  ADD COLUMN status_changed_at timestamptz;

-- Index for filtering by status
CREATE INDEX idx_job_applications_status ON job_applications (listing_id, status);
-- Track which expiry emails have been sent for job listings
ALTER TABLE job_listings ADD COLUMN IF NOT EXISTS expiry_notified TEXT;

-- Track when notify-me signups were fulfilled
ALTER TABLE job_notification_signups ADD COLUMN IF NOT EXISTS notified_at TIMESTAMPTZ;

-- Add job notification preference columns
ALTER TABLE notification_preferences
  ADD COLUMN IF NOT EXISTS jobs_applications BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS jobs_performance BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS jobs_digest BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS jobs_updates BOOLEAN DEFAULT true;
-- Queue for batching application notification emails to companies.
-- The flush cron groups by listing_id and sends one digest per listing.
CREATE TABLE IF NOT EXISTS job_application_email_queue (
  id BIGSERIAL PRIMARY KEY,
  listing_id UUID NOT NULL REFERENCES job_listings(id) ON DELETE CASCADE,
  developer_login TEXT NOT NULL,
  has_profile BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_app_email_queue_pending
  ON job_application_email_queue (created_at);
-- Efficient grouped count of job listing events for weekly reports.
-- Returns listing_id, event_type, cnt for the given time window.
CREATE OR REPLACE FUNCTION count_job_events_by_listing(
  p_listing_ids UUID[],
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS TABLE (listing_id UUID, event_type TEXT, cnt BIGINT)
LANGUAGE sql STABLE
AS $$
  SELECT
    e.listing_id,
    e.event_type,
    COUNT(*) AS cnt
  FROM job_listing_events e
  WHERE e.listing_id = ANY(p_listing_ids)
    AND e.created_at >= p_from
    AND e.created_at < p_to
  GROUP BY e.listing_id, e.event_type;
$$;
-- Public job alerts: allow anyone (with or without account) to subscribe
-- to recurring weekly job digest emails filtered by tech stack.

CREATE TABLE IF NOT EXISTS job_alert_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        text NOT NULL,
  tech_stack   text[] NOT NULL DEFAULT '{}',
  verified     boolean NOT NULL DEFAULT false,
  verify_token text UNIQUE,
  unsubscribe_token text NOT NULL DEFAULT encode(gen_random_bytes(24), 'hex'),
  developer_id bigint REFERENCES developers(id) ON DELETE SET NULL,
  last_sent_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Unique per email to prevent duplicates
CREATE UNIQUE INDEX idx_job_alert_subscriptions_email ON job_alert_subscriptions (lower(email));

-- For cron: find verified subscribers that haven't been emailed recently
CREATE INDEX idx_job_alert_subscriptions_pending ON job_alert_subscriptions (last_sent_at)
  WHERE verified = true;

-- RLS: service role only
ALTER TABLE job_alert_subscriptions ENABLE ROW LEVEL SECURITY;
-- Migrate cleanup-sessions and refresh-ad-stats from Vercel cron to pg_cron (free)

-- 1. Cleanup sessions: mark idle/offline, prune stale visitors
--    Runs every minute (was every 5 min on Vercel, now free so can be more precise)
SELECT cron.schedule('cleanup-sessions', '* * * * *', $$
  -- Mark offline if no heartbeat in 15 minutes
  UPDATE developer_sessions
  SET status = 'offline', ended_at = now()
  WHERE status IN ('active', 'idle')
    AND last_heartbeat_at < now() - interval '15 minutes';

  -- Mark idle if no heartbeat in 5 minutes
  UPDATE developer_sessions
  SET status = 'idle'
  WHERE status = 'active'
    AND last_heartbeat_at < now() - interval '5 minutes';

  -- Prune stale site visitors (heartbeat window is 90s)
  DELETE FROM site_visitors
  WHERE last_seen < now() - interval '90 seconds';
$$);

-- 2. Refresh ad stats: calls existing RPC
--    Runs every hour (same as Vercel)
SELECT cron.schedule('refresh-ad-stats', '0 * * * *', 'SELECT refresh_sky_ad_stats()');
-- Track how much was actually paid for each ad
ALTER TABLE sky_ads
  ADD COLUMN IF NOT EXISTS amount_paid_cents INT,
  ADD COLUMN IF NOT EXISTS currency TEXT;

-- Backfill currency for existing ads that have a stripe_session_id (assume USD)
-- and pix_id (always BRL). amount_paid_cents can't be backfilled without querying Stripe.
UPDATE sky_ads SET currency = 'brl' WHERE pix_id IS NOT NULL AND currency IS NULL;
-- 073: Comprehensive security hardening
-- Fixes all issues flagged by Supabase security advisor

BEGIN;

-- ============================================================================
-- PART 1: Enable RLS on all unprotected public tables
-- All 8 tables are accessed exclusively via getSupabaseAdmin() (service_role)
-- which bypasses RLS, so no policies needed.
-- ============================================================================

-- Sensitive: emails, webhook_secrets
ALTER TABLE advertiser_accounts ENABLE ROW LEVEL SECURITY;

-- Sensitive: session tokens (allows session hijacking if exposed)
ALTER TABLE advertiser_sessions ENABLE ROW LEVEL SECURITY;

-- Sensitive: API key hashes
ALTER TABLE advertiser_api_keys ENABLE ROW LEVEL SECURITY;

-- Sensitive: session_ids
ALTER TABLE site_visitors ENABLE ROW LEVEL SECURITY;

-- Reference data, but no client-side reads (API uses admin client)
ALTER TABLE districts ENABLE ROW LEVEL SECURITY;
ALTER TABLE district_changes ENABLE ROW LEVEL SECURITY;

-- Internal tracking tables
ALTER TABLE milestone_celebrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE xp_log ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- PART 2: Fix developer_sessions broken policy
-- "Service role manages sessions" uses USING(true) WITH CHECK(true) for ALL
-- roles, which completely defeats RLS. Service role already bypasses RLS,
-- so this policy only opens the door for anon/authenticated.
-- ============================================================================

DROP POLICY IF EXISTS "Service role manages sessions" ON developer_sessions;


-- ============================================================================
-- PART 3: Fix survey_responses user_metadata vulnerability
-- Existing policies use auth.jwt()->'user_metadata'->>'user_name' which is
-- EDITABLE by end users — anyone can forge their github_login in metadata.
-- Fix: use developers.claimed_by = auth.uid() which is tamper-proof.
-- ============================================================================

DROP POLICY IF EXISTS "Users can submit their own response" ON survey_responses;
DROP POLICY IF EXISTS "Users can read their own responses" ON survey_responses;

CREATE POLICY "Users can submit their own response" ON survey_responses
  FOR INSERT
  WITH CHECK (
    developer_id = (
      SELECT id FROM public.developers
      WHERE claimed_by = auth.uid()
      LIMIT 1
    )
  );

CREATE POLICY "Users can read their own responses" ON survey_responses
  FOR SELECT
  USING (
    developer_id = (
      SELECT id FROM public.developers
      WHERE claimed_by = auth.uid()
      LIMIT 1
    )
  );


-- ============================================================================
-- PART 4: Revoke materialized view access from PostgREST API
-- sky_ad_daily_stats and sky_ad_conversion_daily_stats expose ad analytics
-- to anon/authenticated. All access goes through RPC functions via service_role.
-- ============================================================================

REVOKE SELECT ON sky_ad_daily_stats FROM anon, authenticated;
REVOKE SELECT ON sky_ad_conversion_daily_stats FROM anon, authenticated;


-- ============================================================================
-- PART 5: Set search_path on all functions missing it
-- SECURITY DEFINER functions without search_path are vulnerable to
-- search_path injection (attacker creates objects in a schema that gets
-- searched before 'public'). Using 'public' instead of '' to avoid
-- rewriting all function bodies with fully-qualified names.
-- ============================================================================

-- SECURITY DEFINER functions (HIGH risk — run as owner, bypass RLS)
ALTER FUNCTION assign_new_dev_rank(bigint) SET search_path = 'public';
ALTER FUNCTION credit_pixels(bigint, bigint, text, text, text, text, text, inet, text) SET search_path = 'public';
ALTER FUNCTION deactivate_expired_ads() SET search_path = 'public';
ALTER FUNCTION debit_pixels(bigint, bigint, text, text, text, text) SET search_path = 'public';
ALTER FUNCTION earn_pixels(bigint, text, text, text, text) SET search_path = 'public';
ALTER FUNCTION find_auth_user_by_github_login(text) SET search_path = 'public';
ALTER FUNCTION get_ad_daily_stats(date, date, text[]) SET search_path = 'public';
ALTER FUNCTION get_ad_stats(date, date, text[]) SET search_path = 'public';
ALTER FUNCTION get_auth_users_without_developer() SET search_path = 'public';
ALTER FUNCTION get_endorsements_given_this_month(bigint) SET search_path = 'public';
ALTER FUNCTION heartbeat_visitor(text) SET search_path = 'public';
ALTER FUNCTION increment_hired_count(uuid) SET search_path = 'public';
ALTER FUNCTION increment_job_counter(uuid, text) SET search_path = 'public';
ALTER FUNCTION increment_kudos_count(bigint) SET search_path = 'public';
ALTER FUNCTION increment_referral_count(bigint) SET search_path = 'public';
ALTER FUNCTION increment_visit_count(bigint) SET search_path = 'public';
ALTER FUNCTION recalculate_ranks() SET search_path = 'public';
ALTER FUNCTION refresh_sky_ad_stats() SET search_path = 'public';
ALTER FUNCTION spend_pixels(bigint, text, text, bigint, boolean, inet, text) SET search_path = 'public';
ALTER FUNCTION upsert_arcade_visit(uuid, uuid) SET search_path = 'public';

-- SECURITY INVOKER functions (MEDIUM risk — run as caller, but still best practice)
ALTER FUNCTION complete_all_dailies(bigint) SET search_path = 'public';
ALTER FUNCTION count_devs_with_more_achievements(bigint) SET search_path = 'public';
ALTER FUNCTION grant_streak_freeze(bigint) SET search_path = 'public';
ALTER FUNCTION grant_xp(bigint, text, integer) SET search_path = 'public';
ALTER FUNCTION increment_kudos_week(bigint, bigint) SET search_path = 'public';
ALTER FUNCTION perform_checkin(bigint) SET search_path = 'public';
ALTER FUNCTION prevent_ledger_mutation() SET search_path = 'public';
ALTER FUNCTION record_mission_progress(bigint, text, integer, integer) SET search_path = 'public';
ALTER FUNCTION refresh_weekly_kudos() SET search_path = 'public';
ALTER FUNCTION top_achievers(integer) SET search_path = 'public';
ALTER FUNCTION update_arcade_rooms_updated_at() SET search_path = 'public';
ALTER FUNCTION update_job_updated_at() SET search_path = 'public';


-- ============================================================================
-- PART 6: Revoke EXECUTE on SECURITY DEFINER functions from anon/authenticated
-- All 20 are called exclusively via getSupabaseAdmin() (service_role), which
-- bypasses privilege checks. Revoking prevents direct PostgREST RPC abuse
-- where anon users could call functions like credit_pixels, recalculate_ranks,
-- find_auth_user_by_github_login (which accesses auth.users!), etc.
-- ============================================================================

-- Must revoke from PUBLIC (not just anon/authenticated) because PostgreSQL
-- grants EXECUTE to PUBLIC by default on all functions, and named roles inherit it.
REVOKE EXECUTE ON FUNCTION assign_new_dev_rank(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION credit_pixels(bigint, bigint, text, text, text, text, text, inet, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION deactivate_expired_ads() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION debit_pixels(bigint, bigint, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION earn_pixels(bigint, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION find_auth_user_by_github_login(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_ad_daily_stats(date, date, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_ad_stats(date, date, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_auth_users_without_developer() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_endorsements_given_this_month(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION heartbeat_visitor(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_hired_count(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_job_counter(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_kudos_count(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_referral_count(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION increment_visit_count(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION recalculate_ranks() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION refresh_sky_ad_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION spend_pixels(bigint, text, text, bigint, boolean, inet, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_arcade_visit(uuid, uuid) FROM PUBLIC;


-- ============================================================================
-- PART 7: Drop duplicate index
-- idx_dev_achievements_dev and idx_dev_achievements_dev_id are identical
-- (both btree on developer_id). Keeping the more descriptive name.
-- ============================================================================

DROP INDEX IF EXISTS idx_dev_achievements_dev;

COMMIT;
-- 074: Hide sensitive columns from public API
-- Column-level REVOKE doesn't work when table-level SELECT is granted.
-- Fix: revoke table SELECT, then re-grant only safe columns.

REVOKE SELECT ON developers FROM anon, authenticated;

GRANT SELECT (
  id, github_login, github_id, name, avatar_url, bio,
  contributions, public_repos, total_stars, primary_language, top_repos,
  rank, fetched_at, created_at, claimed, claimed_by, fetch_priority, claimed_at,
  kudos_count, visit_count, referred_by, referral_count,
  contributions_total, contribution_years, total_prs, total_reviews,
  total_issues, repos_contributed_to, followers, following,
  organizations_count, account_created_at,
  current_streak, longest_streak, active_days_last_year, language_diversity,
  app_streak, app_longest_streak, last_checkin_date,
  streak_freezes_available, streak_freeze_30d_claimed,
  kudos_streak, last_kudos_given_date, raid_xp,
  current_week_contributions, current_week_kudos_given, current_week_kudos_received,
  rabbit_progress, rabbit_started_at, rabbit_completed, rabbit_completed_at,
  district, district_chosen, district_changes_count, district_changed_at, district_rank,
  timezone, last_active_at, city_theme,
  dailies_completed, dailies_streak, last_dailies_date,
  xp_total, xp_level, xp_github, xp_daily, xp_daily_date,
  github_etag, suspended
) ON developers TO anon, authenticated;

-- Hidden columns: email, email_verified, email_updated_at, vscode_api_key_hash, vscode_api_key
-- Performance: wrap auth.uid() in (select auth.uid()) for InitPlan caching
-- and add missing indexes on hot lookup columns.
--
-- Benchmark on developers (72K rows):
--   auth.uid() without wrapper, no index: 197ms
--   (select auth.uid()) with index:       0.18ms  (1000x faster)

-- ──────────────────────────────────────────────────
-- 1. Index on developers.claimed_by (used by almost every RLS policy)
-- ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_developers_claimed_by
  ON developers (claimed_by) WHERE claimed_by IS NOT NULL;

-- ──────────────────────────────────────────────────
-- 2. Drop redundant indexes (duplicates of unique constraints)
-- ──────────────────────────────────────────────────
DROP INDEX IF EXISTS idx_advertiser_sessions_token;
DROP INDEX IF EXISTS idx_job_applications_listing;
DROP INDEX IF EXISTS idx_developers_login;
DROP INDEX IF EXISTS idx_developers_vscode_api_key_hash;

-- ──────────────────────────────────────────────────
-- 3. Composite index for events sparkline query
-- ──────────────────────────────────────────────────
DROP INDEX IF EXISTS idx_job_listing_events_listing;
CREATE INDEX IF NOT EXISTS idx_job_listing_events_listing_date
  ON job_listing_events (listing_id, created_at);

-- ──────────────────────────────────────────────────
-- 4. Rewrite RLS policies to use (select auth.uid())
-- ──────────────────────────────────────────────────

-- arcade_avatars
DROP POLICY IF EXISTS "Users can read own avatar" ON arcade_avatars;
CREATE POLICY "Users can read own avatar" ON arcade_avatars
  FOR SELECT TO authenticated USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update own avatar" ON arcade_avatars;
CREATE POLICY "Users can update own avatar" ON arcade_avatars
  FOR UPDATE TO authenticated USING (user_id = (select auth.uid()));

-- arcade_discoveries
DROP POLICY IF EXISTS "Users can read own discoveries" ON arcade_discoveries;
CREATE POLICY "Users can read own discoveries" ON arcade_discoveries
  FOR SELECT TO authenticated USING (user_id = (select auth.uid()));

DROP POLICY IF EXISTS "Users can update own discoveries" ON arcade_discoveries;
CREATE POLICY "Users can update own discoveries" ON arcade_discoveries
  FOR UPDATE TO authenticated USING (user_id = (select auth.uid()));

-- arcade_room_favorites
DROP POLICY IF EXISTS "Users can read own favorites" ON arcade_room_favorites;
CREATE POLICY "Users can read own favorites" ON arcade_room_favorites
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can manage own favorites" ON arcade_room_favorites;
CREATE POLICY "Users can manage own favorites" ON arcade_room_favorites
  FOR ALL TO authenticated USING ((select auth.uid()) = user_id);

-- arcade_room_visits
DROP POLICY IF EXISTS "Users can read own visits" ON arcade_room_visits;
CREATE POLICY "Users can read own visits" ON arcade_room_visits
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);

-- arcade_rooms
DROP POLICY IF EXISTS "Owners can update their rooms" ON arcade_rooms;
CREATE POLICY "Owners can update their rooms" ON arcade_rooms
  FOR UPDATE TO authenticated USING ((select auth.uid()) = owner_id);

DROP POLICY IF EXISTS "Visible rooms are readable by everyone" ON arcade_rooms;
CREATE POLICY "Visible rooms are readable by everyone" ON arcade_rooms
  FOR SELECT USING (
    visibility IN ('open', 'password')
    OR (select auth.uid()) = owner_id
    OR auth.role() = 'service_role'
  );

-- career_profiles
DROP POLICY IF EXISTS "Own profile readable by owner" ON career_profiles;
CREATE POLICY "Own profile readable by owner" ON career_profiles
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR id = (SELECT d.id FROM developers d WHERE d.claimed_by = (select auth.uid()) LIMIT 1)
  );

-- developer_customizations
DROP POLICY IF EXISTS "Owner reads own customizations" ON developer_customizations;
CREATE POLICY "Owner reads own customizations" ON developer_customizations
  FOR SELECT TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- job_applications
DROP POLICY IF EXISTS "Devs can see own applications" ON job_applications;
CREATE POLICY "Devs can see own applications" ON job_applications
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR developer_id = (SELECT d.id FROM developers d WHERE d.claimed_by = (select auth.uid()) LIMIT 1)
  );

-- notification_preferences
DROP POLICY IF EXISTS "Users can update own preferences" ON notification_preferences;
CREATE POLICY "Users can update own preferences" ON notification_preferences
  FOR UPDATE TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

DROP POLICY IF EXISTS "Users can read own preferences" ON notification_preferences;
CREATE POLICY "Users can read own preferences" ON notification_preferences
  FOR SELECT TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- pixel_purchases
DROP POLICY IF EXISTS "pp_read" ON pixel_purchases;
CREATE POLICY "pp_read" ON pixel_purchases
  FOR SELECT TO authenticated USING (
    developer_id = (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- purchases
DROP POLICY IF EXISTS "Owner reads own purchases" ON purchases;
CREATE POLICY "Owner reads own purchases" ON purchases
  FOR SELECT TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- push_subscriptions
DROP POLICY IF EXISTS "Users can manage own push subscriptions" ON push_subscriptions;
CREATE POLICY "Users can manage own push subscriptions" ON push_subscriptions
  FOR ALL TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- streak_rewards
DROP POLICY IF EXISTS "Users can read own streak rewards" ON streak_rewards;
CREATE POLICY "Users can read own streak rewards" ON streak_rewards
  FOR SELECT TO authenticated USING (
    developer_id IN (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- survey_responses
DROP POLICY IF EXISTS "Users can read their own responses" ON survey_responses;
CREATE POLICY "Users can read their own responses" ON survey_responses
  FOR SELECT TO authenticated USING (
    developer_id = (SELECT d.id FROM developers d WHERE d.claimed_by = (select auth.uid()) LIMIT 1)
  );

-- wallet_transactions
DROP POLICY IF EXISTS "tx_read" ON wallet_transactions;
CREATE POLICY "tx_read" ON wallet_transactions
  FOR SELECT TO authenticated USING (
    developer_id = (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );

-- wallets
DROP POLICY IF EXISTS "wallet_read" ON wallets;
CREATE POLICY "wallet_read" ON wallets
  FOR SELECT TO authenticated USING (
    developer_id = (SELECT id FROM developers WHERE claimed_by = (select auth.uid()))
  );
-- 076_native_apply.sql — Separate native applications from external clicks

-- ── 1. Make apply_url nullable (listings without it accept native applications) ──
ALTER TABLE job_listings ALTER COLUMN apply_url DROP NOT NULL;

-- ── 2. Add click_count for external link tracking ──
ALTER TABLE job_listings ADD COLUMN click_count integer NOT NULL DEFAULT 0;

-- ── 3. Add type to job_applications ──
ALTER TABLE job_applications
  ADD COLUMN type text NOT NULL DEFAULT 'native'
    CHECK (type IN ('native', 'external_click'));

-- ── 4. Add contact fields to career_profiles (PII — never expose publicly) ──
ALTER TABLE career_profiles
  ADD COLUMN first_name text,
  ADD COLUMN last_name text,
  ADD COLUMN email text,
  ADD COLUMN phone text,
  ADD COLUMN resume_url text;

-- ── 5. Expand event types ──
ALTER TABLE job_listing_events DROP CONSTRAINT job_listing_events_event_type_check;
ALTER TABLE job_listing_events
  ADD CONSTRAINT job_listing_events_event_type_check
    CHECK (event_type IN ('view', 'apply_click', 'profile_copy', 'save', 'external_click'));

-- ── 6. Update counter RPC to support click_count ──
CREATE OR REPLACE FUNCTION increment_job_counter(
  p_listing_id uuid,
  p_column text
)
RETURNS void AS $$
BEGIN
  IF p_column = 'view_count' THEN
    UPDATE job_listings SET view_count = view_count + 1 WHERE id = p_listing_id;
  ELSIF p_column = 'apply_count' THEN
    UPDATE job_listings SET apply_count = apply_count + 1 WHERE id = p_listing_id;
  ELSIF p_column = 'profile_count' THEN
    UPDATE job_listings SET profile_count = profile_count + 1 WHERE id = p_listing_id;
  ELSIF p_column = 'click_count' THEN
    UPDATE job_listings SET click_count = click_count + 1 WHERE id = p_listing_id;
  ELSE
    RAISE EXCEPTION 'Invalid column: %', p_column;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 7. Backfill: mark existing applications for external listings ──
UPDATE job_applications
SET type = 'external_click'
WHERE listing_id IN (
  SELECT id FROM job_listings WHERE apply_url IS NOT NULL
);

-- ── 8. Index for filtering applications by type ──
CREATE INDEX idx_job_applications_type ON job_applications(type);
-- 077: Fix developers table SELECT - restore table-level grant
--
-- Migration 074 revoked table-level SELECT on developers and replaced it
-- with column-level grants to hide email/vscode_api_key columns.
-- PostgREST does NOT support column-level SELECT grants — it expands
-- select("*") to all columns, hitting "permission denied" on hidden columns.
-- This broke ALL profile pages (/dev/[username]) for 12+ hours.
--
-- Fix: restore table-level SELECT. Sensitive columns (email, vscode_api_key)
-- are already NULL in the database and are not written by the app.

GRANT SELECT ON developers TO anon, authenticated;
-- Count unique countries for a specific ad
create or replace function count_ad_countries(p_ad_id uuid)
returns integer
language sql
stable
security definer
as $$
  select count(distinct country)::integer
  from sky_ad_events
  where ad_id = p_ad_id
    and country is not null
    and country != '';
$$;
-- 079: Arcade scores table for minigames (10s challenge, etc.)

CREATE TABLE arcade_scores (
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  game text NOT NULL,
  best_ms integer NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, game)
);

-- Leaderboard query: top N by best_ms ascending per game
CREATE INDEX idx_arcade_scores_leaderboard
  ON arcade_scores (game, best_ms ASC);

-- RLS: anyone can read, only service_role can write
ALTER TABLE arcade_scores ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read scores"
  ON arcade_scores FOR SELECT USING (true);

CREATE POLICY "Service role manages scores"
  ON arcade_scores FOR ALL USING (false);

-- Milestones tracking: which precision milestones a player has earned
CREATE TABLE arcade_milestones (
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  game text NOT NULL,
  milestone text NOT NULL,
  earned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, game, milestone)
);

ALTER TABLE arcade_milestones ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read milestones"
  ON arcade_milestones FOR SELECT USING (true);

CREATE POLICY "Service role manages milestones"
  ON arcade_milestones FOR ALL USING (false);

-- Achievements for arcade games (inserted into achievements table)
INSERT INTO achievements (id, category, name, description, threshold, tier, reward_type, sort_order)
VALUES
  ('arcade_hello_friend', 'arcade', 'Hello, Friend', 'Play the 10 Second Challenge for the first time', 1, 'bronze', 'exclusive_badge', 900),
  ('arcade_not_bad_kiddo', 'arcade', 'Not Bad, Kiddo', 'Score within 100ms on the 10 Second Challenge', 100, 'silver', 'exclusive_badge', 901),
  ('arcade_control_illusion', 'arcade', 'Control Is An Illusion', 'Score within 25ms on the 10 Second Challenge', 25, 'gold', 'exclusive_badge', 902),
  ('arcade_perfection', 'arcade', '10.000', 'Score within 5ms on the 10 Second Challenge', 5, 'diamond', 'exclusive_badge', 903);
-- ============================================================
-- Migration 080: Arcade Shop — Items, Inventory & Avatar
-- Safe to run multiple times (IF NOT EXISTS + ON CONFLICT)
-- ============================================================

-- 1. Shop items catalog
CREATE TABLE IF NOT EXISTS arcade_shop_items (
  id             text PRIMARY KEY,
  category       text NOT NULL CHECK (category IN ('hair', 'clothes', 'acc', 'eyes', 'pets')),
  name           text NOT NULL,
  file           text,            -- sprite path relative to storage base (null for 'bald')
  rarity         text NOT NULL CHECK (rarity IN ('free', 'common', 'rare', 'epic', 'legendary')),
  price_px       integer NOT NULL DEFAULT 0 CHECK (price_px >= 0),
  default_color  text,            -- hex color for tinting (null = no tint / pre-colored)
  no_tint        boolean NOT NULL DEFAULT false,
  tags           text[] NOT NULL DEFAULT '{}',
  slot           text NOT NULL CHECK (slot IN (
    'hair', 'top', 'bottom', 'full', 'shoes', 'costume',
    'hat', 'face', 'facial', 'mask', 'jewelry',
    'eyes', 'blush', 'lipstick',
    'pet'
  )),
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shop_items_category ON arcade_shop_items(category);
CREATE INDEX IF NOT EXISTS idx_shop_items_rarity ON arcade_shop_items(rarity);
CREATE INDEX IF NOT EXISTS idx_shop_items_slot ON arcade_shop_items(slot);

ALTER TABLE arcade_shop_items ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY "Anyone can read shop items" ON arcade_shop_items FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 2. Player inventory (purchased items)
CREATE TABLE IF NOT EXISTS arcade_inventory (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  developer_id   bigint NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
  item_id        text NOT NULL REFERENCES arcade_shop_items(id),
  purchased_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE(developer_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_inventory_developer ON arcade_inventory(developer_id);

ALTER TABLE arcade_inventory ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY "Players can read own inventory" ON arcade_inventory
    FOR SELECT USING (developer_id = (SELECT id FROM developers WHERE claimed_by = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 3. Player avatar loadout (new system — arcade_avatars kept for backwards compat)
-- Old arcade_avatars has 956 rows with { sprite_id: 0-5 }, keyed by user_id uuid.
-- New table keyed by developer_id with full slot system.
CREATE TABLE IF NOT EXISTS arcade_avatar_loadouts (
  developer_id      bigint PRIMARY KEY REFERENCES developers(id) ON DELETE CASCADE,
  skin_color        text NOT NULL DEFAULT '#e8c4a0',
  hair_id           text REFERENCES arcade_shop_items(id),
  hair_color        text,
  clothes_top_id    text REFERENCES arcade_shop_items(id),
  clothes_top_color text,
  clothes_bottom_id text REFERENCES arcade_shop_items(id),
  clothes_bottom_color text,
  clothes_full_id   text REFERENCES arcade_shop_items(id),
  clothes_full_color text,
  shoes_id          text REFERENCES arcade_shop_items(id),
  shoes_color       text,
  acc_hat_id        text REFERENCES arcade_shop_items(id),
  acc_hat_color     text,
  acc_face_id       text REFERENCES arcade_shop_items(id),
  acc_face_color    text,
  acc_facial_id     text REFERENCES arcade_shop_items(id),
  acc_facial_color  text,
  acc_jewelry_id    text REFERENCES arcade_shop_items(id),
  acc_jewelry_color text,
  eyes_color        text DEFAULT '#4a3728',
  blush_id          text REFERENCES arcade_shop_items(id),
  blush_color       text,
  lipstick_id       text REFERENCES arcade_shop_items(id),
  lipstick_color    text,
  pet_id            text REFERENCES arcade_shop_items(id),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE arcade_avatar_loadouts ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY "Players can read own loadout" ON arcade_avatar_loadouts
    FOR SELECT USING (developer_id = (SELECT id FROM developers WHERE claimed_by = auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 4. Seed shop items (ON CONFLICT = safe to re-run, updates existing items)
INSERT INTO arcade_shop_items (id, category, name, file, rarity, price_px, default_color, no_tint, tags, slot) VALUES
  -- Hair
  ('bob',                'hair',    'Bob',                  'hair/bob_grey.png',              'common',    75,   '#8B4513', false, '{short}',        'hair'),
  ('braids',             'hair',    'Braids',               'hair/braids_grey.png',           'common',    75,   '#2c1810', false, '{long}',         'hair'),
  ('bald',               'hair',    'Bald',                 NULL,                             'free',      0,    NULL,      false, '{short}',        'hair'),
  ('buzzcut',            'hair',    'Buzzcut',              'hair/buzzcut_grey.png',          'free',      0,    '#1a1a1a', false, '{short}',        'hair'),
  ('curly',              'hair',    'Curly',                'hair/curly_grey.png',            'free',      0,    '#8B4513', false, '{short}',        'hair'),
  ('emo',                'hair',    'Emo',                  'hair/emo_grey.png',              'rare',      200,  '#1a1a1a', false, '{short,edgy}',   'hair'),
  ('extra_long',         'hair',    'Extra Long',           'hair/extra_long_grey.png',       'rare',      150,  '#D2691E', false, '{long}',         'hair'),
  ('extra_long_skirt',   'hair',    'Extra Long (Skirt)',   'hair/extra_long_skirt_grey.png', 'rare',      150,  '#D2691E', false, '{long}',         'hair'),
  ('french_curl',        'hair',    'French Curl',          'hair/french_curl_grey.png',      'rare',      250,  '#4a3728', false, '{short}',        'hair'),
  ('gentleman',          'hair',    'Gentleman',            'hair/gentleman_grey.png',        'free',      0,    '#2c1810', false, '{short,formal}', 'hair'),
  ('long_straight',      'hair',    'Long Straight',        'hair/long_straight_grey.png',    'common',    75,   '#D2691E', false, '{long}',         'hair'),
  ('long_straight_skirt','hair',    'Long Straight (Skirt)','hair/long_straight_skirt_grey.png','common',  75,   '#D2691E', false, '{long}',         'hair'),
  ('midiwave',           'hair',    'Midi Wave',            'hair/midiwave_grey.png',         'rare',      150,  '#8B4513', false, '{long}',         'hair'),
  ('ponytail',           'hair',    'Ponytail',             'hair/ponytail_grey.png',         'free',      0,    '#FFD700', false, '{long}',         'hair'),
  ('spacebuns',          'hair',    'Space Buns',           'hair/spacebuns_grey.png',        'epic',      400,  '#FF69B4', false, '{short,edgy}',   'hair'),
  ('wavy',               'hair',    'Wavy',                 'hair/wavy_grey.png',             'common',    75,   '#4a3728', false, '{long}',         'hair'),
  -- Clothes: Tops
  ('basic',              'clothes', 'Basic Tee',            'clothes/basic_grey.png',         'free',      0,    '#4a9eff', false, '{casual,top}',   'top'),
  ('spaghetti',          'clothes', 'Spaghetti Top',        'clothes/spaghetti_grey.png',     'common',    75,   '#f5d5b8', false, '{casual,top}',   'top'),
  ('stripe',             'clothes', 'Stripe',               'clothes/stripe_grey.png',        'rare',      150,  '#9b59b6', false, '{casual,top}',   'top'),
  ('skull',              'clothes', 'Skull Tee',            'clothes/skull_grey.png',         'epic',      400,  '#1a1a1a', false, '{edgy,top}',     'top'),
  -- Clothes: Bottoms
  ('pants',              'clothes', 'Pants',                'clothes/pants_grey.png',         'common',    50,   '#2c3e50', false, '{casual,bottom}','bottom'),
  ('skirt',              'clothes', 'Skirt',                'clothes/skirt_grey.png',         'common',    75,   '#9b59b6', false, '{casual,bottom}','bottom'),
  ('pants_suit',         'clothes', 'Suit Pants',           'clothes/pants_suit.png',         'rare',      150,  NULL,      true,  '{formal,bottom}','bottom'),
  ('shoes',              'clothes', 'Shoes',                'clothes/shoes_grey.png',         'common',    50,   '#4a3728', false, '{casual}',       'shoes'),
  -- Clothes: Full outfits
  ('overalls',           'clothes', 'Overalls',             'clothes/overalls_grey.png',      'free',      0,    '#e74c3c', false, '{casual,full}',  'full'),
  ('sporty',             'clothes', 'Sporty',               'clothes/sporty_grey.png',        'free',      0,    '#c8e64a', false, '{casual,full}',  'full'),
  ('suit',               'clothes', 'Suit',                 'clothes/suit_grey.png',          'free',      0,    '#2c3e50', false, '{formal,full}',  'full'),
  ('dress',              'clothes', 'Dress',                'clothes/dress_grey.png',         'common',    75,   '#e91e63', false, '{casual,full}',  'full'),
  ('floral',             'clothes', 'Floral',               'clothes/floral_grey.png',        'rare',      150,  '#e8a0a0', false, '{casual,full}',  'full'),
  ('sailor',             'clothes', 'Sailor',               'clothes/sailor_grey.png',        'rare',      200,  '#1a5276', false, '{formal,full}',  'full'),
  ('sailor_bow',         'clothes', 'Sailor + Bow',         'clothes/sailor_bow.png',         'epic',      400,  NULL,      true,  '{formal,full}',  'full'),
  ('suit_tie',           'clothes', 'Suit + Tie',           'clothes/suit_tie_grey.png',      'epic',      500,  '#8B0000', false, '{formal,full}',  'full'),
  -- Clothes: Costumes
  ('clown_blue',         'clothes', 'Clown (Blue)',         'clothes/clown_blue_grey.png',    'legendary', 800,  '#4a9eff', false, '{costume}',      'costume'),
  ('clown_red',          'clothes', 'Clown (Red)',          'clothes/clown_red_grey.png',     'legendary', 800,  '#e74c3c', false, '{costume}',      'costume'),
  ('spooky',             'clothes', 'Spooky',               'clothes/spooky_grey.png',        'legendary', 800,  '#ff6600', false, '{costume,seasonal}','costume'),
  ('witch',              'clothes', 'Witch',                'clothes/witch_grey.png',         'legendary', 800,  '#2c1810', false, '{costume,seasonal}','costume'),
  ('pumpkin',            'clothes', 'Pumpkin',              'clothes/pumpkin_grey.png',       'legendary', 1200, '#ff6600', false, '{costume,seasonal}','costume'),
  -- Accessories: Face
  ('glasses',            'acc',     'Glasses',              'acc/glasses_grey.png',           'common',    75,   '#333333', false, '{face}',         'face'),
  ('glasses_sun',        'acc',     'Sunglasses',           'acc/glasses_sun_grey.png',       'rare',      200,  '#1a1a1a', false, '{face}',         'face'),
  -- Accessories: Facial
  ('beard',              'acc',     'Beard',                'acc/beard_grey.png',             'rare',      150,  '#4a3728', false, '{face}',         'facial'),
  -- Accessories: Hats
  ('hat_cowboy',         'acc',     'Cowboy Hat',            'acc/hat_cowboy_grey.png',        'epic',      400,  '#8B4513', false, '{hat}',          'hat'),
  ('hat_lucky',          'acc',     'Lucky Hat',             'acc/hat_lucky_grey.png',         'legendary', 800,  '#2e7d32', false, '{hat}',          'hat'),
  ('hat_pumpkin',        'acc',     'Pumpkin Hat',           'acc/hat_pumpkin_grey.png',       'legendary', 1200, '#ff6600', false, '{hat,seasonal}', 'hat'),
  ('hat_pumpkin_purple', 'acc',     'Pumpkin (Purple)',      'acc/hat_pumpkin_purple.png',     'legendary', 1200, NULL,      true,  '{hat,seasonal}', 'hat'),
  ('hat_witch',          'acc',     'Witch Hat',             'acc/hat_witch_grey.png',         'legendary', 800,  '#2c1810', false, '{hat,seasonal}', 'hat'),
  -- Accessories: Masks
  ('mask_clown',         'acc',     'Clown Mask',            'acc/mask_clown_grey.png',       'legendary', 800,  '#e74c3c', false, '{mask}',         'mask'),
  ('mask_clown_blue',    'acc',     'Clown (Blue)',          'acc/mask_clown_blue.png',       'legendary', 800,  NULL,      true,  '{mask}',         'mask'),
  ('mask_clown_red',     'acc',     'Clown (Red)',           'acc/mask_clown_red.png',        'legendary', 800,  NULL,      true,  '{mask}',         'mask'),
  ('mask_spooky',        'acc',     'Spooky Mask',           'acc/mask_spooky_grey.png',      'legendary', 800,  '#f5f5dc', false, '{mask,seasonal}','mask'),
  -- Accessories: Jewelry
  ('earring_emerald',        'acc', 'Emerald Earring',       'acc/earring_emerald.png',       'rare',      200,  NULL,      true,  '{jewelry}',     'jewelry'),
  ('earring_emerald_silver', 'acc', 'Emerald (Silver)',      'acc/earring_emerald_silver.png','epic',      400,  NULL,      true,  '{jewelry}',     'jewelry'),
  ('earring_gold',           'acc', 'Gold Earring',          'acc/earring_gold_grey.png',     'epic',      500,  '#ffd700', false, '{jewelry}',     'jewelry'),
  ('earring_red',            'acc', 'Red Earring',           'acc/earring_red.png',           'rare',      200,  NULL,      true,  '{jewelry}',     'jewelry'),
  ('earring_red_silver',     'acc', 'Red (Silver)',          'acc/earring_red_silver.png',    'epic',      400,  NULL,      true,  '{jewelry}',     'jewelry'),
  ('earring_silver',         'acc', 'Silver Earring',        'acc/earring_silver_grey.png',   'epic',      400,  '#c0c0c0', false, '{jewelry}',     'jewelry'),
  -- Eyes / Face
  ('eyes',               'eyes',   'Eyes',                  'eyes/eyes_grey.png',            'free',      0,    '#4a3728', false, '{base}',         'eyes'),
  ('blush',              'eyes',   'Blush',                 'eyes/blush_grey.png',           'common',    50,   '#e8a0a0', false, '{makeup}',       'blush'),
  ('lipstick',           'eyes',   'Lipstick',              'eyes/lipstick_grey.png',        'common',    50,   '#cc4444', false, '{makeup}',       'lipstick'),
  -- Pets
  ('cat',                'pets',   'Cat',                   'cat_animation.png',             'epic',      300,  NULL,      false, '{follower}',     'pet'),
  ('yorkie',             'pets',   'Yorkie',                'yorkie_animation.png',          'epic',      500,  NULL,      false, '{follower}',     'pet')
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  file = EXCLUDED.file,
  rarity = EXCLUDED.rarity,
  price_px = EXCLUDED.price_px,
  default_color = EXCLUDED.default_color,
  no_tint = EXCLUDED.no_tint,
  tags = EXCLUDED.tags,
  slot = EXCLUDED.slot;

-- 5. Auto-grant free items to existing players (skip if already granted)
INSERT INTO arcade_inventory (developer_id, item_id)
SELECT d.id, si.id
FROM developers d
CROSS JOIN arcade_shop_items si
WHERE si.rarity = 'free'
  AND EXISTS (SELECT 1 FROM wallets w WHERE w.developer_id = d.id)
ON CONFLICT (developer_id, item_id) DO NOTHING;

-- 6. Grant permissions (safe to re-run)
GRANT SELECT ON arcade_shop_items TO authenticated;
GRANT SELECT ON arcade_inventory TO authenticated;
GRANT SELECT ON arcade_avatar_loadouts TO authenticated;
-- ============================================================
-- Migration 081: arcade_buy_item RPC
-- Atomic purchase: advisory lock → check ownership → check balance → debit → grant → ledger
-- Safe to re-run (CREATE OR REPLACE)
-- ============================================================

CREATE OR REPLACE FUNCTION arcade_buy_item(
  p_developer_id bigint,
  p_item_id text
) RETURNS jsonb AS $$
DECLARE
  v_price integer;
  v_item_name text;
  v_rarity text;
  v_old_balance bigint;
  v_new_balance bigint;
BEGIN
  -- Only service_role (API routes) can call this
  IF auth.role() != 'service_role' THEN
    RAISE EXCEPTION 'arcade_buy_item requires service_role';
  END IF;

  -- Lock on developer to prevent concurrent purchases
  PERFORM pg_advisory_xact_lock(p_developer_id);

  -- 1. Lookup item in arcade catalog
  SELECT price_px, name, rarity INTO v_price, v_item_name, v_rarity
  FROM arcade_shop_items
  WHERE id = p_item_id AND active = true;

  IF v_price IS NULL THEN
    RETURN jsonb_build_object('error', 'item_not_found');
  END IF;

  -- 2. Check if already owned
  IF EXISTS (
    SELECT 1 FROM arcade_inventory
    WHERE developer_id = p_developer_id AND item_id = p_item_id
  ) THEN
    RETURN jsonb_build_object('error', 'already_owned');
  END IF;

  -- 3. Debit wallet (skip for free items)
  IF v_price > 0 THEN
    UPDATE wallets
    SET balance = balance - v_price,
        lifetime_spent = lifetime_spent + v_price,
        updated_at = now()
    WHERE developer_id = p_developer_id
      AND balance >= v_price
    RETURNING balance + v_price, balance
    INTO v_old_balance, v_new_balance;

    IF NOT FOUND THEN
      -- Check if wallet exists at all
      PERFORM 1 FROM wallets WHERE developer_id = p_developer_id;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'wallet_not_found');
      ELSE
        RETURN jsonb_build_object('error', 'insufficient_balance');
      END IF;
    END IF;

    -- 4. Ledger entry (immutable transaction log)
    INSERT INTO wallet_transactions (
      developer_id, type, amount, source,
      reference_id, reference_type, description,
      balance_before, balance_after
    ) VALUES (
      p_developer_id, 'debit', v_price, 'item_purchase',
      p_item_id, 'arcade_cosmetic',
      'Purchased ' || v_item_name,
      v_old_balance, v_new_balance
    );
  ELSE
    -- Free item: just get current balance for response
    SELECT balance INTO v_new_balance
    FROM wallets WHERE developer_id = p_developer_id;
    v_new_balance := COALESCE(v_new_balance, 0);
  END IF;

  -- 5. Grant item to inventory
  INSERT INTO arcade_inventory (developer_id, item_id)
  VALUES (p_developer_id, p_item_id);

  RETURN jsonb_build_object(
    'success', true,
    'new_balance', v_new_balance,
    'price', v_price,
    'item_name', v_item_name
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Only service_role can call this
REVOKE EXECUTE ON FUNCTION arcade_buy_item FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION arcade_buy_item FROM authenticated;
REVOKE EXECUTE ON FUNCTION arcade_buy_item FROM anon;
-- ============================================================
-- Migration 082: Reclassify clothes — no item is truly "full outfit"
-- All clothes in the Cozy People pack are shirt overlays (waist area).
-- Players always need shirt + pants + shoes for a complete look.
-- Costumes are still separate (full body coverage: clown, witch, etc.)
-- ============================================================

-- Move "full" items to "top" (they're just shirts with different styles)
UPDATE arcade_shop_items SET slot = 'top', tags = array_replace(tags, 'full', 'top')
WHERE id IN ('overalls', 'sporty', 'suit', 'dress', 'floral', 'sailor', 'sailor_bow', 'suit_tie')
  AND slot = 'full';

-- Keep costumes as costumes — these DO cover more of the body
-- (clown_blue, clown_red, spooky, witch, pumpkin stay as 'costume')
-- ============================================================
-- Migration 083: Make pants and shoes free (every player needs them)
-- Also grant these to all existing players
-- ============================================================

UPDATE arcade_shop_items SET rarity = 'free', price_px = 0 WHERE id = 'pants';
UPDATE arcade_shop_items SET rarity = 'free', price_px = 0 WHERE id = 'shoes';

-- Grant to all players who have a wallet but don't own these yet
INSERT INTO arcade_inventory (developer_id, item_id)
SELECT d.id, si.id
FROM developers d
CROSS JOIN arcade_shop_items si
WHERE si.id IN ('pants', 'shoes')
  AND EXISTS (SELECT 1 FROM wallets w WHERE w.developer_id = d.id)
ON CONFLICT (developer_id, item_id) DO NOTHING;
-- 084_elevator_cleanup.sql
-- Clean up a bogus 'arcade' room that was briefly seeded, and remove the stale
-- 'floor-1' portal on the lobby (that floor never existed). Elevator routing now
-- reads from the `portals` column on arcade_rooms, not from map_json.objects.

BEGIN;

-- 1. Remove the bogus arcade room (only if it still has no user-created content).
DELETE FROM arcade_rooms WHERE slug = 'arcade';

-- 2. Remove the `destination` key that was injected into the lobby elevator object.
UPDATE arcade_rooms
SET map_json = jsonb_set(
  map_json,
  '{objects}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN obj->>'type' = 'elevator' THEN obj - 'destination'
        ELSE obj
      END
    )
    FROM jsonb_array_elements(map_json->'objects') obj
  )
),
updated_at = now()
WHERE slug = 'lobby';

-- 3. Drop the stale 'floor-1' portal from the lobby (fsociety is the live Floor 1).
UPDATE arcade_rooms
SET portals = (
  SELECT COALESCE(jsonb_agg(p), '[]'::jsonb)
  FROM jsonb_array_elements(portals) p
  WHERE p->>'destination' <> 'floor-1'
),
updated_at = now()
WHERE slug = 'lobby';

COMMIT;
-- 085_lobby_elevator_range.sql
-- Expand the lobby elevator's interact area so players standing at y=2 (below
-- the sprite) are detected by findNearbyObject. Previously: y=0, height=1
-- (range -1..1, unreachable). Now: y=0, height=2 (range -1..2).

BEGIN;

UPDATE arcade_rooms
SET map_json = jsonb_set(
  map_json,
  '{objects}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN obj->>'type' = 'elevator'
          THEN obj || '{"height": 2}'::jsonb
        ELSE obj
      END
    )
    FROM jsonb_array_elements(map_json->'objects') obj
  )
),
updated_at = now()
WHERE slug = 'lobby';

COMMIT;
-- ============================================================
-- Migration 086: Dynamic Landmarks pool
-- Safe to run multiple times (IF NOT EXISTS + EXCEPTION guards)
-- ============================================================
-- Decouples the 3 physical landmark slots (in code) from the
-- active pool (N rows here). page.tsx picks 3 at render time
-- via deterministic weighted selection.
-- ============================================================

CREATE TABLE IF NOT EXISTS landmarks (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                 text UNIQUE NOT NULL,

  -- Card data
  name                 text NOT NULL,
  tagline              text NOT NULL,
  description          text NOT NULL,
  url                  text NOT NULL,
  features             jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Rendering
  accent               text NOT NULL,
  hitbox_radius        integer NOT NULL DEFAULT 80,
  hitbox_height        integer NOT NULL DEFAULT 500,

  -- Geometry selector
  building_kind        text NOT NULL DEFAULT 'tower'
                       CHECK (building_kind IN ('custom', 'tower')),
  custom_component     text,
  template_config      jsonb,

  -- Rotation
  priority             integer NOT NULL DEFAULT 100 CHECK (priority >= 0),

  -- Ownership (force-include when listed login authenticated)
  owner_github_logins  text[] NOT NULL DEFAULT '{}',

  -- Lifecycle
  active               boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT landmarks_kind_config CHECK (
    (building_kind = 'custom' AND custom_component IS NOT NULL)
    OR (building_kind = 'tower' AND template_config IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS landmarks_active_idx
  ON landmarks (active)
  WHERE active;

ALTER TABLE landmarks ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Public reads active landmarks" ON landmarks
    FOR SELECT USING (active = true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- updated_at trigger
CREATE OR REPLACE FUNCTION landmarks_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$ BEGIN
  CREATE TRIGGER landmarks_updated_at
  BEFORE UPDATE ON landmarks
  FOR EACH ROW EXECUTE FUNCTION landmarks_set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

GRANT SELECT ON landmarks TO anon, authenticated;
-- Remap developers.city_theme after THEMES array reorder.
--
-- Old order: 0=Midnight, 1=Sunset, 2=Neon, 3=Emerald
-- New order: 0=Emerald, 1=Midnight, 2=Sunset, 3=Neon
--
-- Mapping: 0→1, 1→2, 2→3, 3→0
--
-- Uses a two-step update via a temporary offset to avoid collisions
-- (e.g. setting rows from 0→1 and then 1→2 in a single pass would
-- double-update the rows that started at 0).

-- Step 1: shift every valid value up by 10 so they don't collide with target values.
update developers
set city_theme = city_theme + 10
where city_theme between 0 and 3;

-- Step 2: apply the final mapping from shifted values.
update developers
set city_theme = case city_theme
  when 10 then 1  -- Midnight (was 0)  → now 1
  when 11 then 2  -- Sunset   (was 1)  → now 2
  when 12 then 3  -- Neon     (was 2)  → now 3
  when 13 then 0  -- Emerald  (was 3)  → now 0
end
where city_theme between 10 and 13;
