-- ReServe合宿（仮想予約SaaS）シードデータ
-- 設計.md「シードデータ設計方針」「シード検算クエリ」に厳密準拠。
-- 20260620000000_init.sql のスキーマに対して投入する。
--
-- 全数字は generate_series + seq の閾値で決定論的に作る。
-- 日時はすべて固定タイムスタンプ（now()/CURRENT_DATE 等の非決定論的関数は使わない）。
-- 何度 seed しても同じ数字になる。
--
-- 期待値（末尾の検算クエリ参照）：
--   stores 500 / setup_done 280 / published 198
--   billing month2 178 / month3 89
--   first_booking 4800 / confirmed 4785 / cancelled 2640
--   checkins 4569 / repeaters 875 / GMV 18,276,000 / fee 182,760
--
-- 基準日時（決定論）：
--   起点 = 2026-01-01 00:00:00+09（JST）。
--   各行は seq に応じて分単位/日単位でずらすが、すべて固定式で生成する。

-- ============================================================
-- stores（500行）
--   id 1..500 / is_setup_done = id<=280 / is_published = id<=198
--   created_at = 起点 + (id-1)分（決定論）
-- ============================================================
INSERT INTO stores (id, name, is_setup_done, is_published, created_at)
SELECT
  s                                                      AS id,
  'ReServe店舗 ' || s                                    AS name,
  (s <= 280)                                             AS is_setup_done,
  (s <= 198)                                             AS is_published,
  TIMESTAMPTZ '2026-01-01 00:00:00+09' + ((s - 1) * INTERVAL '1 minute') AS created_at
FROM generate_series(1, 500) AS s;

-- ============================================================
-- users（4,800行）— 初回予約を完了した利用者（予約のFK用）
--   id 1..4800 / created_at = 起点 + (id-1)分
-- ============================================================
INSERT INTO users (id, name, created_at)
SELECT
  u                                                      AS id,
  '利用者 ' || u                                         AS name,
  TIMESTAMPTZ '2026-02-01 00:00:00+09' + ((u - 1) * INTERVAL '1 minute') AS created_at
FROM generate_series(1, 4800) AS u;

-- ============================================================
-- billing_periods（767行）— 継続の正典
--   month1: store_id 1..500（500行）
--   month2: store_id 1..178（178行）
--   month3: store_id 1..89 （89行）
--   全行 amount=12000・status='paid'
--   id は連番（month1=1..500 / month2=501..678 / month3=679..767）
--   billed_at = 起点 + (period_month-1)*30日（30日刻みの固定日時）
-- ============================================================
-- month1（1..500）
INSERT INTO billing_periods (id, store_id, period_month, amount, billed_at, status)
SELECT
  s                                                      AS id,
  s                                                      AS store_id,
  1                                                      AS period_month,
  12000                                                  AS amount,
  TIMESTAMPTZ '2026-01-01 00:00:00+09' + (0 * INTERVAL '30 days') AS billed_at,
  'paid'                                                 AS status
FROM generate_series(1, 500) AS s;

-- month2（1..178）／ id を 500 ずらす
INSERT INTO billing_periods (id, store_id, period_month, amount, billed_at, status)
SELECT
  500 + s                                                AS id,
  s                                                      AS store_id,
  2                                                      AS period_month,
  12000                                                  AS amount,
  TIMESTAMPTZ '2026-01-01 00:00:00+09' + (1 * INTERVAL '30 days') AS billed_at,
  'paid'                                                 AS status
FROM generate_series(1, 178) AS s;

-- month3（1..89）／ id を 678 ずらす（500 + 178）
INSERT INTO billing_periods (id, store_id, period_month, amount, billed_at, status)
SELECT
  678 + s                                                AS id,
  s                                                      AS store_id,
  3                                                      AS period_month,
  12000                                                  AS amount,
  TIMESTAMPTZ '2026-01-01 00:00:00+09' + (2 * INTERVAL '30 days') AS billed_at,
  'paid'                                                 AS status
FROM generate_series(1, 89) AS s;

-- ============================================================
-- reservations（7,425行）
--   初回予約 4,800（id 1..4800, user_id 1..4800）
--     - user_id 1..2160  → confirmed（来店確定 2,160）
--     - user_id 2161..4800 → cancelled（キャンセル 2,640）
--   リピート予約 2,625（id 4801..7425, リピーター 875人 × 3件）
--     - user_id 1..875 が 3件ずつ（全て confirmed）
--   store_id は公開店舗 1..198 に割り当て（((seq-1) % 198) + 1）
--   payment_timing は全行 postpaid
--   confirmed 合計 = 2,160 + 2,625 = 4,785 / cancelled = 2,640 / 総数 7,425
-- ============================================================
-- 初回予約（id=1..4800, user_id=1..4800）
INSERT INTO reservations (id, user_id, store_id, status, payment_timing, created_at)
SELECT
  u                                                      AS id,
  u                                                      AS user_id,
  ((u - 1) % 198) + 1                                    AS store_id,        -- 公開店舗 1..198
  CASE WHEN u <= 2160 THEN 'confirmed' ELSE 'cancelled' END AS status,
  'postpaid'                                             AS payment_timing,
  TIMESTAMPTZ '2026-02-01 00:00:00+09' + ((u - 1) * INTERVAL '1 minute') AS created_at
FROM generate_series(1, 4800) AS u;

