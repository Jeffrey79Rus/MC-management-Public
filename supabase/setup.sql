-- =====================================================================
-- MC 교육 희망 조사 : 응답 저장소 설정
-- Supabase의 SQL Editor에 이 파일 내용을 통째로 붙여넣고 Run을 누릅니다.
-- 여러 번 실행해도 기존 응답과 관리자 키는 지워지지 않습니다.
-- 마지막에 나오는 '관리자 키'를 복사해 두세요.
-- =====================================================================

create table if not exists public.mc_survey_responses (
  name       text primary key,
  picks      text[] not null,
  shared     text[] not null default '{}',
  memo       text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.mc_survey_config (
  key   text primary key,
  value text not null default ''
);

-- 표를 직접 읽거나 쓰는 것은 모두 막고, 아래 함수로만 접근하게 합니다.
alter table public.mc_survey_responses enable row level security;
alter table public.mc_survey_config    enable row level security;
revoke all on public.mc_survey_responses from anon, authenticated;
revoke all on public.mc_survey_config    from anon, authenticated;

insert into public.mc_survey_config (key, value) values
  ('admin_key', substr(md5(random()::text || clock_timestamp()::text), 1, 12)),
  ('closed', ''),
  ('roster', '')
on conflict (key) do nothing;

-- 과정 코드 정리 (형식 확인, 중복 제거, 개수 제한)
create or replace function public.mc_valid_ids(p text[], lim int)
returns text[] language sql immutable as $$
  select coalesce(array_agg(id order by ord), '{}'::text[]) from (
    select id, min(ord) as ord
    from unnest(coalesce(p, '{}'::text[])) with ordinality as u(id, ord)
    where id ~ '^[a-z]{2}[0-9]{1,2}$'
    group by id order by min(ord) limit lim
  ) s
$$;

create or replace function public.mc_is_admin(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_key, '') <> ''
     and p_key = (select value from mc_survey_config where key = 'admin_key')
$$;

-- 팀원 제출 (같은 이름이면 덮어씀)
create or replace function public.submit_survey(
  p_name text, p_picks text[], p_shared text[] default '{}', p_memo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare v_name text; v_picks text[]; v_existed boolean;
begin
  if coalesce((select value from mc_survey_config where key = 'closed'), '') = 'Y' then
    return json_build_object('ok', false, 'error', 'closed');
  end if;
  v_name  := left(regexp_replace(coalesce(p_name, ''), '\s', '', 'g'), 20);
  v_picks := mc_valid_ids(p_picks, 5);
  if v_name = '' or cardinality(v_picks) = 0 then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;
  v_existed := exists (select 1 from mc_survey_responses where name = v_name);
  if not v_existed and (select count(*) from mc_survey_responses) >= 200 then
    return json_build_object('ok', false, 'error', 'full');
  end if;
  insert into mc_survey_responses (name, picks, shared, memo, updated_at)
  values (v_name, v_picks, mc_valid_ids(p_shared, 20), left(coalesce(p_memo, ''), 500), now())
  on conflict (name) do update
    set picks = excluded.picks, shared = excluded.shared, memo = excluded.memo, updated_at = now();
  return json_build_object('ok', true, 'updated', v_existed);
end $$;

-- 누구나 보는 과정별 합계 (이름은 내보내지 않음)
create or replace function public.survey_summary()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'n', (select count(*) from mc_survey_responses),
    'closed', coalesce((select value from mc_survey_config where key = 'closed'), '') = 'Y',
    'at', now(),
    'picks', coalesce((select json_agg(x) from (
        select u.id, u.rk, count(*) as cnt
        from mc_survey_responses r cross join lateral unnest(r.picks) with ordinality as u(id, rk)
        group by u.id, u.rk) x), '[]'::json),
    'shared', coalesce((select json_agg(y) from (
        select s.id, count(*) as cnt
        from mc_survey_responses r cross join lateral unnest(r.shared) as s(id)
        group by s.id) y), '[]'::json))
$$;

-- 관리자 전용 (관리자 키가 맞을 때만 동작)
create or replace function public.admin_rows(p_key text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not mc_is_admin(p_key) then return json_build_object('ok', false, 'error', 'key'); end if;
  return json_build_object('ok', true,
    'closed', coalesce((select value from mc_survey_config where key = 'closed'), '') = 'Y',
    'roster', coalesce((select value from mc_survey_config where key = 'roster'), ''),
    'rows', coalesce((select json_agg(json_build_object(
        'name', name, 'picks', picks, 'shared', shared, 'memo', memo, 'at', updated_at)
        order by updated_at) from mc_survey_responses), '[]'::json));
end $$;

create or replace function public.admin_save_roster(p_key text, p_roster text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not mc_is_admin(p_key) then return json_build_object('ok', false, 'error', 'key'); end if;
  update mc_survey_config set value = left(coalesce(p_roster, ''), 5000) where key = 'roster';
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_set_closed(p_key text, p_closed boolean)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not mc_is_admin(p_key) then return json_build_object('ok', false, 'error', 'key'); end if;
  update mc_survey_config set value = case when p_closed then 'Y' else '' end where key = 'closed';
  return json_build_object('ok', true, 'closed', p_closed);
end $$;

create or replace function public.admin_delete(p_key text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not mc_is_admin(p_key) then return json_build_object('ok', false, 'error', 'key'); end if;
  delete from mc_survey_responses where name = p_name;
  return json_build_object('ok', true);
end $$;

-- 실행 권한: 내부 함수는 막고, 사이트가 부르는 함수만 엽니다.
revoke execute on function public.mc_valid_ids(text[], int) from public, anon, authenticated;
revoke execute on function public.mc_is_admin(text)         from public, anon, authenticated;
grant execute on function public.submit_survey(text, text[], text[], text) to anon, authenticated;
grant execute on function public.survey_summary()                          to anon, authenticated;
grant execute on function public.admin_rows(text)                          to anon, authenticated;
grant execute on function public.admin_save_roster(text, text)             to anon, authenticated;
grant execute on function public.admin_set_closed(text, boolean)           to anon, authenticated;
grant execute on function public.admin_delete(text, text)                  to anon, authenticated;

notify pgrst, 'reload schema';

select value as "관리자 키 (복사해 두세요)" from public.mc_survey_config where key = 'admin_key';
