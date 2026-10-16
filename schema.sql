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
alter table public.enrollments add column if not exists attendance      text not null default '';  -- 전참 / 부분참 (간사 입력)
-- 예전 규칙(시간대별 1개) → 새 규칙(1인 1특강)으로 바꾸기
alter table public.enrollments drop constraint if exists enrollments_slot_student_name_student_phone_key;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'enrollments_student_name_student_phone_key') then
    alter table public.enrollments add constraint enrollments_student_name_student_phone_key unique (student_name, student_phone);
  end if;
end $$;
create index if not exists enrollments_lecture_idx on public.enrollments (lecture_id, created_at);

-- 5) 학생 명단 — 입장할 때 등록, 이름+번호로 로그인. 등록 상태·비고는 간사가 관리
create table if not exists public.students (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text not null,   -- 숫자만
  reg_status      text not null default '',   -- 가등록 / 등록(완등록)
  district        text not null default '',
  campus          text not null default '',
  grade           text not null default '',
  soon_role       text not null default '',
  follow_district text not null default '',
  church          text not null default '',
  note            text not null default '',   -- 비고 (간사 입력)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (name, phone)
);
alter table public.students add column if not exists attendance text not null default '';  -- 전참 / 부분참 (간사 입력)

-- 예전 버전에서 신청만 있던 학생들을 명단으로 옮기기
insert into public.students (name, phone, reg_status, district, campus, grade, soon_role, follow_district, church, note)
select student_name, student_phone, reg_status, district, campus, grade, soon_role, follow_district, church, note
from public.enrollments
on conflict (name, phone) do nothing;

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
alter table public.students enable row level security;
drop policy if exists students_read  on public.students;
drop policy if exists students_write on public.students;
create policy students_read  on public.students for select to authenticated using (public.is_admin());
create policy students_write on public.students for all    to authenticated using (public.is_owner()) with check (public.is_owner());

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

-- 간사: 학생 명단의 등록 상태·비고 수정
drop function if exists public.staff_update_student(uuid, text, text);
create or replace function public.staff_update_student(p_id uuid, p_reg_status text, p_note text, p_attendance text default null)
returns json language plpgsql security definer set search_path = public as $$
declare st students;
begin
  if not public.is_admin() then return json_build_object('ok', false, 'message', '권한이 없어요.'); end if;
  if p_reg_status is not null and p_reg_status not in ('가등록', '등록') then
    return json_build_object('ok', false, 'message', '등록 상태가 올바르지 않아요.');
  end if;
  if p_attendance is not null and p_attendance not in ('', '전참', '부분참') then
    return json_build_object('ok', false, 'message', '참석 형태가 올바르지 않아요.');
  end if;
  update students set attendance = coalesce(p_attendance, attendance), reg_status = coalesce(p_reg_status, reg_status),
                      note = coalesce(left(btrim(p_note), 100), note), updated_at = now()
   where id = p_id returning * into st;
  if not found then return json_build_object('ok', false, 'message', '학생을 찾을 수 없어요.'); end if;
  update enrollments set reg_status = st.reg_status, note = st.note, attendance = st.attendance
   where student_name = st.name and student_phone = st.phone;
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

