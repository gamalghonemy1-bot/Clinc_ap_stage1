-- شغّل هذا الملف مرة واحدة في Supabase > SQL Editor
create table if not exists patients (
  clinic text not null check (length(clinic) >= 16),
  uid text not null,
  name text, phone text, age int, notes text,
  upd bigint not null,
  del int not null default 0,
  primary key (clinic, uid)
);
create table if not exists appts (
  clinic text not null check (length(clinic) >= 16),
  uid text not null,
  puid text, dt text, status text, reason text,
  fee real not null default 0,
  paid int not null default 0,
  upd bigint not null,
  del int not null default 0,
  primary key (clinic, uid)
);
create index if not exists patients_upd on patients (clinic, upd);
create index if not exists appts_upd on appts (clinic, upd);

alter table patients enable row level security;
alter table appts enable row level security;

-- لا يصل أحد لبيانات العيادة إلا إذا أرسل كود العيادة الصحيح في الهيدر x-clinic
create policy clinic_patients on patients for all to anon
  using (clinic = coalesce(current_setting('request.headers', true)::json ->> 'x-clinic', ''))
  with check (clinic = coalesce(current_setting('request.headers', true)::json ->> 'x-clinic', ''));
create policy clinic_appts on appts for all to anon
  using (clinic = coalesce(current_setting('request.headers', true)::json ->> 'x-clinic', ''))
  with check (clinic = coalesce(current_setting('request.headers', true)::json ->> 'x-clinic', ''));
