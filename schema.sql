-- =========================================================
-- 수련회 선택특강 수강신청 — Supabase 스키마
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run
-- 맨 아래 admins 이메일만 본인 것으로 바꾸세요.
-- =========================================================

create extension if not exists pgcrypto;

-- 1) 전체 설정 (한 줄만 존재)
create table if not exists public.settings (
  id          int primary key default 1 check (id = 1),
  event_title text not null default '수련회 선택특강',
  notice      text not null default '',
  open_at     timestamptz,          -- 신청 시작 시각
  close_at    timestamptz,          -- 신청 마감 시각 (비우면 무기한)
  access_code text not null default '' -- 입장 코드 (비우면 사용 안 함)
);
insert into public.settings (id) values (1) on conflict do nothing;
update public.settings set access_code = '20261228' where id = 1 and access_code = '';  -- 입장 코드 기본값
alter table public.settings add column if not exists campuses jsonb not null default '{}'::jsonb;  -- 지구별 캠퍼스 목록 {"경주":["동국대",…]}

-- 2) 관리자 (이메일 목록)
create table if not exists public.admins (
  email    text primary key,
  role     text not null default 'staff' check (role in ('owner','staff')),  -- owner=최고관리자, staff=일반 간사
  district text not null default ''                                          -- 간사님 담당 지구
);
alter table public.admins add column if not exists role text not null default 'staff';
alter table public.admins add column if not exists district text not null default '';
-- 처음 업그레이드할 때: 최고관리자가 아무도 없으면 기존 관리자를 최고관리자로
update public.admins set role = 'owner' where not exists (select 1 from public.admins where role = 'owner');

-- 3) 특강
create table if not exists public.lectures (
  id              uuid primary key default gen_random_uuid(),
  slot            text not null default '선택특강', -- (내부용, 화면에서 사용 안 함)
  title           text not null,
  description     text not null default '',
  speaker_name    text not null,
  speaker_bio     text not null default '',
  speaker_contact text not null default '',   -- 관리자만 보임
  location        text not null default '',
  capacity        int  not null check (capacity > 0),
  sort_order      int  not null default 0,
  created_at      timestamptz not null default now()
);

-- 4) 신청 내역
create table if not exists public.enrollments (
  id            uuid primary key default gen_random_uuid(),
  lecture_id    uuid not null references public.lectures(id) on delete cascade,
  slot          text not null,
  student_name  text not null,
  student_phone text not null,   -- 숫자만 저장
  campus        text not null default '',
  reg_status    text not null default '',   -- 가등록 / 등록
  district      text not null default '',   -- 안동/영주/경주/김천구미/포항/그외(…)
  created_at    timestamptz not null default clock_timestamp(),
  unique (student_name, student_phone)   -- 학생 1명당 특강 1개만
);
-- 예전 버전으로 이미 만든 경우를 위해
alter table public.enrollments add column if not exists reg_status text not null default '';
alter table public.enrollments add column if not exists district   text not null default '';
alter table public.enrollments add column if not exists note       text not null default '';   -- 비고 (부분참, 화수참여 등)
alter table public.enrollments add column if not exists grade           text not null default '';  -- 학년
alter table public.enrollments add column if not exists soon_role       text not null default '';  -- 순장 / 순원 / 해당 없음
alter table public.enrollments add column if not exists follow_district text not null default '';  -- '그외'일 때 함께 참여하는 지구
alter table public.enrollments add column if not exists church          text not null default '';  -- '그외'일 때 출석 교회
-- 예전 규칙(시간대별 1개) → 새 규칙(1인 1특강)으로 바꾸기
alter table public.enrollments drop constraint if exists enrollments_slot_student_name_student_phone_key;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'enrollments_student_name_student_phone_key') then
    alter table public.enrollments add constraint enrollments_student_name_student_phone_key unique (student_name, student_phone);
  end if;
end $$;
create index if not exists enrollments_lecture_idx on public.enrollments (lecture_id, created_at);

-- ---------------------------------------------------------
-- 권한: 학생(anon)은 테이블 직접 접근 불가, 아래 함수로만 접근
-- ---------------------------------------------------------
alter table public.settings    enable row level security;
alter table public.admins      enable row level security;
alter table public.lectures    enable row level security;
alter table public.enrollments enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