-- 입장 코드 확인
create or replace function public._code_ok(p_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select access_code = '' or btrim(coalesce(p_code, '')) = access_code from settings where id = 1;
$$;

create or replace function public._student_json(st students)
returns json language sql immutable as $$
  select json_build_object('name', st.name, 'phone', st.phone, 'reg', st.reg_status, 'district', st.district,
    'campus', st.campus, 'grade', st.grade, 'soon', st.soon_role, 'follow', st.follow_district, 'church', st.church);
$$;

-- 학생 정보 등록(p_is_new = true) / 수정(false). 등록 상태는 처음 등록할 때만 학생이 고름
create or replace function public.save_student(
  p_name text, p_phone text, p_reg_status text, p_district text, p_campus text, p_grade text,
  p_soon_role text, p_follow_district text, p_church text, p_code text, p_is_new boolean
)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_name  text := btrim(coalesce(p_name, ''));
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  st students;
begin
  if not public._code_ok(p_code) then
    return json_build_object('ok', false, 'code', 'bad_code', 'message', '입장 코드가 맞지 않아요.');
  end if;
  if v_name = '' or length(v_name) > 30 or v_phone !~ '^010\d{8}$' then
    return json_build_object('ok', false, 'code', 'invalid', 'message', '이름과 휴대폰 번호(010으로 시작하는 11자리)를 확인해 주세요.');
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

  select * into st from students where name = v_name and phone = v_phone;
  if found and p_is_new then
    return json_build_object('ok', false, 'code', 'exists', 'message', '이미 등록된 이름·번호예요. "이미 등록했어요"에서 로그인해 주세요.');
  end if;
  if not found then
    if coalesce(p_reg_status, '') not in ('가등록', '등록') then
      return json_build_object('ok', false, 'code', 'invalid', 'message', '가등록/완등록 중 하나를 선택해 주세요.');
    end if;
    insert into students (name, phone, reg_status) values (v_name, v_phone, p_reg_status) returning * into st;
  end if;

  update students set
    district = p_district,
    campus = case when p_district = '그외' then '' else left(btrim(p_campus), 40) end,
    grade = left(p_grade, 20), soon_role = p_soon_role,
    follow_district = case when p_district = '그외' then p_follow_district else '' end,
    church = case when p_district = '그외' then left(btrim(p_church), 40) else '' end,
    updated_at = now()
  where id = st.id returning * into st;
  -- 신청 내역에도 같은 정보 반영
  update enrollments set district = st.district, campus = st.campus, grade = st.grade, soon_role = st.soon_role,
         follow_district = st.follow_district, church = st.church
   where student_name = st.name and student_phone = st.phone;

  return json_build_object('ok', true, 'student', public._student_json(st));
end;
$$;

-- 학생 로그인 (이름 + 번호)
create or replace function public.student_login(p_name text, p_phone text, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare st students;
begin
  if not public._code_ok(p_code) then
    return json_build_object('ok', false, 'code', 'bad_code', 'message', '입장 코드가 맞지 않아요.');
  end if;
  select * into st from students
   where name = btrim(coalesce(p_name, '')) and phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if not found then
    return json_build_object('ok', false, 'code', 'not_found', 'message', '등록된 정보가 없어요. 이름과 번호를 확인하거나 "처음이에요"에서 등록해 주세요.');
  end if;
  return json_build_object('ok', true, 'student', public._student_json(st));
end;
$$;

-- 수강신청 (선착순: 강의 행을 잠그고 인원 확인 후 등록) — 학생 명단에 있어야 신청 가능
drop function if exists public.enroll(uuid, text, text, text, text);
drop function if exists public.enroll(uuid, text, text, text, text, text);
drop function if exists public.enroll(uuid, text, text, text, text, text, text, text, text, text, text);
drop function if exists public.update_my_info(text, text, text, text, text, text, text, text);
create or replace function public.enroll(p_lecture_id uuid, p_name text, p_phone text, p_code text default '')
returns json language plpgsql security definer set search_path = public as $$
declare
  s        settings;
  lec      lectures;
  st       students;
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
  if not public._code_ok(p_code) then
    return json_build_object('ok', false, 'code', 'bad_code', 'message', '입장 코드가 맞지 않아요.');
  end if;
  select * into st from students
   where name = btrim(coalesce(p_name, '')) and phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if not found then
    return json_build_object('ok', false, 'code', 'no_student', 'message', '학생 정보가 없어요. 로그아웃 후 다시 등록해 주세요.');
  end if;

  -- 이 강의를 동시에 신청하는 사람들은 여기서 한 줄로 줄을 섬
  select * into lec from lectures where id = p_lecture_id for update;
  if not found then
    return json_build_object('ok', false, 'code', 'not_found', 'message', '없는 특강이에요.');
  end if;

  select * into v_exist from enrollments where student_name = st.name and student_phone = st.phone;
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
                           campus, grade, soon_role, follow_district, church, note)
  values (lec.id, lec.slot, st.name, st.phone, st.reg_status, st.district,
          st.campus, st.grade, st.soon_role, st.follow_district, st.church, st.note);

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
         ) order by e.created_at), '[]'::json)
  from enrollments e join lectures l on l.id = e.lecture_id
  where e.student_name = btrim(coalesce(p_name, ''))
    and e.student_phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
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

