-- ============================================================
-- schema.sql
-- สคริปต์นี้ไม่ได้เป็นส่วนหนึ่งของเว็บไซต์ (ไม่ได้ deploy ขึ้น GitHub Pages)
-- ใช้รันใน Supabase Dashboard > SQL Editor เพียงครั้งเดียวตอนตั้งค่าฐานข้อมูล
-- ============================================================

-- ข้อ 1: สร้างตาราง words สำหรับเก็บคำศัพท์ภาษาถิ่น
create table if not exists public.words (
  id          uuid primary key default gen_random_uuid(),
  central     text not null,                 -- คำภาษากลาง
  dialect     text not null,                 -- คำภาษาถิ่น
  region      text not null,                 -- ภาคที่ใช้ (เก็บได้หลายภาคคั่นด้วย , เช่น "อีสาน,เหนือ")
  province    text not null,                 -- จังหวัดที่ใช้ (คั่นด้วย , ได้เช่นกัน)
  reading     text not null,                 -- คำอ่านออกเสียง
  pos         text not null,                 -- ชนิดของคำ (part of speech)
  level       text not null,                 -- ระดับภาษา: ทางการ / ทั่วไป / กันเอง / หยาบ
  meaning     text not null,                 -- ความหมาย
  example     text,                          -- ตัวอย่างประโยคภาษาถิ่น (ไม่บังคับ)
  example_th  text,                          -- ตัวอย่างประโยคแปลเป็นภาษากลาง (ไม่บังคับ)
  status      text not null default 'ยืนยัน', -- สถานะตรวจสอบ: ยืนยัน / รอตรวจ
  note        text,                          -- หมายเหตุเพิ่มเติม (ไม่บังคับ)
  created_at  timestamptz not null default now(),

  -- กันคำถิ่นซ้ำในภาคเดียวกัน (คำเดียวกันแต่คนละภาคยังเพิ่มได้ เพราะถือเป็นคนละคำ)
  constraint words_dialect_region_unique unique (dialect, region)
);

-- ทำดัชนีให้ค้นหา/กรองตามสถานะได้เร็วขึ้น (ใช้บ่อยตอนกรองคำที่ "ยืนยัน" แล้ว)
create index if not exists words_status_idx on public.words (status);


-- ============================================================
-- ข้อ 2: Row Level Security (RLS)
-- เปิด RLS แล้วอนุญาตเฉพาะ SELECT และ INSERT ให้ทุกคน (รวมผู้ใช้ที่ไม่ได้ login)
-- ส่วน UPDATE และ DELETE ไม่สร้าง policy ให้เลย เมื่อเปิด RLS แล้ว
-- การกระทำใดที่ไม่มี policy รองรับจะถูกปฏิเสธโดยอัตโนมัติ (default deny)
-- ============================================================
alter table public.words enable row level security;

-- ให้ทุกคนอ่านข้อมูลได้ (หน้าค้นหา/หน้าคำทั้งหมด/หน้าเกี่ยวกับ ต้องอ่านได้โดยไม่ login)
-- drop ก่อน create ทุกครั้งเพื่อให้สคริปต์นี้รันซ้ำได้โดยไม่ error (idempotent)
drop policy if exists "words_public_select" on public.words;
create policy "words_public_select"
  on public.words
  for select
  to anon, authenticated
  using (true);

-- ให้ทุกคนเพิ่มคำใหม่ได้ (หน้าเสนอคำใหม่) โดยไม่ต้อง login
-- with check (true) หมายถึงไม่จำกัดว่าค่าที่ insert จะเป็นอะไร (ปล่อยให้ trigger ในข้อ 3 ช่วยตรวจแทน)
drop policy if exists "words_public_insert" on public.words;
create policy "words_public_insert"
  on public.words
  for insert
  to anon, authenticated
  with check (true);

-- หมายเหตุ: ไม่มี policy สำหรับ update และ delete โดยตั้งใจ
-- เมื่อเปิด RLS (บรรทัด "alter table ... enable row level security") แล้ว
-- ทุก operation ที่ไม่มี policy อนุญาตไว้ จะถูกปฏิเสธเสมอ (fail closed)
-- จึงไม่ต้องเขียน policy ปฏิเสธ update/delete แยกต่างหาก


-- ============================================================
-- ข้อ 3: Trigger ตรวจคำหยาบ
-- ถ้าคำภาษากลางหรือคำภาษาถิ่นมีคำหยาบปน แต่ผู้ส่งไม่ได้เลือก level = 'หยาบ'
-- ให้ปฏิเสธการบันทึก (RAISE EXCEPTION) พร้อมข้อความภาษาไทยอธิบายสาเหตุ
-- หมายเหตุ: bad_words ด้านล่างเป็นตัวอย่างคำหยาบพื้นฐาน ไม่ครบทุกคำ
-- ผู้ดูแลระบบแก้ไข/เพิ่มคำในลิสต์นี้ได้เองภายหลังผ่าน SQL Editor
-- ============================================================
create or replace function public.check_profanity()
returns trigger
language plpgsql
as $$
declare
  bad_words text[] := array['เหี้ย', 'สัส', 'ควย', 'เย็ด', 'ตอแหล', 'หี', 'แตด'];
  w text;
begin
  foreach w in array bad_words loop
    -- ilike '%คำ%' คือค้นหาแบบมีคำนี้ปนอยู่ตรงไหนก็ได้ในข้อความ
    -- is distinct from ใช้แทน <> เพราะเทียบกับค่า NULL ได้อย่างปลอดภัย
    if (new.dialect ilike '%' || w || '%' or new.central ilike '%' || w || '%')
       and new.level is distinct from 'หยาบ' then
      raise exception 'คำนี้อาจเป็นคำหยาบ กรุณาเลือก "ระดับภาษา" เป็น หยาบ ก่อนบันทึกคำนี้';
    end if;
  end loop;

  return new;
end;
$$;

-- ให้ trigger ทำงานก่อนบันทึกทุกครั้งที่มีการเพิ่มคำใหม่
drop trigger if exists words_check_profanity on public.words;
create trigger words_check_profanity
  before insert on public.words
  for each row
  execute function public.check_profanity();