drop policy if exists admin_all on public.settings;
drop policy if exists admin_all on public.lectures;
drop policy if exists admin_all on public.enrollments;
create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and role = 'owner'
  );
$$;

-- 특강·신청내역: 간사는 보기만, 최고관리자만 등록/수정/삭제
-- (간사의 등록 상태·비고 수정은 아래 staff_update_enrollment 함수로만)
drop policy if exists lectures_read     on public.lectures;
drop policy if exists lectures_write    on public.lectures;
drop policy if exists enrollments_read  on public.enrollments;
drop policy if exists enrollments_write on public.enrollments;
create policy lectures_read     on public.lectures    for select to authenticated using (public.is_admin());
create policy lectures_write    on public.lectures    for all    to authenticated using (public.is_owner()) with check (public.is_owner());
create policy enrollments_read  on public.enrollments for select to authenticated using (public.is_admin());
create policy enrollments_write on public.enrollments for all    to authenticated using (public.is_owner()) with check (public.is_owner());

-- settings(신청 시간·입장 코드 등): 관리자는 보기만, 최고관리자만 수정
drop policy if exists settings_read  on public.settings;
drop policy if exists settings_write on public.settings;
create policy settings_read  on public.settings for select to authenticated using (public.is_admin());
create policy settings_write on public.settings for update to authenticated using (public.is_owner()) with check (public.is_owner());

-- admins: 관리자는 목록 보기, 최고관리자만 추가/수정/삭제
drop policy if exists admin_manage on public.admins;
drop policy if exists admins_read  on public.admins;
drop policy if exists admins_write on public.admins;
create policy admins_read  on public.admins for select to authenticated using (public.is_admin());
create policy admins_write on public.admins for all    to authenticated using (public.is_owner()) with check (public.is_owner());

-- 내 관리자 정보 (역할, 담당 지구)
create or replace function public.my_admin()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('email', email, 'role', role, 'district', district)
  from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- 간사: 학생의 등록 상태(가등록/완등록)와 비고만 수정
create or replace function public.staff_update_enrollment(p_id uuid, p_reg_status text, p_note text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', '권한이 없어요.');
  end if;
  if p_reg_status is not null and p_reg_status not in ('가등록', '등록') then
    return json_build_object('ok', false, 'message', '등록 상태가 올바르지 않아요.');
  end if;
  update enrollments
     set reg_status = coalesce(p_reg_status, reg_status),
         note       = coalesce(left(btrim(p_note), 100), note)
   where id = p_id;
  if not found then return json_build_object('ok', false, 'message', '학생을 찾을 수 없어요.'); end if;
  return json_build_object('ok', true);
end;
$$;

-- 내 담당 지구 바꾸기 (일반 간사도 자기 것만)
create or replace function public.set_my_district(p_district text)
returns void language sql security definer set search_path = public as $$
  update admins set district = left(btrim(coalesce(p_district, '')), 40)
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- ---------------------------------------------------------
-- 학생용 함수
-- ---------------------------------------------------------

-- 화면 상태: 서버 시각 + 설정 + 특강 목록(신청 인원 포함, 연락처 제외)
create or replace function public.get_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'now', now(),
    'settings', (
      select json_build_object(
        'event_title', event_title, 'notice', notice,
        'open_at', open_at, 'close_at', close_at,
        'needs_code', access_code <> '',
        'campuses', campuses
      ) from settings where id = 1
    ),
    'lectures', coalesce((
      select json_agg(l order by l.sort_order, l.created_at)
      from (
        select le.id, le.slot, le.title, le.description, le.speaker_name,
               le.speaker_bio, le.location, le.capacity, le.sort_order, le.created_at,
               (select count(*) from enrollments e where e.lecture_id = le.id)::int as enrolled
        from lectures le
      ) l
    ), '[]'::json)
  );
$$;