revoke all on function public.get_state() from public;
revoke all on function public._code_ok(text) from public;
revoke all on function public.save_student(text, text, text, text, text, text, text, text, text, text, boolean) from public;
revoke all on function public.student_login(text, text, text) from public;
revoke all on function public.enroll(uuid, text, text, text) from public;
revoke all on function public.my_enrollments(text, text) from public;
revoke all on function public.cancel_enrollment(uuid, text, text) from public;
revoke all on function public.my_admin() from public;
revoke all on function public.set_my_district(text) from public;
revoke all on function public.staff_update_enrollment(uuid, text, text) from public;
revoke all on function public.staff_update_student(uuid, text, text, text) from public;
grant execute on function public.get_state() to anon, authenticated;
grant execute on function public.save_student(text, text, text, text, text, text, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.student_login(text, text, text) to anon, authenticated;
grant execute on function public.enroll(uuid, text, text, text) to anon, authenticated;
grant execute on function public.my_enrollments(text, text) to anon, authenticated;
grant execute on function public.cancel_enrollment(uuid, text, text) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_owner() to authenticated;
grant execute on function public.my_admin() to authenticated;
grant execute on function public.set_my_district(text) to authenticated;
grant execute on function public.staff_update_enrollment(uuid, text, text) to authenticated;
grant execute on function public.staff_update_student(uuid, text, text, text) to authenticated;
-- 간사/관리자 전용 함수는 로그인한 사용자만
revoke execute on function public.staff_update_student(uuid, text, text, text) from anon;
revoke execute on function public.staff_update_enrollment(uuid, text, text) from anon;
revoke execute on function public.set_my_district(text) from anon;
revoke execute on function public.my_admin() from anon;
revoke execute on function public.is_owner() from anon;
alter function public._student_json(public.students) set search_path = public;

-- ---------------------------------------------------------
-- 간사 가입 → 최고관리자 승인
-- ---------------------------------------------------------
create table if not exists public.admin_requests (
  email      text primary key,
  name       text not null default '',
  district   text not null default '',
  status     text not null default 'pending',   -- pending / approved / rejected
  created_at timestamptz not null default now()
);
alter table public.admin_requests enable row level security;   -- 정책 없음: 아래 함수로만 접근

create or replace function public.my_access_status()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'status', case
      when exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))) then 'admin'
      else coalesce((select status from admin_requests where email = lower(coalesce(auth.jwt() ->> 'email', ''))), 'none') end,
    'request', (select json_build_object('name', name, 'district', district, 'created_at', created_at)
                from admin_requests where email = lower(coalesce(auth.jwt() ->> 'email', ''))));
$$;

create or replace function public.request_admin_access(p_name text, p_district text)
returns json language plpgsql security definer set search_path = public as $$
declare v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_email = '' then return json_build_object('ok', false, 'message', '로그인이 필요해요.'); end if;
  if exists (select 1 from admins where lower(email) = v_email) then
    return json_build_object('ok', true, 'status', 'admin');
  end if;
  if btrim(coalesce(p_name, '')) = '' then return json_build_object('ok', false, 'message', '이름을 입력해 주세요.'); end if;
  insert into admin_requests (email, name, district, status) values (v_email, left(btrim(p_name), 30), left(btrim(coalesce(p_district, '')), 40), 'pending')
  on conflict (email) do update set name = excluded.name, district = excluded.district, status = 'pending', created_at = now();
  return json_build_object('ok', true, 'status', 'pending');
end;
$$;

create or replace function public.list_admin_requests()
returns json language sql stable security definer set search_path = public as $$
  select case when public.is_owner() then
    coalesce((select json_agg(json_build_object('email', email, 'name', name, 'district', district, 'created_at', created_at) order by created_at)
              from admin_requests where status = 'pending'), '[]'::json)
  else '[]'::json end;
$$;

create or replace function public.decide_admin_request(p_email text, p_approve boolean, p_role text default 'staff')
returns json language plpgsql security definer set search_path = public as $$
declare r admin_requests;
begin
  if not public.is_owner() then return json_build_object('ok', false, 'message', '최고관리자만 할 수 있어요.'); end if;
  select * into r from admin_requests where email = lower(p_email) and status = 'pending';
  if not found then return json_build_object('ok', false, 'message', '요청을 찾을 수 없어요.'); end if;
  if p_approve then
    insert into admins (email, role, district) values (r.email, case when p_role = 'owner' then 'owner' else 'staff' end, r.district)
    on conflict (email) do nothing;
  end if;
  update admin_requests set status = case when p_approve then 'approved' else 'rejected' end where email = r.email;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.my_access_status() from public, anon;
revoke all on function public.request_admin_access(text, text) from public, anon;
revoke all on function public.list_admin_requests() from public, anon;
revoke all on function public.decide_admin_request(text, boolean, text) from public, anon;
grant execute on function public.my_access_status() to authenticated;
grant execute on function public.request_admin_access(text, text) to authenticated;
grant execute on function public.list_admin_requests() to authenticated;
grant execute on function public.decide_admin_request(text, boolean, text) to authenticated;

-- ---------------------------------------------------------
-- 관리자 등록 — 아래 이메일을 본인 것으로 바꾸고 실행
-- (Authentication > Users 에서 같은 이메일로 사용자도 만들어 두세요)
-- ---------------------------------------------------------
insert into public.admins (email, role) values ('여기에-관리자-이메일@example.com', 'owner')
on conflict do nothing;
