-- RAVIERA ULTIMATE - MIGRAÇÃO ADITIVA (NÃO RECRIA TABELAS EXISTENTES)
-- Faça backup antes. Execute como proprietário do projeto no Supabase SQL Editor.
begin;
create extension if not exists pgcrypto;
-- Usa a função raviera_is_manager já criada em raviera_modulos.sql.
create table if not exists public.support_tickets (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references auth.users(id),
 subject text not null check(length(subject) between 3 and 120), category text not null default 'general' check(category in ('general','telemetry','registration','trip')),
 message text not null check(length(message) between 10 and 3000), status text not null default 'open' check(status in ('open','in_progress','closed')),
 created_at timestamptz not null default now());
create table if not exists public.driver_preferences (
 user_id uuid primary key references auth.users(id), driver_id uuid unique references public.drivers(id),
 division text not null default 'group' check(division in ('group','agro','racing')),
 theme text not null default 'dark' check(theme in ('dark','light')),
 created_at timestamptz not null default now());
create table if not exists public.driver_achievements (
 id uuid primary key default gen_random_uuid(),driver_id uuid not null references public.drivers(id),
 code text not null,awarded_by uuid references auth.users(id),created_at timestamptz not null default now(),
 unique(driver_id,code));
create table if not exists public.driver_notifications (
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id),
 notice_id uuid not null references public.company_notices(id) on delete cascade,read_at timestamptz,
 created_at timestamptz not null default now(),unique(user_id,notice_id));
create table if not exists public.management_audit (
 id uuid primary key default gen_random_uuid(),actor_id uuid not null default auth.uid() references auth.users(id),
 action text not null,details text not null default '',created_at timestamptz not null default now());
create index if not exists support_tickets_user_idx on public.support_tickets(user_id,created_at desc);
create index if not exists audit_created_idx on public.management_audit(created_at desc);
create index if not exists notifications_user_idx on public.driver_notifications(user_id);
-- RLS (default deny for unauthenticated users)
alter table public.support_tickets enable row level security;
alter table public.driver_preferences enable row level security;
alter table public.driver_achievements enable row level security;
alter table public.driver_notifications enable row level security;
alter table public.management_audit enable row level security;
-- Idempotent policy creation; do not drop other policies.
do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_select') then
  create policy rv_ticket_select on public.support_tickets for select to authenticated using(user_id=(select auth.uid()) or (select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_insert') then
  create policy rv_ticket_insert on public.support_tickets for insert to authenticated with check(user_id=(select auth.uid()) and status='open'); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='support_tickets' and policyname='rv_ticket_update') then
  create policy rv_ticket_update on public.support_tickets for update to authenticated using((select public.raviera_is_manager())) with check((select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_select') then
  create policy rv_prefs_select on public.driver_preferences for select to authenticated using(true); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_insert') then
  create policy rv_prefs_insert on public.driver_preferences for insert to authenticated with check(user_id=(select auth.uid()) and driver_id is null); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_preferences' and policyname='rv_prefs_update') then
  create policy rv_prefs_update on public.driver_preferences for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_achievements' and policyname='rv_achievements_select') then
  create policy rv_achievements_select on public.driver_achievements for select to authenticated using(true); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_achievements' and policyname='rv_achievements_insert') then
  create policy rv_achievements_insert on public.driver_achievements for insert to authenticated with check((select public.raviera_is_manager())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_select') then
  create policy rv_notifications_select on public.driver_notifications for select to authenticated using(user_id=(select auth.uid())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_insert') then
  create policy rv_notifications_insert on public.driver_notifications for insert to authenticated with check(user_id=(select auth.uid()) and notice_id in (select id from public.company_notices)); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='driver_notifications' and policyname='rv_notifications_update') then
  create policy rv_notifications_update on public.driver_notifications for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid())); end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='management_audit' and policyname='rv_audit_select') then
  create policy rv_audit_select on public.management_audit for select to authenticated using((select public.raviera_is_manager())); end if;
 end $$;
-- Audit events are server-generated on updates to approvals (not editable by clients).
-- join_applications does not have created_by; use user_id for fallback
create or replace function public.rv_audit_status_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status then
  insert into public.management_audit(actor_id,action,details) values(auth.uid(),TG_TABLE_NAME||'_status',old.id::text||': '||old.status||' -> '||new.status);
 end if;
 return new;
end $$;
drop trigger if exists rv_audit_trips on public.trips;
create trigger rv_audit_trips after update of status on public.trips for each row execute function public.rv_audit_status_change();
drop trigger if exists rv_audit_events on public.event_participations;
create trigger rv_audit_events after update of status on public.event_participations for each row execute function public.rv_audit_status_change();
drop trigger if exists rv_audit_applications on public.join_applications;
create trigger rv_audit_applications after update of status on public.join_applications for each row execute function public.rv_audit_status_change();
commit;