-- 수강신청 (선착순: 강의 행을 잠그고 인원 확인 후 등록)
drop function if exists public.enroll(uuid, text, text, text, text);
drop function if exists public.enroll(uuid, text, text, text, text, text);
create or replace function public.enroll(
  p_lecture_id uuid, p_name text, p_phone text,
  p_reg_status text, p_district text, p_code text default '',
  p_campus text default '', p_grade text default '', p_soon_role text default '',
  p_follow_district text default '', p_church text default ''
)
returns json language plpgsql security definer set search_path = public as $$
declare
  s        settings;
  lec      lectures;
  v_name   text := btrim(coalesce(p_name, ''));
  v_phone  text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_count  int;
  v_exist  enrollments;
  v_other  text;
begin
  select * into s from settings where id = 1;

  if s.open_at is null or now() < s.open_at then
    return json_build_object('ok', false, 'code', 'not_open', 'message', '아직 신청 시간이 아니에요.');
  end if;
  if s.close_at is not null and now() > s.close_at then
    return json_build_object('ok', false, 'code', 'closed', 'message', '신청이 마감되었어요.');
  end if;
  if s.access_code <> '' and btrim(coalesce(p_code, '')) <> s.access_code then
    return json_build_object('ok', false, 'code', 'bad_code', 'message', '입장 코드가 맞지 않아요.');
  end if;
  if v_name = '' or length(v_name) > 30 or length(v_phone) < 10 or length(v_phone) > 11 then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '이름과 휴대폰 번호를 정확히 입력해 주세요.');
  end if;
  if coalesce(p_reg_status, '') not in ('가등록', '등록') then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '가등록/등록 여부를 선택해 주세요.');
  end if;
  if coalesce(p_district, '') not in ('안동','영주','경주','김천구미','포항','그외') then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '지구를 선택해 주세요.');
  end if;
  if p_district <> '그외' and btrim(coalesce(p_campus, '')) = '' then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '캠퍼스를 선택해 주세요.');
  end if;
  if p_district = '그외' and (coalesce(p_follow_district, '') not in ('안동','영주','경주','김천구미','포항') or btrim(coalesce(p_church, '')) = '') then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '함께 참여하는 지구와 출석 교회를 입력해 주세요.');
  end if;
  if btrim(coalesce(p_grade, '')) = '' or coalesce(p_soon_role, '') not in ('순장','순원','해당 없음') then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '학년과 순장/순원 여부를 선택해 주세요.');
  end if;

  -- 이 강의를 동시에 신청하는 사람들은 여기서 한 줄로 줄을 섬
  select * into lec from lectures where id = p_lecture_id for update;
  if not found then
    return json_build_object('ok', false, 'code', 'not_found', 'message', '없는 특강이에요.');
  end if;

  select * into v_exist from enrollments
   where student_name = v_name and student_phone = v_phone;
  if found then
    if v_exist.lecture_id = lec.id then
      return json_build_object('ok', true, 'code', 'already', 'message', '이미 신청한 특강이에요.');
    end if;
    select title into v_other from lectures where id = v_exist.lecture_id;
    return json_build_object('ok', false, 'code', 'taken',
      'message', format('특강은 1인 1개만 신청할 수 있어요. 이미 「%s」 특강을 신청했어요. 바꾸려면 먼저 취소해 주세요.', v_other));
  end if;

  select count(*) into v_count from enrollments where lecture_id = lec.id;
  if v_count >= lec.capacity then
    return json_build_object('ok', false, 'code', 'full', 'message', '아쉽지만 정원이 마감되었어요.');
  end if;

  insert into enrollments (lecture_id, slot, student_name, student_phone, reg_status, district,
                           campus, grade, soon_role, follow_district, church)
  values (lec.id, lec.slot, v_name, v_phone, p_reg_status, p_district,
          left(btrim(coalesce(p_campus, '')), 40), left(p_grade, 20), p_soon_role,
          case when p_district = '그외' then p_follow_district else '' end,
          case when p_district = '그외' then left(btrim(p_church), 40) else '' end);

  return json_build_object('ok', true, 'code', 'enrolled',
    'message', format('「%s」 신청 완료! (%s/%s)', lec.title, v_count + 1, lec.capacity));
exception when unique_violation then
  return json_build_object('ok', false, 'code', 'taken', 'message', '특강은 1인 1개만 신청할 수 있어요. 이미 신청한 특강이 있어요.');