-- リピート予約（id=4801..7425, 875人 × 3件 = 2,625行, 全て confirmed）
--   r = 1..2625。対象ユーザー = ((r-1) % 875) + 1 で 1..875 を 3周。
INSERT INTO reservations (id, user_id, store_id, status, payment_timing, created_at)
SELECT
  4800 + r                                               AS id,
  ((r - 1) % 875) + 1                                    AS user_id,         -- リピーター 1..875
  ((r - 1) % 198) + 1                                    AS store_id,        -- 公開店舗 1..198
  'confirmed'                                            AS status,
  'postpaid'                                             AS payment_timing,
  TIMESTAMPTZ '2026-03-01 00:00:00+09' + ((r - 1) * INTERVAL '1 minute') AS created_at
FROM generate_series(1, 2625) AS r;

-- ============================================================
-- payments（4,569行・来店時後払い）
--   初回来店 1,944：confirmed かつ来店した利用者 = user_id 1..1944
--     - user_id 1..875   = リピーター（後でリピート3件が追加され COUNT=4）
--     - user_id 876..1944 = 非リピーター（初回1件のみ COUNT=1）
--   リピート 2,625：リピーター 875人 × 3回（user_id 1..875 を 3周）
--   amount は全行 4000 → SUM = 4569 × 4000 = 18,276,000 / AVG = 4000（厳密）
--   id：初回 1..1944 / リピート 1945..4569
--   リピーター判定：GROUP BY user_id HAVING COUNT(*)>=2 → user_id 1..875 = 875人
-- ============================================================
-- 初回来店決済（id=1..1944, user_id=1..1944, 各1件）
INSERT INTO payments (id, user_id, amount, paid_at)
SELECT
  v                                                      AS id,
  v                                                      AS user_id,
  4000                                                   AS amount,
  TIMESTAMPTZ '2026-02-05 00:00:00+09' + ((v - 1) * INTERVAL '1 minute') AS paid_at
FROM generate_series(1, 1944) AS v;

-- リピート決済（id=1945..4569, 875人 × 3回 = 2,625件, user_id 1..875 を 3周）
INSERT INTO payments (id, user_id, amount, paid_at)
SELECT
  1944 + r                                               AS id,
  ((r - 1) % 875) + 1                                    AS user_id,         -- リピーター 1..875
  4000                                                   AS amount,
  TIMESTAMPTZ '2026-03-05 00:00:00+09' + ((r - 1) * INTERVAL '1 minute') AS paid_at
FROM generate_series(1, 2625) AS r;

-- ============================================================
-- checkins（4,569行）— 来店＝決済。payments と1:1対応。
--   payment_id は payments.id 1..4569 をそのまま1:1で紐付け。
--   user_id は対応する payment の user_id（同じ式で再現）。
--   id 1..4569。
-- ============================================================
-- 初回来店分（payment_id=1..1944, user_id=1..1944）
INSERT INTO checkins (id, user_id, payment_id, checked_in_at)
SELECT
  v                                                      AS id,
  v                                                      AS user_id,
  v                                                      AS payment_id,
  TIMESTAMPTZ '2026-02-05 00:00:00+09' + ((v - 1) * INTERVAL '1 minute') AS checked_in_at
FROM generate_series(1, 1944) AS v;

-- リピート来店分（payment_id=1945..4569, user_id=リピーター 1..875 を 3周）
INSERT INTO checkins (id, user_id, payment_id, checked_in_at)
SELECT
  1944 + r                                               AS id,
  ((r - 1) % 875) + 1                                    AS user_id,
  1944 + r                                               AS payment_id,
  TIMESTAMPTZ '2026-03-05 00:00:00+09' + ((r - 1) * INTERVAL '1 minute') AS checked_in_at
FROM generate_series(1, 2625) AS r;

-- ============================================================
-- 検算クエリ（設計.md「シード検算クエリ」と一致）
--   期待値：500 / 280 / 198 / 178 / 89 / 4800 / 4785 / 2640 / 4569 / 875 / 18276000 / 182760
--   seed 適用後に手動で実行して確認する（コメントアウト）。
-- ============================================================
-- SELECT
--   (SELECT COUNT(*) FROM stores)                                          AS registered_500,
--   (SELECT COUNT(*) FROM stores WHERE is_setup_done)                      AS setup_done_280,
--   (SELECT COUNT(*) FROM stores WHERE is_published)                       AS published_198,
--   (SELECT COUNT(DISTINCT store_id) FROM billing_periods
--    WHERE period_month=2 AND status='paid')                               AS month2_178,
--   (SELECT COUNT(DISTINCT store_id) FROM billing_periods
--    WHERE period_month=3 AND status='paid')                               AS month3_89,
--   (SELECT COUNT(DISTINCT user_id) FROM reservations
--    WHERE user_id <= 4800)                                                AS first_booking_4800,
--   (SELECT COUNT(*) FROM reservations WHERE status='confirmed')           AS confirmed_4785,
--   (SELECT COUNT(*) FROM reservations WHERE status='cancelled')           AS cancelled_2640,
--   (SELECT COUNT(*) FROM checkins)                                        AS visits_4569,
--   (SELECT COUNT(*) FROM (
--     SELECT user_id FROM payments GROUP BY user_id HAVING COUNT(*)>=2) r)  AS repeaters_875,
--   (SELECT SUM(amount) FROM payments)                                     AS gmv_18276000,
--   (SELECT ROUND(SUM(amount)*0.01) FROM payments)                         AS fee_182760;

-- 追加検算（行数・整合の確認用。コメントアウト）：
--   billing_periods 総数 = 767（500+178+89）
--   reservations 総数 = 7425 / payments 総数 = 4569 / checkins 総数 = 4569
--   payments AVG = 4000
-- SELECT
--   (SELECT COUNT(*) FROM billing_periods)              AS billing_767,
--   (SELECT COUNT(*) FROM reservations)                 AS reservations_7425,
--   (SELECT COUNT(*) FROM payments)                     AS payments_4569,
--   (SELECT ROUND(AVG(amount)) FROM payments)           AS avg_4000;