end;
$$;

-- 내 신청 내역 조회
create or replace function public.my_enrollments(p_name text, p_phone text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'lecture_id', l.id, 'slot', l.slot, 'title', l.title,
           'speaker_name', l.speaker_name, 'location', l.location,
           'created_at', e.created_at
         ) order by l.slot, e.created_at), '[]'::json)
  from enrollments e join lectures l on l.id = e.lecture_id
  where e.student_name = btrim(coalesce(p_name, ''))
    and e.student_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
$$;

-- 신청한 학생이 내 정보(지구·캠퍼스·학년 등) 고치기 — 이름+번호로 찾음, 등록 상태는 간사가 관리하므로 제외
create or replace function public.update_my_info(
  p_name text, p_phone text, p_district text, p_campus text, p_grade text,
  p_soon_role text, p_follow_district text, p_church text
)
returns json language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_district, '') not in ('안동','영주','경주','김천구미','포항','그외')
     or coalesce(p_soon_role, '') not in ('순장','순원','해당 없음') then
    return json_build_object('ok', false, 'message', '입력값을 확인해 주세요.');
  end if;
  update enrollments set
    district = p_district,
    campus = case when p_district = '그외' then '' else left(btrim(coalesce(p_campus, '')), 40) end,
    grade = left(coalesce(p_grade, ''), 20), soon_role = p_soon_role,
    follow_district = case when p_district = '그외' then coalesce(p_follow_district, '') else '' end,
    church = case when p_district = '그외' then left(btrim(coalesce(p_church, '')), 40) else '' end
  where student_name = btrim(coalesce(p_name, ''))
    and student_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  return json_build_object('ok', true);
end;
$$;

-- 신청 취소 (마감 전까지만) — 빈자리는 다음 신청자에게
create or replace function public.cancel_enrollment(p_lecture_id uuid, p_name text, p_phone text)
returns json language plpgsql security definer set search_path = public as $$
declare s settings; n int;
begin
  select * into s from settings where id = 1;
  if s.close_at is not null and now() > s.close_at then
    return json_build_object('ok', false, 'message', '마감 후에는 취소할 수 없어요. 담당 간사에게 문의하세요.');
  end if;
  delete from enrollments
   where lecture_id = p_lecture_id
     and student_name = btrim(coalesce(p_name, ''))
     and student_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  get diagnostics n = row_count;
  if n = 0 then
    return json_build_object('ok', false, 'message', '취소할 신청 내역이 없어요.');
  end if;
  return json_build_object('ok', true, 'message', '취소되었어요.');
end;
$$;

revoke all on function public.get_state()                               from public;
revoke all on function public.enroll(uuid, text, text, text, text, text, text, text, text, text, text) from public;
revoke all on function public.update_my_info(text, text, text, text, text, text, text, text) from public;
revoke all on function public.my_enrollments(text, text)                from public;
revoke all on function public.cancel_enrollment(uuid, text, text)       from public;
grant execute on function public.get_state()                            to anon, authenticated;
grant execute on function public.enroll(uuid, text, text, text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.update_my_info(text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.my_enrollments(text, text)             to anon, authenticated;
grant execute on function public.cancel_enrollment(uuid, text, text)    to anon, authenticated;
grant execute on function public.is_admin()                             to authenticated;
revoke all on function public.my_admin()            from public;
revoke all on function public.set_my_district(text) from public;
grant execute on function public.is_owner()                             to authenticated;
grant execute on function public.my_admin()                             to authenticated;
grant execute on function public.set_my_district(text)                  to authenticated;
revoke all on function public.staff_update_enrollment(uuid, text, text) from public;
grant execute on function public.staff_update_enrollment(uuid, text, text) to authenticated;

-- ---------------------------------------------------------
-- 관리자 등록 — 아래 이메일을 본인 것으로 바꾸고 실행
-- (Authentication > Users 에서 같은 이메일로 사용자도 만들어 두세요)
-- ---------------------------------------------------------
insert into public.admins (email, role) values ('여기에-관리자-이메일@example.com', 'owner')
on conflict do nothing;
